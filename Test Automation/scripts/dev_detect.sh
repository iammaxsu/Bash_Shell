#!/usr/bin/env bash
# dev_detect.sh — unified log naming; single snapshot log per run; lshw_short only
set -euo pipefail

_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
_entry_dir="$(cd "$(dirname "$_entry")" && pwd)"
_try_source() { local f="$1"; if [[ -f "${_entry_dir}/${f}" ]]; then . "${_entry_dir}/${f}"; elif [[ -f "/home/${USER}/Downloads/${f}" ]]; then . "/home/${USER}/Downloads/${f}"; else echo "FATAL: cannot source ${f}" >&2; exit 1; fi; }
_try_source "config.sh"; _try_source "function.sh"

log_folder; session_start; cycles_init "dev_detect" "${_bootCycle:-1000}"
summary="$(build_log_name dev_detect Init)"

{
  echo "==== Device Detection (dev_detect.sh) ===="
  echo "Script   : ${_entry}"
  echo "LogPath  : ${_logPath}"
  echo "Date     : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Cycles   : total=${CYC_TOTAL} done=${CYC_DONE} remaining=$(cycles_remaining dev_detect)"
  echo "=========================================="
} | tee -a "$summary"

# snapshot log (this is the only snapshot file we keep)
snap="$(build_log_name dev_detect Init)"
collect_dev_snapshot "${snap}"
echo "[INFO] snapshot/log: ${_logPath}/${snap}" | tee -a "$summary"

# lshw short only
ts_now="$(now_ts)"
collect_lshw_logs "${ts_now}"
if [[ -f "lshw_short_${ts_now}.log" ]]; then
  mv -f "lshw_short_${ts_now}.log" "$(build_log_name lshw_short Info)"
  echo "[INFO] lshw_short: $(build_log_name lshw_short Info)" | tee -a "$summary"
fi

golden="dev_detect_golden.log"
diff_out="$(build_log_name dev_detect_diff Info)"
if [[ ! -f "${golden}" ]]; then
  cp -f "${snap}" "${golden}"
  echo "[INIT] golden created: ${_logPath}/${golden}" | tee -a "$summary"
  # also emit a result log for first run
  if diff -u "${golden}" "${snap}" > "${diff_out}"; then res="Pass"; else res="Fail"; fi
  mv -f "${snap}" "$(build_log_name dev_detect "${res}")"
  echo "[INFO] first-run result: ${res}" | tee -a "$summary"
else
  if compare_dev_snapshot "${snap}" "${golden}" "${diff_out}"; then res="Pass"; echo "[PASS] match golden" | tee -a "$summary"; else res="Fail"; echo "[FAIL] differ -> ${diff_out}" | tee -a "$summary"; fi
  mv -f "${snap}" "$(build_log_name dev_detect "${res}")"
fi

cycles_mark_done "dev_detect" 1
run_time; elp_time | tee -a "$summary"
echo "[RESULT] ${res:-Init}" | tee -a "$summary"
