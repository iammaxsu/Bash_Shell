#!/usr/bin/env bash
# config.sh — shared parameters for disk_test.sh & sleep_test.sh
# - Defines timestamps, persistent counters, disk log defaults
# - Records _SESSION_T0 for elapsed fallback
# - Manages _bLoops prompt unless DISABLE_LOOPS_PROMPT=1
# - Provides default sleep timing params:
#     _sleep_delay_after_boot (default 40s)
#     _sleep_wake_after_sec   (default 60s)
set -Eeuo pipefail

export _config_api_version
: "${_config_api_version:="00.00.01"}"

setup_session() {
  # Session start (for elapsed fallback)
  #export _SESSION_T0="$(date +%s)"
  export _session_t0="$(date +%s)"      # some tests use ${_session_t0} for elapsed time

  # Timestamps
  export _date_format1="$(date '+%Y-%m-%d_%H-%M-%S')"

  export _date_format2="$(date '+%Y%m%d%H%M%S')"
  #export date2="${_date2}"   # some tests use ${date2} in filenames

  # Ensure log path (function.sh/log_folder normally sets this)
  #: "${_log_folder:=${PWD}/logs}"
  #mkdir -p "${_log_folder}"

  # Persistent counter for sleep test iteration filenames
  export _count_file="${_log_folder}/counter.log"
  if [[ -f "${_count_file}" ]]; then
    local _last
    : "${_last:="$(tail -n1 "${_count_file}" 2>/dev/null | tr -dc '0-9')"}"
    if [[ -n "${_last}" ]]; then 
    export _count="${_last}"
    else
      export _count=0
      echo "${_count}" > "${_count_file}"
    fi
  else
    export _count=0
    echo "${_count}" > "${_count_file}"
  fi

  # Disk test defaults
  export _disklog="${_disklog:-disk_test_${_date_format2}.log}"
  : "${YES_I_UNDERSTAND:=0}" ; export YES_I_UNDERSTAND

  # Sleep timing defaults (can be overridden by environment before calling setup_session)
  : "${_sleep_delay_after_boot:=40}"
  : "${_sleep_wake_after_sec:=60}"
  export _sleep_delay_after_boot _sleep_wake_after_sec
}
  # Loops parameter for test scripts 
#  if [[ -z "${_bLoops:-}" ]]; then
#    if [[ "${DISABLE_LOOPS_PROMPT:-0}" != "1" ]]; then
#      # interactive prompt (default 1000) for disk tests
#      echo -n "How many cycles to run the test? (default: 1000): "
#      read -r _bLoops_input || true
#      if [[ -z "${_bLoops_input:-}" ]]; then
#        export _bLoops=1000
#      elif [[ "${_bLoops_input}" =~ ^[0-9]+$ && "${_bLoops_input}" -ge 1 ]]; then
#        export _bLoops="${_bLoops_input}"
#      else
#        echo "Invalid input '${_bLoops_input}', use default 1000"
#        export _bLoops=1000
#      fi
#    else
#      # non-interactive default to keep env consistent
#      export _bLoops="${_bLoops:-1000}"
#    fi
#  fi
#}