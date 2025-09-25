#!/usr/bin/env bash
# config.sh — shared parameters (cleaned to use only _date2)
_config_api_version="00.00.01"

setup_session() {
  # Session start (for elapsed fallback)
  export _SESSION_T0="$(date +%s)"

  # Timestamps (single source of truth)
  export _date1="$(date '+%Y-%m-%d_%H-%M-%S')"
  export _date2="$(date '+%Y%m%d%H%M%S')"
  # (legacy alias removed)  # export date2="${_date2}"

  # Ensure log path (function.sh/log_folder normally sets this)
  : "${_logPath:=${PWD}/logs}"
  mkdir -p "${_logPath}"

  # Persistent counter for sleep test iteration filenames
  export _count_file="${_logPath}/sleep_count.txt"
  if [[ -f "${_count_file}" ]]; then
    local last; last="$(tail -n1 "${_count_file}" 2>/dev/null | tr -dc '0-9')"
    if [[ -n "${last}" ]]; then export _count="${last}"; else export _count=0; echo "${_count}" > "${_count_file}"; fi
  else
    export _count=0
    echo "${_count}" > "${_count_file}"
  fi

  # Disk test defaults
  export _disklog="${_disklog:-disk_test_${_date2}.log}"
  : "${YES_I_UNDERSTAND:=0}" ; export YES_I_UNDERSTAND

  # Sleep timing defaults (can be overridden by environment before calling setup_session)
  : "${_sleep_delay_after_boot:=40}"
  : "${_sleep_wake_after_sec:=60}"
  export _sleep_delay_after_boot _sleep_wake_after_sec

  # Loops parameter for disk_test.sh (sleep_test.sh has its own loops)
  if [[ -z "${_bLoops:-}" ]]; then
    if [[ "${DISABLE_LOOPS_PROMPT:-0}" != "1" ]]; then
      echo -n "How many cycles to run the test? (default: 1000): "
      read -r _bLoops_input || true
      if [[ -z "${_bLoops_input:-}" ]]; then
        export _bLoops=1000
      elif [[ "${_bLoops_input}" =~ ^[0-9]+$ && "${_bLoops_input}" -ge 1 ]]; then
        export _bLoops="${_bLoops_input}"
      else
        echo "Invalid input '${_bLoops_input}', use default 1000"
        export _bLoops=1000
      fi
    else
      export _bLoops="${_bLoops:-1000}"
    fi
  fi
}
