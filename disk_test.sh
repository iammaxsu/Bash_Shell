#!/usr/bin/env bash
# disk_test.sh — Safe FIO with OS‑disk isolation (sturdy)
# - Normalizes device paths (no /dev//dev/...)
# - Excludes entire parent disk for /, /boot, /boot/efi, mounted devs, swap (block), and fstab (UUID/PARTUUID/dev)
# - Avoids premature aborts: no `set -e`, no ERR trap; explicit `|| true` where needed

set -uo pipefail

_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
_entry_dir="$(cd "$(dirname "$_entry")" && pwd)"

try_source() {
  local f="$1"
  if [[ -f "${_entry_dir}/$f" ]]; then . "${_entry_dir}/$f"; return 0
  elif [[ -f "/home/${USER}/Downloads/$f" ]]; then . "/home/${USER}/Downloads/$f"; return 0
  fi
  return 1
}

if ! try_source "function.sh"; then
  log_folder() { mkdir -p "${_entry_dir}/logs"; _toolPath="${_entry_dir}"; _logPath="${_entry_dir}/logs"; cd "${_logPath}"; }
  run_time(){ :; }; elp_time(){ :; }
fi
if ! try_source "config.sh"; then
  _bLoops="${_bLoops:-1}"; _date2="$(date '+%Y%m%d%H%M%S')"; setup_session(){ :; }
fi

log_folder || true
setup_session || true

sudo_run() { if [[ -n "${_pwd:-}" ]]; then echo "${_pwd}" | sudo -S "$@"; else sudo "$@"; fi; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
ensure_cmd(){
  local bin="$1"
  if ! need_cmd "$bin"; then
    if [[ -f /etc/debian_version ]]; then
      sudo_run apt-get update -y || true
      sudo_run DEBIAN_FRONTEND=noninteractive apt-get install -y "$bin" || true
    elif [[ -f /etc/redhat-release ]]; then
      sudo_run yum install -y "$bin" || true
    fi
  fi
}

ensure_cmd lsblk
ensure_cmd findmnt
need_cmd blkid || true
need_cmd fio   || true

_disklog="${_disklog:-disk_test_${_date2:-$(date +%Y%m%d%H%M%S)}.log}"
{
  echo "==== disk_test.sh (safe, sturdy) ===="
  echo "Time     : $(date '+%F %T')"
  echo "Script   : ${_entry}"
  echo "LogPath  : ${PWD}"
  echo "Loops    : ${_bLoops:-1}"
  echo "====================================="
} | tee -a "${_disklog}"

# ---------- Helpers ----------
normalize_dev() {
  local n="$1"
  # strip all leading /dev/
  while [[ "$n" == /dev/* ]]; do n="${n#/dev/}"; done
  [[ -z "$n" ]] && return 1
  echo "/dev/${n}"
}

is_block() {
  local n; n="$(normalize_dev "$1" 2>/dev/null || true)"
  [[ -n "$n" ]] || return 1
  lsblk -dn -o NAME "$n" &>/dev/null
}

resolve_ref() {
  local ref="$1"
  if [[ "$ref" == UUID=* ]]; then
    local uuid="${ref#UUID=}"; uuid="${uuid//\"/}"
    blkid -U "$uuid" 2>/dev/null || echo ""
  elif [[ "$ref" == PARTUUID=* ]]; then
    local pu="${ref#PARTUUID=}"; pu="${pu//\"/}"
    blkid -t PARTUUID="$pu" -o device 2>/dev/null || echo ""
  else
    echo "$ref"
  fi
}

parents_to_disks() {
  local node="$1"
  node="$(normalize_dev "$node" 2>/dev/null || true)"
  [[ -n "$node" ]] || return 0
  if ! is_block "$node"; then return 0; fi

  local t; t="$(lsblk -no TYPE "$node" 2>/dev/null || echo "")"
  if [[ "$t" == "disk" ]]; then basename "$node"; return; fi

  declare -A seen=(); local q=("$node")
  while ((${#q[@]})); do
    local cur="${q[0]}"; q=("${q[@]:1}")
    [[ -n "${seen[$cur]:-}" ]] && continue; seen["$cur"]=1
    while IFS= read -r line; do
      local name type pk; name="$(awk '{print $1}' <<<"$line")"; type="$(awk '{print $2}' <<<"$line")"; pk="$(awk '{print $3}' <<<"$line")"
      if [[ "$name" == "$cur" ]]; then
        if [[ "$type" == "disk" ]]; then basename "$name"
        elif [[ -n "$pk" && "$pk" != "-" ]]; then
          IFS=',' read -ra pks <<<"$pk"
          for p in "${pks[@]}"; do [[ -n "$p" ]] && q+=("$(normalize_dev "$p")"); done
        fi
      fi
    done < <(lsblk -nrpo NAME,TYPE,PKNAME "$cur" 2>/dev/null || true)
  done | sed 's|/dev/||' | sort -u
}

mark_disk_parent() {
  local src="$1"; local why="$2"
  [[ -z "$src" ]] && return
  local dev; dev="$(resolve_ref "$src")"
  [[ -z "$dev" ]] && dev="$src"
  dev="$(normalize_dev "$dev" 2>/dev/null || true)"
  [[ -n "$dev" ]] || return
  if ! is_block "$dev"; then echo "Skip non-block source: ${src} (${why})" | tee -a "${_disklog}"; return; fi
  while IFS= read -r d; do [[ -n "$d" ]] && _UNSAFE["$d"]="reason:${why} source:${src}"; done < <(parents_to_disks "$dev")
}

declare -A _UNSAFE=()

# Mounted block sources only
while IFS= read -r src; do
  [[ "$src" == /dev/* ]] || continue
  is_block "$src" || continue
  mark_disk_parent "$src" "mounted"
done < <(findmnt -rn -o SOURCE 2>/dev/null | sort -u)

# Critical mountpoints: force-check
for mp in / /boot /boot/efi; do
  src="$(findmnt -nr -o SOURCE --target "$mp" 2>/dev/null || true)"
  [[ -n "$src" ]] && mark_disk_parent "$src" "critical:${mp}"
done

# Active swap (block only)
if [[ -r /proc/swaps ]]; then
  awk 'NR>1{print $1}' /proc/swaps | while read -r sw; do
    [[ "$sw" == /dev/* ]] || continue
    is_block "$sw" || continue
    mark_disk_parent "$sw" "swap"
  done
fi

# fstab (resolve UUID/PARTUUID then block-only)
if [[ -r /etc/fstab ]]; then
  awk '!/^#/ && NF>=2 {print $1}' /etc/fstab | sort -u | while read -r ref; do
    dev="$(resolve_ref "$ref")"
    [[ -n "$dev" && "$dev" == /dev/* ]] || continue
    is_block "$dev" || continue
    mark_disk_parent "$dev" "fstab"
  done
fi

# Candidate disks
mapfile -t _ALL_DISKS < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
SAFE=()
echo "---- Exclusion report (OS/in-use disks) ----" | tee -a "${_disklog}"
for d in "${_ALL_DISKS[@]}"; do
  if [[ -n "${_UNSAFE[$d]:-}" ]]; then
    echo "Exclude /dev/${d} -> ${_UNSAFE[$d]}" | tee -a "${_disklog}"
  else
    SAFE+=("/dev/${d}")
  fi
done
echo "--------------------------------------------" | tee -a "${_disklog}"

if [[ ${#SAFE[@]} -eq 0 ]]; then
  echo "No SAFE disks were found. Exit." | tee -a "${_disklog}"
  exit 0
fi

echo "SAFE targets: ${SAFE[*]}" | tee -a "${_disklog}"
echo "WARNING: Destructive fio tests on: ${SAFE[*]}"
if [[ "${YES_I_UNDERSTAND:-0}" != "1" ]]; then
  read -r -p "Type YES to proceed: " _ans || true
  if [[ "${_ans:-}" != "YES" ]]; then
    echo "Cancelled." | tee -a "${_disklog}"
    exit 0
  fi
fi

run_fio(){ local dev="$1" out="$2"; shift 2; sudo_run fio --filename="$dev" --group_reporting --name=test --output="$out" --direct=1 "$@"; }

loops="${_bLoops:-1}"
for ((n=1;n<=loops;n++)); do
  echo "=== FIO Loop ${n}/${loops} ===" | tee -a "${_disklog}"
  for dev in "${SAFE[@]}"; do
    short="${dev#/dev/}"; echo "[RUN] ${dev} (loop ${n})" | tee -a "${_disklog}"
    run_fio "$dev" "seq_r_${n}_${short}.log" --rw=read --bs=1M --iodepth=8 --size=1G --runtime=30
    run_fio "$dev" "seq_w_${n}_${short}.log" --rw=write --bs=1M --iodepth=8 --size=1G --runtime=30
  done
done

run_time || true; echo | tee -a "${_disklog}"; elp_time | tee -a "${_disklog}"
echo "Logs written to: ${PWD}" | tee -a "${_disklog}"
