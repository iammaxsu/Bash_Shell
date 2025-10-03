#!/usr/bin/env bash
# disk_test.sh — depends on config.sh & function.sh, with robust logging and fixed summary

#set -uo pipefail  # no `-e` to avoid early aborts
set -Eeuo pipefail

export _disk_test_version
: "${_disk_test_version:="00.00.01"}"

# ---------- Locate & source companions (REQUIRED) ----------
_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
_entry_dir="$(cd "$(dirname "$_entry")" && pwd)"

find_and_source() {
  local name="$1"
  if [[ -f "${_entry_dir}/${name}" ]]; then . "${_entry_dir}/${name}"; return 0; fi
  if [[ -f "/home/${USER}/Downloads/${name}" ]]; then . "/home/${USER}/Downloads/${name}"; return 0; fi
  echo "FATAL: cannot find ${name}. Please place it next to disk_test.sh or in ~/Downloads." >&2
  exit 1
}

find_and_source "function.sh"
find_and_source "config.sh"

parse_loops_arg "${1:-}"

# ---------- Init logs & session ----------
log_folder   || true   # from function.sh
setup_session || true  # from config.sh

: "${_date_format2:?Missing. Please set _date_format2 in config.sh (setup_session).}"
: "${_bLoops:?Missing. Please set _bLoops in config.sh (e.g., _bLoops=10).}"
: "${_disklog:?Missing. Please set _disklog in config.sh (e.g., disk_test_${_date_format2}.log).}"

log() { echo "[$(date '+%F %T')] $*" | tee -a "${_disklog}"; }

log "==== disk_test.sh (from config/function) ===="
log "Script   : ${_entry}"
log "LogPath  : ${PWD}"
log "Loops    : ${_bLoops}"
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
  if [[ -z "${_UNSAFE[$d]:-}" ]]; then SAFE+=("/dev/${d}"); fi
done

if [[ ${#SAFE[@]} -eq 0 ]]; then
  log "No SAFE disks were found. Exit."
  exit 0
fi

log "SAFE targets: ${SAFE[*]}"
log "WARNING: Destructive fio on: ${SAFE[*]}"
if [[ "${YES_I_UNDERSTAND:-0}" != "1" ]]; then
  read -r -p "Type YES to proceed: " _ans || true
  if [[ "${_ans:-}" != "YES" ]]; then log "Cancelled."; exit 0; fi
fi

for (( loop_n=1; loop_n<=_bLoops; loop_n++ )); do
    echo "------------------------------------------------------------"
    echo "[$loop_n/$_bLoops] Disk test..."
# ---------- FIO patterns ----------
    run_fio(){ local dev="$1" out="$2"; shift 2; sudo fio --filename="$dev" --group_reporting --name=test --output="$out" --direct=1 "$@"; }

    loops="${_bLoops}"
    for ((n=1;n<=loops;n++)); do
      log "=== FIO Loop ${n}/${loops} ==="
      for dev in "${SAFE[@]}"; do
        short="${dev#/dev/}"; log "[RUN] ${dev} (loop ${n})"
        run_fio "$dev" "seq_r_1M_Q8T1_${n}_${short}.log"   --rw=read      --bs=1M --iodepth=8  --numjobs=1 --size=1G --runtime=30
        run_fio "$dev" "seq_w_1M_Q8T1_${n}_${short}.log"   --rw=write     --bs=1M --iodepth=8  --numjobs=1 --size=1G --runtime=30
        run_fio "$dev" "seq_r_1M_Q1T1_${n}_${short}.log"   --rw=read      --bs=1M --iodepth=1  --numjobs=1 --size=1G --runtime=30
        run_fio "$dev" "seq_w_1M_Q1T1_${n}_${short}.log"   --rw=write     --bs=1M --iodepth=1  --numjobs=1 --size=1G --runtime=30
        run_fio "$dev" "rnd_r_4K_Q32T1_${n}_${short}.log"  --rw=randread  --bs=4k --iodepth=32 --numjobs=1 --size=1G --runtime=30
        run_fio "$dev" "rnd_w_4K_Q32T1_${n}_${short}.log"  --rw=randwrite --bs=4k --iodepth=32 --numjobs=1 --size=1G --runtime=30
        run_fio "$dev" "rnd_r2_4K_Q32T1_${n}_${short}.log" --rw=randread  --bs=4k --iodepth=32 --numjobs=1 --size=1G --runtime=30
        run_fio "$dev" "rnd_w2_4K_Q32T1_${n}_${short}.log" --rw=randwrite --bs=4k --iodepth=32 --numjobs=1 --size=1G --runtime=30
      done
    done

    # ---------- Summary ----------
    summary_file="disk_summary_${_date_format2}.log"; : > "${summary_file}"
    extract_bw(){ grep -E "^\s*$1:" "$2" | sed -n 's/.*bw=\([0-9.]\+\)[KMG]i\?B\/s (\([0-9.]\+\)[KMG]B\/s.*/\1 \2/p' | head -n1; }

    for dev in "${SAFE[@]}"; do
      short="${dev#/dev/}"
      {
        echo "Disk: $short"
        patterns=(
          "seq_r_1M_Q8T1 READ"
          "seq_w_1M_Q8T1 WRITE"
          "seq_r_1M_Q1T1 READ"
          "seq_w_1M_Q1T1 WRITE"
          "rnd_r_4K_Q32T1 READ"
          "rnd_w_4K_Q32T1 WRITE"
          "rnd_r2_4K_Q32T1 READ"
          "rnd_w2_4K_Q32T1 WRITE"
        )
        for item in "${patterns[@]}"; do
          base="${item%% *}"
          kind="${item##* }"
          mib_total=0; mb_total=0; cnt=0
          for ((n=1;n<=loops;n++)); do
            f="${base}_${n}_${short}.log"
            if [[ -f "$f" ]]; then
              v="$(extract_bw "$kind" "$f")"
              if [[ -n "$v" ]]; then
                mib="$(echo "$v" | awk '{print $1}')"; mb="$(echo "$v" | awk '{print $2}')"
                mib_total=$(awk -v a="$mib_total" -v b="$mib" 'BEGIN{print a+b}')
                mb_total=$(awk -v a="$mb_total" -v b="$mb" 'BEGIN{print a+b}')
                cnt=$((cnt+1))
              fi
            fi
          done
          if [[ $cnt -gt 0 ]]; then
            mib_avg=$(awk -v a="$mib_total" -v c="$cnt" 'BEGIN{printf "%.3f", a/c}')
            mb_avg=$(awk -v a="$mb_total" -v c="$cnt" 'BEGIN{printf "%.3f", a/c}')
            printf "  %-18s %-5s : avg=%s MiB/s (%s MB/s)\n" "$base" "$kind" "$mib_avg" "$mb_avg"
          else
            printf "  %-18s %-5s : no data\n" "$base" "$kind"
          fi
        done
        echo
      } >> "${summary_file}"
    done
done

run_time || true
echo "" | tee -a "${_disklog}"
elp_time | tee -a "${_disklog}"
log "Summary written to: ${summary_file}"
