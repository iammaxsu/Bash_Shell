#!/usr/bin/env bash
set -Eeuo pipefail

export _dev_detect_version
: "${_dev_detect_version:="00.00.01"}"
#: "${_dev_detect_requires_config_api_version:=00.00.01}"
#: "${_dev_detect_requires_function_api_version:=00.00.01}"

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

#_function_require_versions "${_dev_detect_test_name}" "${_dev_detect_requires_config_api_version}" "${_dev_detect_requires_function_api_version}" "${_dev_detect_api_version}"

: "${_dev_detect_total_loops:=${_dev_detect_default_loops}}"
if (( _dev_detect_total_loops < 1 )); then
  printf '[FATAL] Invalid loop count %s for %s\n' "${_dev_detect_total_loops}" "${_dev_detect_test_name}" >&2
  exit 10
fi

_function_resume_load "${_dev_detect_test_name}" "${_dev_detect_total_loops}"
if (( _resume_loop_start > _dev_detect_total_loops )); then
  echo "[INFO] ${_dev_detect_test_name}: previously completed ${_resume_last_completed}/${_dev_detect_total_loops} loops" >&2
  exit 0
fi

_overall_result="${_default_result_token_pass}"

for ((_dev_loop=_resume_loop_start; _dev_loop<=_dev_detect_total_loops; _dev_loop++)); do
  _function_set_testing_state "${_session_default_suspend_mode}" 1
  _loop_timestamp="$(date +"${_log_timestamp_format}")"
  _loop_start_epoch=$(_function_timer_start)
  _loop_log_tmp="${_logs_root_dir}/${_dev_detect_test_name}_${_dev_loop}_of_${_dev_detect_total_loops}_${_loop_timestamp}_tmp.log"
  : > "${_loop_log_tmp}"
  _loop_result="${_default_result_token_pass}"

  _log_msg() {
    printf '%s\n' "$*" | tee -a "${_loop_log_tmp}"
  }

  _log_msg "============================================================"
  _log_msg "Test       : ${_dev_detect_test_name}"
  _log_msg "Loop       : ${_dev_loop}/${_dev_detect_total_loops}"
  _log_msg "Timestamp  : ${_loop_timestamp}"
  _log_msg "Session ID : ${_session_id}"
  _log_msg "============================================================"

  _short_log_path="${_logs_root_dir}/${_dev_detect_test_name}_short_${_loop_timestamp}.log"
  _log_msg "[STEP] Collecting device snapshot -> ${_short_log_path}"
  if ! _dev_collect_inventory_snapshot "${_short_log_path}" >>"${_loop_log_tmp}" 2>&1; then
    _log_msg "[ERROR] Failed to collect inventory snapshot"
    _loop_result="${_default_result_token_fail}"
  fi

  _log_msg "[STEP] Collecting lshw logs"
  if ! _dev_collect_lshw_logs "${_loop_timestamp}" >>"${_loop_log_tmp}" 2>&1; then
    _log_msg "[WARN] lshw logs not collected"
  fi

  _golden_path="${_dev_detect_golden_template}"
  mkdir -p "$(dirname "${_golden_path}")"
  _diff_path="${_logs_root_dir}/${_dev_detect_test_name}_diff_${_loop_timestamp}.diff"

  if [[ ! -f "${_golden_path}" ]]; then
    cp -f "${_short_log_path}" "${_golden_path}"
    _log_msg "[INIT] Golden template created at ${_golden_path}"
    _loop_result="INIT"
  else
    if _dev_compare_with_golden "${_short_log_path}" "${_golden_path}" "${_diff_path}"; then
      _log_msg "[PASS] Snapshot matches golden template"
    else
      _log_msg "[FAIL] Snapshot differs from golden -> ${_diff_path}"
      _loop_result="${_default_result_token_fail}"
    fi
  fi

# ---------- Component Detection ----------
# ===== CPU =====
  if command -v lscpu >/dev/null 2>&1; then
    _cpu_model=$(lscpu | awk -F': +' '/Model name/{print $2; exit}')
    _cpu_count=$(lscpu | awk -F': +' '/^CPU\(s\)/{print $2; exit}')
  else
    _cpu_model="unknown"
    _cpu_count="unknown"
  fi
  
  if command -v nproc >/dev/null 2>&1; then
    _cpu_count=$(nproc)
  fi

  # ===== RAM =====
  if command -v free >/dev/null 2>&1; then
    _ram_total=$(free -h | awk '/^Mem:/{print $2}')
  else
    _ram_total="unknown"
  fi

  # ===== PCI/PCIe =====
  if command -v lspci >/dev/null 2>&1; then
    _net_count=$(lspci | grep -ci ethernet || true)
    _pcie_bandwidth=$(lspci -vv | awk '/LnkCap:/ {print $0}' | paste -sd '; ' -)
  else
    _net_count="N/A"
    _pcie_bandwidth=""
  fi

  # ===== USB =====
  if command -v lsusb >/dev/null 2>&1; then
    _usb_count=$(lsusb | wc -l)
  else
    _usb_count="N/A"
  fi

  # ===== Storage (SATA, NVMe, USB, etc.) =====
  if command -v lsblk >/dev/null 2>&1; then
    _disk_count=$(lsblk -dn -o NAME,TYPE | awk '$2=="disk"' | wc -l)
  else
    _disk_count="N/A"
  fi

  _log_msg "[INFO] CPU Model : ${_cpu_model:-unknown}"
  _log_msg "[INFO] CPU Count : ${_cpu_count:-unknown}"
  _log_msg "[INFO] RAM Total : ${_ram_total:-unknown}"
  _log_msg "[INFO] NIC Count : ${_net_count}"
  _log_msg "[INFO] USB Count : ${_usb_count}"
  _log_msg "[INFO] Disk Count: ${_disk_count}"

  if [[ -n "${_pcie_bandwidth}" ]]; then
    _log_msg "[INFO] PCIe Bandwidth: ${_pcie_bandwidth}"
  fi

  _function_set_testing_state "${_session_default_suspend_mode}" 0
  _function_resume_store "${_dev_detect_test_name}" "${_dev_loop}" "${_dev_detect_total_loops}"

  _elapsed_line=$(_function_elapsed_line "${_loop_start_epoch}")
  printf '%s\n' "${_elapsed_line}" | tee -a "${_loop_log_tmp}"

  _final_log_name=$(_config_build_test_log_name "${_dev_detect_test_name}" "${_dev_loop}" "${_dev_detect_total_loops}" "${_loop_result}" "${_loop_timestamp}")
  _loop_log_final="${_logs_root_dir}/${_final_log_name}"
  mv "${_loop_log_tmp}" "${_loop_log_final}"
  echo "[INFO] Loop log stored at ${_loop_log_final}"

  if [[ "${_loop_result}" != "${_default_result_token_pass}" ]]; then
    _overall_result="${_default_result_token_fail}"
  fi

done

if [[ "${_overall_result}" == "${_default_result_token_pass}" ]]; then
  _function_resume_clear "${_dev_detect_test_name}"
fi

echo "${_overall_result}"
if [[ "${_overall_result}" != "${_default_result_token_pass}" ]]; then
  exit 1
fi

exit 0
