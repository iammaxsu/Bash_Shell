#!/usr/bin/env bash
# disk_test.sh — single-log style but with unified filename
set -euo pipefail

_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
_entry_dir="$(cd "$(dirname "$_entry")" && pwd)"
_try_source() { local f="$1"; if [[ -f "${_entry_dir}/${f}" ]]; then . "${_entry_dir}/${f}"; elif [[ -f "/home/${USER}/Downloads/${f}" ]]; then . "/home/${USER}/Downloads/${f}"; else echo "FATAL: cannot source ${f}" >&2; exit 1; fi; }
_try_source "config.sh"; _try_source "function.sh"

required_fn="00.00.01"; if [[ "${_function_api_version:-}" != "$required_fn" ]]; then echo "FATAL: function.sh API=${_function_api_version:-<unset>}, require ${required_fn}" >&2; exit 64; fi

log_folder; session_start; cycles_init "disk_test" "${_bootCycle:-1000}"

# unified log filename (replaces _disklog)
summary="$(build_log_name disk_test Init)"
exec > >(tee -a "${summary}") 2>&1

log "==== disk_test.sh ===="
log "Script   : ${_entry}"
log "LogPath  : ${_logPath}"
log "Loops    : ${_bLoops:-1}"
log "======================="

# ensure fio
command -v fio >/dev/null 2>&1 || {
  if command -v apt >/dev/null 2>&1; then sudo apt update -y && sudo apt install -y fio
  elif command -v yum >/dev/null 2>&1; then sudo yum install -y fio
  elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y fio
  fi
}

log "Stage: Collect mounted block sources"
mapfile -t all_disks < <(lsblk -ln -o NAME,TYPE | awk '$2=="disk"{print $1}')
declare -A unsafe=()
while read -r name mnt; do
  [[ -n "$mnt" ]] || continue
  parent="${name%[0-9]*}"; [[ "$name" == nvme* && "$name" == *p* ]] && parent="${name%p*}"
  unsafe["$parent"]="critical:${mnt} source:/dev/${name}"
done < <(lsblk -o NAME,MOUNTPOINT | awk 'NR>1 && $2!="" {print $1, $2}')

echo "---- Exclusion report (OS / in-use) ----"
for k in "${!unsafe[@]}"; do echo "Exclude /dev/${k} -> reason:${unsafe[$k]}"; done
echo "----------------------------------------"

targets=()
for d in "${all_disks[@]}"; do [[ -z "${unsafe[$d]:-}" ]] && targets+=("/dev/${d}"); done
log "SAFE targets: ${targets[*]:-<none>}"

if (( ${#targets[@]} == 0 )); then
  echo "No safe disks found. Abort."
  res="Fail"
  final="$(build_log_name disk_test "${res}")"; mv -f "$summary" "$final"
  run_time; elp_time | tee -a "$final"
  exit 1
fi

echo "WARNING: Destructive fio on: ${targets[*]}"
read -r -p "Type YES to proceed: " ack
if [[ "$ack" != "YES" ]]; then
  echo "User cancelled."
  res="Cancel"
  final="$(build_log_name disk_test "${res}")"; mv -f "$summary" "$final"
  run_time; elp_time | tee -a "$final"
  exit 0
fi

failed=0; loops="${_bLoops:-1}"
for ((n=1;n<=loops;n++)); do
  echo "=== FIO Loop ${n}/${loops} ==="
  for dev in "${targets[@]}"; do
    bname="${dev#/dev/}"
    log "[RUN] ${dev} (loop ${n})"
    if ! fio --filename="${dev}" --name=write --rw=write --bs=1M --iodepth=8 --numjobs=1 --size=1G --runtime=60 --output="${bname}_fio_$(now_ts).log"; then
      failed=1
    fi
  done
done

cycles_mark_done "disk_test" 1
res="Pass"; [[ $failed -eq 1 ]] && res="Fail"
final="$(build_log_name disk_test "${res}")"; mv -f "$summary" "$final"
run_time; elp_time | tee -a "$final"
echo "[RESULT] ${res}" | tee -a "$final"
