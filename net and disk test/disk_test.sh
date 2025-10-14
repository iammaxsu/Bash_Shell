#!/usr/bin/env bash
# disk_test.sh ??depends on config.sh & function.sh, with robust logging and fixed summary

#set -uo pipefail  # no `-e` to avoid early aborts
set -Eeuo pipefail

export _disk_test_version
: "${_disk_test_version:="00.00.01"}"

# ---------- Locate & source companions (REQUIRED) ----------
_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"     # The script with full path, e.g. /home/adlink/Downloads/test.sh.
_entry_dir="$(cd "$(dirname "${_entry}")" && pwd)"      # The directory of the script, e.g. /home/adlink/Downloads.

find_and_source() {
  local _name="$1"
  local search_dirs=(     # Directories to search for the companion scripts
    "${_entry_dir}"
    "/home/${USER}/Downloads"
  )

  for _dir in "${search_dirs[@]}"; do
    if [[ -f "${_dir}/${_name}" ]]; then
      . "${_dir}/${_name}"
      return 0
    fi
  done

  echo "FATAL: cannot find ${_name} in any of the search directories." >&2
  printf " - %s\n" "${search_dirs[@]}" >&2
  exit 1
}

find_and_source "config.sh"
find_and_source "function.sh"
# ---------- Parse CLI parameters ----------
parse_common_cli "$@"

# ---------- Init logs & session ----------
log_dir "" 1
log_root="${_session_log_dir}"

# Initialize, m = _target_loop
counter_init "disk" "${_target_loop:-1}"

# Calculate how many loops to do
_loops_this_run=$(counter_loops_this_run)
if [[ "${_loops_this_run}" -le 0 ]]; then
  echo "[INFO] Already completed (${_n}/${_m}). Nothing to do."
  exit 0
fi

# parse_loops_arg "${1:-}"

# Timestamp per loop & log folders
: "${_session_ts:=$(now_ts)}"
_run_ts="${_session_ts}"
_disklog="${log_root}/disk_test_${_run_ts}.log"
_disksum="${log_root}/disk_summary_${_run_ts}.log"

# ---------- Test Header ----------
## ---------- Start elapsed time now ----------
run_time || true

if [[ ! -f "${_disklog}" ]]; then
  {
    echo "============= Disk Test (${_run_ts}) ============="
    echo "Host: $(hostname)   User: $(whoami)"
    echo "API: ${_function_api_version}"
    echo "=================================================="
  } > "${_disklog}"
fi

# fio 包裝
run_fio() { 
  local dev="$1" out="$2"
  shift 2
  sudo fio --filename="$dev" --group_reporting --name=test \
    --output="${log_root}/${out}" --direct=1 "$@"
}

log "==== disk_test.sh ===="
log "Script   : ${_entry}"
log "LogPath  : ${log_root}"
log "Target m : ${_m}    Done n: ${_n}    This run loops: ${_loops_this_run}"
log "============================================="

# ---------- Ensure tools ----------
if command -v fio >/dev/null 2>&1; then :; else fio_install || true; fi
command -v lsblk >/dev/null 2>&1 || { log "ERROR: lsblk not found"; exit 1; }
command -v findmnt >/dev/null 2>&1 || { log "ERROR: findmnt not found"; exit 1; }
command -v blkid >/dev/null 2>&1 || true

# ---------- Helpers ----------
normalize_dev() { local n="$1"; while [[ "$n" == /dev/* ]]; do n="${n#/dev/}"; done; echo "/dev/${n}"; }
is_block() { local n; n="$(normalize_dev "$1")"; lsblk -dn -o NAME "$n" &>/dev/null; }
resolve_ref() {
  local ref="$1"
  if [[ "$ref" == UUID=* ]]; then blkid -U "${ref#UUID=}" 2>/dev/null || echo ""
  elif [[ "$ref" == PARTUUID=* ]]; then blkid -t PARTUUID="${ref#PARTUUID=}" -o device 2>/dev/null || echo ""
  else echo "$ref"; fi
}
parents_to_disks() {
  local node; node="$(normalize_dev "$1")"; is_block "$node" || return 0
  local t; t="$(lsblk -no TYPE "$node" 2>/dev/null || echo "")"
  if [[ "$t" == "disk" ]]; then basename "$node"; return; fi
  declare -A seen=(); local q=("$node")
  while ((${#q[@]})); do
    local cur="${q[0]}"; q=("${q[@]:1}"); [[ -n "${seen[$cur]:-}" ]] && continue; seen["$cur"]=1
    while IFS= read -r line; do
      local name type pk; name="$(awk '{print $1}' <<<"$line")"; type="$(awk '{print $2}' <<<"$line")"; pk="$(awk '{print $3}' <<<"$line")"
      if [[ "$name" == "$cur" ]]; then
        if [[ "$type" == "disk" ]]; then basename "$name"
        elif [[ -n "$pk" && "$pk" != "-" ]]; then IFS=',' read -ra pks <<<"$pk"; for p in "${pks[@]}"; do q+=("$(normalize_dev "$p")"); done; fi
      fi
    done < <(lsblk -nrpo NAME,TYPE,PKNAME "$cur" 2>/dev/null || true)
  done | sed 's|/dev/||' | sort -u
}
declare -A _UNSAFE=()
mark_disk_parent() {
  local src="$1" why="$2"; [[ -z "$src" ]] && return
  local dev; dev="$(resolve_ref "$src")"; [[ -z "$dev" ]] && dev="$src"
  dev="$(normalize_dev "$dev")"; is_block "$dev" || { log "Skip non-block: ${src} (${why})"; return; }
  while IFS= read -r d; do [[ -n "$d" ]] && _UNSAFE["$d"]="reason:${why} source:${src}"; done < <(parents_to_disks "$dev")
}

# ---------- Build SAFE target list ----------
log "Stage: Collect mounted block sources"
while IFS= read -r src; do [[ "$src" == /dev/* ]] || continue; is_block "$src" || continue; mark_disk_parent "$src" "mounted"; done < <(findmnt -rn -o SOURCE 2>/dev/null | sort -u)

for mp in / /boot /boot/efi; do
  src="$(findmnt -nr -o SOURCE --target "$mp" 2>/dev/null || true)"
  [[ -n "$src" ]] && mark_disk_parent "$src" "critical:${mp}"
done

if [[ -r /proc/swaps ]]; then
  while read -r sw; do [[ "$sw" == /dev/* ]] || continue; is_block "$sw" || continue; mark_disk_parent "$sw" "swap"; done < <(awk 'NR>1{print $1}' /proc/swaps)
fi

if [[ -r /etc/fstab ]]; then
  while read -r ref; do
    dev="$(resolve_ref "$ref")"
    [[ -n "$dev" && "$dev" == /dev/* ]] || continue
    is_block "$dev" || continue
    mark_disk_parent "$dev" "fstab"
  done < <(awk '!/^#/ && NF>=2 {print $1}' /etc/fstab | sort -u)
fi

mapfile -t _ALL_DISKS < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

log "---- Exclusion report (OS / in-use) ----"
for d in "${_ALL_DISKS[@]}"; do
  if [[ -n "${_UNSAFE[$d]:-}" ]]; then
    log "Exclude /dev/${d} -> ${_UNSAFE[$d]}"
  fi
done
log "----------------------------------------"

SAFE=()
for d in "${_ALL_DISKS[@]}"; do
  if [[ -z "${_UNSAFE[$d]:-}" ]]; then 
    SAFE+=("/dev/${d}")
  fi
done

if [[ ${#SAFE[@]} -eq 0 ]]; then
  log "No SAFE disks were found. Exit."
  exit 0
fi

log "SAFE targets: ${SAFE[*]}"
log "WARNING: Destructive fio on: ${SAFE[*]}"
if [[ "${YES_I_UNDERSTAND:-0}" != "1" ]]; then
  read -r -p "Type YES to proceed: " _ans || true
  if [[ "${_ans:-}" != "YES" ]]; then 
    log "Cancelled."
    exit 0
  fi
fi

for (( loop_n=1; loop_n<=_loops_this_run; loop_n++ )); do
  echo "------------------------------------------------------------"
  echo "[$(counter_next_tag)] Disk test..."
  km="$(counter_next_tag)"
  k="${km%%/*}"
  mm="${km##*/}"
  log "----- Iteration ${k} of ${mm} -----"

  n="${k}"   # 這一輪的編號（避免覆蓋）
  for dev in "${SAFE[@]}"; do
    _short="${dev#/dev/}"
    log "[RUN] ${dev} (loop ${n})"
    run_fio "$dev" "${_short}_SEQ1MQ8T1_Read_${n}_of_${_target_loop}.log"   --rw=read      --bs=1m --iodepth=8  --numjobs=1 --size=1g --runtime=5
    run_fio "$dev" "${_short}_SEQ1MQ8T1_Write_${n}_of_${_target_loop}.log"  --rw=write     --bs=1m --iodepth=8  --numjobs=1 --size=1g --runtime=5
    run_fio "$dev" "${_short}_SEQ1MQ1T1_Read_${n}_of_${_target_loop}.log"   --rw=read      --bs=1m --iodepth=1  --numjobs=1 --size=1g --runtime=5
    run_fio "$dev" "${_short}_SEQ1MQ1T1_Write_${n}_of_${_target_loop}.log"  --rw=write     --bs=1m --iodepth=1  --numjobs=1 --size=1g --runtime=5
    run_fio "$dev" "${_short}_RND4KQ32T1_Read_${n}_of_${_target_loop}.log"  --rw=randread  --bs=4k --iodepth=32 --numjobs=1 --size=1g --runtime=5
    run_fio "$dev" "${_short}_RND4KQ32T1_Write_${n}_of_${_target_loop}.log" --rw=randwrite --bs=4k --iodepth=32 --numjobs=1 --size=1g --runtime=5
    run_fio "$dev" "${_short}_RND4KQ1T1_Read_${n}_of_${_target_loop}.log"   --rw=randread  --bs=4k --iodepth=1  --numjobs=1 --size=1g --runtime=5
    run_fio "$dev" "${_short}_RND4KQ1T1_Write_${n}_of_${_target_loop}.log"  --rw=randwrite --bs=4k --iodepth=1  --numjobs=1 --size=1g --runtime=5
  done    

# ---------- Summary ----------
: > "${_disksum}"
extract_bw() {
  local _kind="$1" _file="$2"
  grep -iE "^\s*${_kind,,}:" "$_file" \
    | sed -n 's/.*bw=\([0-9.]\+\)[KMG]i\?B\/s (\([0-9.]\+\)[KMG]B\/s.*/\1 \2/p' \
    | head -n1
}

for dev in "${SAFE[@]}"; do
  _short="${dev#/dev/}"
  {
    echo "Disk: $_short"
    patterns=(
      "SEQ1MQ8T1 Read"
      "SEQ1MQ8T1 Write"
      "SEQ1MQ1T1 Read"
      "SEQ1MQ1T1 Write"
      "RND4KQ32T1 Read"
      "RND4KQ32T1 Write"
      "RND4KQ1T1 Read"
      "RND4KQ1T1 Write"
    )
    for item in "${patterns[@]}"; do
      base="${item%% *}"
      _kind="${item##* }"
      mib_total=0; mb_total=0; cnt=0
      for ((n=1;n<=_m;n++)); do
        for f in "${log_root}/${_short}_${base}_${_kind}_${n}_of_"*.log; do
          [[ -f "$f" ]] || continue
          v="$(extract_bw "$_kind" "$f")"
          [[ -n "$v" ]] || continue

          mib="$(echo "$v" | awk '{print $1}')"
          mb="$(echo "$v"  | awk '{print $2}')"

          # 加總（用 awk 避免 bash 浮點）
          mib_total=$(awk -v a="$mib_total" -v b="$mib" 'BEGIN{print a+b}')
          mb_total=$(awk -v a="$mb_total" -v b="$mb"  'BEGIN{print a+b}')
          cnt=$((cnt+1))
        done
      done
      if [[ $cnt -gt 0 ]]; then
        mib_avg=$(awk -v a="$mib_total" -v c="$cnt" 'BEGIN{printf "%.3f", a/c}')
        mb_avg=$(awk -v a="$mb_total" -v c="$cnt" 'BEGIN{printf "%.3f", a/c}')
        printf "  %-18s %-5s : avg=%s MiB/s (%s MB/s)\n" "$base" "$_kind" "$mib_avg" "$mb_avg"
      else
        printf "  %-18s %-5s : no data\n" "$base" "$_kind"
      fi
    done
    echo
  } >> "${_disksum}"
done

counter_tick

done  # for loop_n
echo "" | tee -a "${_disklog}"
elp_time | tee -a "${_disklog}"
log "Summary written to: ${_disksum}"
