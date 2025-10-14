#!/usr/bin/env bash
# function.sh ??hardened netns helpers for enp* pairs
# - Sanitize interface names
# - Bring links down + flush before moving
# - Move-back down/flush then up
# - Kill weird leftover namespace "ns_" and any empty file /run/netns/ns_
# - Verbose debug
set -Eeuo pipefail

export _function_api_version
: "${_function_api_version:="00.00.01"}"

# ---------- Logging & timing ----------
now_ts() {
  date +"${_log_timestamp_format}"
}

run_time() { export _RUN_T0="$(date +%s)"; }

elp_time() {
  if [[ $# -ge 2 ]]; then
    local start="$1" end="$2" sec=$(( end - start ))
    (( sec < 0 )) && sec=0
    printf "%02d:%02d:%02d\n" $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
  else
    local t0 now sec
    if [[ -n "${_RUN_T0:-}" ]]; then t0="${_RUN_T0}"
    elif [[ -n "${_session_t0:-}" ]]; then t0="${_session_t0}"
    else return 0; fi
    now="$(date +%s)"; sec=$(( now - t0 )); (( sec < 0 )) && sec=0
    printf "Elapsed: %02d:%02d:%02d\n" $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
  fi
}

# ---------- General CLI parameters: call parse_common_cli "$@" after sourcing ----------
# Support:
#   sticky | --sticky     : SESSION_POLICY=sticky
#   auto   | --auto       : SESSION_POLICY=auto (default)
#   -n | --force-new      : SESSION_FORCE_NEW=1
#   --session-id=ID       : specific session ID
#   --prefix=STR          : session prefix (default "session")
#   <number>              : loops count (default 1)
#   others                : preseve in REM_ARGS[]
parse_common_cli() {
  declare -ga REM_ARGS=()
  unset _target_loop

  while [[ $# -gt 0 ]]; do
    case "$1" in
      #sticky|--sticky)       export _session_policy="sticky"  ;;
      #auto|--auto)           export _session_policy="auto"    ;;
      #-n|--force-new)        export _session_force_new=1      ;;
      #--session-id=*)        export _session_id="${1#*=}"     ;;
      #--prefix=*)            export _session_prefix="${1#*=}" ;;
      # 1st number is the count of loops
      ''|*[!0-9]*)           REM_ARGS+=("$1") ;;      # non-number
      *)
        if [[ -z "${_target_loop:-}" ]]; then
          _target_loop="$1"
        else
          REM_ARGS+=("$1")
        fi
        ;;
    esac
    shift
  done

  : "${_target_loop:=1}"      # default: 1 loop
  #: "${_session_policy:=auto}"      # default policy
}

# ---------- Session directory & ID ----------
# Policy:
#   _session_policy=auto      (Default) Generate a new session ID when running the script. No persistence.
#   _session_policy=sticky      Share to read/write in <logs>/session_state/session.id. Reuse if exists.
# Control:
#   SESSION_FORCE_NEW=1   撘瑕??寞活嚗??? session.id ???
ensure_session_id() {
  : "${_session_prefix:=session}"
  : "${_session_policy:=auto}"      # option: auto|sticky
  
  # Locate or create session state directory
  local _base="${_session_log_dir:-${_log_dir:-${_tool_path:-$PWD}/logs}}"
  : "${_session_state_dir:=${_base}/session_state}"
  mkdir -p -- "${_session_state_dir}" || { echo "[FATAL] mkdir ${_session_state_dir} failed"; return 1; }
  local _sid_file="${_session_state_dir}/session.id"

  # 0) Force new session
  if [[ "${_session_force_new:-0}" == "1" ]]; then
    unset _session_id
    rm -f -- "${_sid_file}" 2>/dev/null || true
  fi 

  # 1) If have session ID
  if [[ -n "${_session_id:-}" ]]; then
    _session_id="${_session_id}"
    # sticky mode: write to file
    if [[ "${_session_policy}" == "sticky" ]]; then
      printf '%s\n' "${_session_id}" > "${_sid_file}"
    fi
    export _session_id
    return 0
  fi

  case "${_session_policy}" in
    auto)     # Generate new session each time
      if [[ -z "${_session_id:-}" ]]; then
        _session_id="${_session_prefix}_$(now_ts)_$$"
      fi
      export _session_id
      return 0
      ;;

    sticky)   # Reuse session if possible
      if [[ -s "${_sid_file}" ]]; then
        read -r _session_id < "${_sid_file}"
      else
        _session_id="${_session_prefix}_$(now_ts)_$$"
        printf '%s\n' "${_session_id}" > "${_sid_file}"
      fi
      export _session_id
      return 0
      ;;

    *)
      echo "[WARN] Unknown SESSION_POLICY='${_session_policy}', fallback to 'auto'." >&2
      if [[ -z "${_session_id:-}" ]]; then
        _session_id="${_session_prefix}_$(now_ts)_$$"
      fi
      export _session_id
      return 0
      ;;
  esac
}

clear_session_id() {
  # Remove session ID file unless sticky mode.
  if [[ "${_session_policy:-auto}" != "sticky" ]]; then
    rm -f -- "${_session_state_dir:-}/session.id" 2>/dev/null || true
  fi
  unset _session_id
}

log_dir() {
#  local caller="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
#  local base_dir
#  base_dir="$(cd "$(dirname "$(readlink -f "${caller}")")" && pwd)"
#  export _tool_path="${_tool_path:-${base_dir}}"
#  export _log_dir="${_tool_path}/logs"
#  mkdir -p "${_log_dir}"
#  cd "${_log_dir}" || return 1
  local _caller="${1:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"      # 1st parameter: caller script (default: caller of log_dir)
  local _use_session_dir="${2:-${LOGS_USE_SESSION_SUBDIR:-1}}"      # 2nd paramter: Use session subdir or not (default: 1). 
  local _root_override="${3:-}"     # 3rd parameter: override root path (default: auto-detect)

  local _base_dir
  _base_dir="$(cd "$(dirname "$(readlink -f "${_caller}")")" && pwd)"

  if [[ -n "${_root_override}" ]]; then
    _tool_path="$(readlink -f -- "${_root_override}")"
  else
    : "${_tool_path:=${_base_dir}}"
  fi
  export _tool_path

  : "${_log_dir:=${_tool_path}/logs}"
  : "${_session_log_dir:=${_log_dir}}"
  if [[ "${_use_session_dir}" == "1" ]]; then
    _session_log_dir="${_log_dir}/${_session_id:-pending}"
  fi

  mkdir -p -- "${_log_dir}" || { echo "[FATAL] mkdir ${_log_dir} failed"; return 1; }

  ensure_session_id || return 1

  if [[ "${_use_session_dir}" == "1" && "${_session_log_dir##*/}" == "pending" ]]; then
    _session_log_dir="${_log_dir}/${_session_id}"
  fi

  mkdir -p -- "${_session_log_dir}" || { echo "[FATAL] mkdir ${_session_log_dir} failed"; return 1;}

  export _log_dir _session_log_dir
  echo "[INFO] log dir: ${_log_dir}"
  echo "[INFO] session log dir: ${_session_log_dir}"
  export _now_timestamp="$(now_ts)"
  printf '%s\n' "${_log_dir}"
}

# ---------- loops arguement ----------
#parse_loops_arg() {
#  local _target_loops="${1:-1}"
#  if ! [[ "${_target_loops}" =~ ^[0-9]+$ ]] || [[ "${_target_loops}" -lt 1 ]]; then
#    echo "[FATAL] Invalid loop count: '${_target_loops}'. Using default: 1"
#    _target_loops=1
#  fi
#  export _bLoops="${_target_loops}"
#  echo "[INFO] Running ${_target_loops} time(s)"
#}

# ---------- Installers ----------
__is_debian_like() { [[ -f /etc/debian_version ]]; }
__is_redhat_like() { [[ -f /etc/redhat-release ]]; }
__pkg_install() {
  local pkg="$1"
  if __is_debian_like; then
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  elif __is_redhat_like; then
    if command -v dnf >/dev/null 2>&1; then sudo dnf install -y "$pkg"; else sudo yum install -y "$pkg"; fi
  else
    echo "[WARN] Unknown distro; please install '$pkg' manually"
    return 1
  fi
}
fio_install()     { command -v fio     >/dev/null 21>&1 && return 0; __pkg_install fio; }
ethtool_install() { command -v ethtool >/dev/null 2>&1 && return 0; __pkg_install ethtool; }
iperf3_install()  { command -v iperf3  >/dev/null 2>&1 && return 0; __pkg_install iperf3; }

# ---------- iperf3 control ----------
iperf3_is_running() { pgrep -f '(^|/| )iperf3( |$)' >/dev/null 2>&1; }
iperf3_stop_all() {
  if iperf3_is_running; then
    echo "[INFO] iperf3 running -> SIGTERM"; sudo pkill -TERM -f '(^|/| )iperf3( |$)' 2>/dev/null || true; sleep 0.4
  fi
  if iperf3_is_running; then
    echo "[WARN] iperf3 still running -> SIGKILL"; sudo pkill -KILL -f '(^|/| )iperf3( |$)' 2>/dev/null || true; sleep 0.2
  fi
  iperf3_is_running && { echo "[ERR] iperf3 still running"; return 1; }
  echo "[INFO] iperf3 stopped"
}
iperf3_del() { iperf3_stop_all "$@"; }

prepare_net_tools() {
  if [[ "${FEATURE_USE_NEW_NET_TOOLING:-0}" == "1" ]]; then
    echo "[INFO] FeatureFlag ON: ensure ethtool/iperf3 installed & stop running iperf3"
    ethtool_install || { echo "[ERR] ethtool install failed"; return 1; }
    iperf3_install  || { echo "[ERR] iperf3 install failed";  return 1; }
    iperf3_stop_all || { echo "[ERR] iperf3 stop failed";     return 1; }
  else
    echo "[INFO] FeatureFlag OFF: legacy net preparation"
  fi
}

# ---------- Netns (enp* only) ----------
unset _ethArray even_ethArray odd_ethArray
declare -ga _ethArray even_ethArray odd_ethArray

__sanitize_if() {
  # strip CR/LF and anything after '@' (e.g., vlan/master decorations)
  local in="$1"
  in="${in//$'\r'/}"; in="${in//$'\n'/}"
  in="${in%%@*}"
  # keep safe chars
  in="$(printf "%s" "$in" | sed 's/[^A-Za-z0-9_.:-]//g')"
  printf "%s" "$in"
}

__move_back_to_root() {
  local ifn="$(__sanitize_if "$1")" ns="ns_${ifn}"
  if ip netns list 2>/dev/null | grep -q -E "^${ns}\b"; then
    echo "[DEBUG] move-back ${ifn} from ${ns} -> root"
    sudo ip netns exec "${ns}" ip link set dev "${ifn}" down 2>/dev/null || true
    sudo ip netns exec "${ns}" ip addr flush dev "${ifn}" 2>/dev/null || true
    sudo ip netns exec "${ns}" ip link set "${ifn}" netns 1 2>/dev/null || true
    sudo ip link set dev "${ifn}" up 2>/dev/null || true
  fi
}

# ---------- Namespace Approach ----------
netns_del() {
  local found=0
  # delete literal stray ns_ first if present
  if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "ns_"; then
    echo "[WARN] removing stray namespace 'ns_'"
    sudo ip netns del ns_ 2>/dev/null || true
  fi
  sudo rm -f /run/netns/ns_ 2>/dev/null || true

  while read -r ns; do
    [[ -z "$ns" ]] && continue
    [[ "$ns" != ns_enp* ]] && continue
    found=1
    local ifn="${ns#ns_}"; ifn="$(__sanitize_if "$ifn")"
    __move_back_to_root "${ifn}"
    sudo ip netns del "$ns" >/dev/null 2>&1 || true
    echo "[INFO] deleted $ns"
  done < <(ip netns list 2>/dev/null | awk '{print $1}')
  (( found )) || echo "[INFO] no ns_enp* to delete"
  sleep 0.2
}

netns_add() {
  netns_del || true

  _ethArray=()
  # Use ip -o to get single-line per link; sanitize names
  while IFS= read -r name; do
    name="$(__sanitize_if "$name")"
    [[ -n "$name" ]] && _ethArray+=("$name")
  done < <(ip -o link show | awk -F': ' '{print $2}' | grep -E '^enp' | sort -n)

  local n=${#_ethArray[@]}
  echo "[DEBUG] root enp*: ${_ethArray[*]}"
  if (( n < 2 )); then
    echo "[FATAL] Need at least 2 enp* NICs in root; found $n"
    even_ethArray=(); odd_ethArray=()
    return 1
  fi

  even_ethArray=(); odd_ethArray=()
  local start=0
  (( n % 2 )) && start=1

  for ((i=start; i<n; i++)); do
    local ifn="${_ethArray[i]}"
    local ns="ns_${ifn}"
    echo "[DEBUG] prepare ${ifn} -> ${ns}"
    sudo ip link set dev "${ifn}" down 2>/dev/null || true
    sudo ip addr flush dev "${ifn}" 2>/dev/null || true
    ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "${ns}" && sudo ip netns del "${ns}" || true
    sudo ip netns add "${ns}"
    if ! sudo ip link set "${ifn}" netns "${ns}"; then
      echo "[ERR] fail move ${ifn} into ${ns}"
      continue
    fi
    if (( i % 2 == 0 )); then even_ethArray+=("${ifn}"); else odd_ethArray+=("${ifn}"); fi
    sleep 0.1
  done

  for ((i=0; i<${#even_ethArray[@]}; i++)); do
    echo "[DEBUG] address ${even_ethArray[i]} & ${odd_ethArray[i]}"
    sudo ip netns exec "ns_${even_ethArray[i]}" ip a add "192.247.${i}.1/24"   dev "${even_ethArray[i]}" || true
    sudo ip netns exec "ns_${even_ethArray[i]}" ip -6 a add "fd00:2470::${i}:1/64"  dev "${even_ethArray[i]}" || true
    sudo ip netns exec "ns_${even_ethArray[i]}" ip link set dev "${even_ethArray[i]}" up || true

    sudo ip netns exec "ns_${odd_ethArray[i]}"  ip a add "192.247.${i}.11/24"  dev "${odd_ethArray[i]}"  || true
    sudo ip netns exec "ns_${odd_ethArray[i]}"  ip -6 a add "fd00:2470::${i}:11/64" dev "${odd_ethArray[i]}" || true
    sudo ip netns exec "ns_${odd_ethArray[i]}"  ip link set dev "${odd_ethArray[i]}"  up || true
  done

  ip netns list
  echo "[INFO] netns created. even=[${even_ethArray[*]}] odd=[${odd_ethArray[*]}]"
}

netns_reset() {
  netns_del
  netns_add
}

# 小工具：紀錄到主 log
log() {
  echo "[$(date '+%F %T')] $*" | tee -a "${_disklog}";
}

# ---------- Batch counter (n/m) ----------
# 檔案位置：<logs>/session_state/counter.<name>
# 格式（shell 可 source）：
#   sid=session_20251009_...
#   m=10
#   n=3

counter_init() {
  local _name="${1:-net}"   # 1st parameter: counter name (default: "net")
  local _target="${2:-1}"   # 2nd parameter: target count (default: 1)

  # Use the same session_state dir as session.id
  local _base="${_session_log_dir:-${_log_dir:-${_tool_path:-$PWD}/logs}}"
  : "${_session_state_dir:=${_base}/session_state}"
  mkdir -p -- "${_session_state_dir}"

  _counter_name="${_name}"
  _counter_file="${_session_state_dir}/counter.${_counter_name}"

  # If have a counter and not done, reuse it.
  if [[ -s "${_counter_file}" ]]; then
    # load existing
    # shellcheck disable=SC1090,SC1091
    source "${_counter_file}"     # Import sid, m, & n.
    if [[ -n "${_sid:-}" && -n "${_m:-}" && -n "${_n:-}" && "${_n}" -lt "${_m}" ]]; then
      #export _session_policy="sticky"
      export _session_id="${_sid}"
    fi
  fi

  # Build or rebuild session ID if needed
  ensure_session_id

  if [[ ! -s "${_counter_file}" || "${_n:-999999}" -ge "${_m:-0}" || "${_sid:-}" != "${_session_id:-}" ]]; then
    # start new counter
    _sid="${_session_id}"
    _m="${_target}"
    _n=0
    printf 'sid=%q\nm=%q\nn=%q\n' "${_sid}" "${_m}" "${_n}" > "${_counter_file}"
  fi
}

# Return k/m (k = n+1)
counter_next_tag() {
  local _k=$(( ${_n} + 1 ))
  if (( _k > _m )); then
    _k="${_m}"
  fi
  printf '%d/%d' "${_k}" "${_m}"
}

counter_loops_this_run() {
  local _remain=$(( _m - _n ))
  local _want="${_target_loop:-1}"
  (( _remain < 0 )) && _remain=0
  (( _want < 1 )) && _want=1
  if (( _want < _remain )); then
    echo "${_want}"
  else
    echo "${_remain}"
  fi
}

# Call after each successful loop. n+1 if n >= m, end and cleaar the session.
counter_tick() {
  _n=$(( _n + 1 ))
  printf 'sid=%q\nm=%q\nn=%q\n' "${_session_id}" "${_m}" "${_n}" > "${_counter_file}"
  if [[ "${_n}" -ge "${_m}" ]]; then
    # Done: clear the counter & session ID. 
    rm -f -- "${_counter_file}" 2>/dev/null || true
    rm -rf -- "${_session_state_dir}/session.id" 2>/dev/null || true
    unset _session_id
  fi
}

# ---------- fio: assess whether the dev is NVMe or not ----------
fio_is_nvme() {
  [[ "$1" == /dev/nvme* ]]
}

# ---------- Return fio_tests array ----------
build_fio_tests_for_dev() {
  local _dev="$1"
  FIO_TESTS=()
  if fio_is_nvme "${_dev}"; then
    FIO_TESTS+=("${FIO_TESTS_NVME[@]}")
  else
    FIO_TESTS+=("${FIO_TESTS_SATA[@]}")
  fi
}

# ---------- Return summary pattern for dev ----------
build_fio_summary_patterns_for_dev() {
  local dev="$1"
  SUMMARY_PATTERNS=()
  if [[ "$dev" == /dev/nvme* ]]; then
    SUMMARY_PATTERNS=("${FIO_SUMMARY_NVME[@]}")
  else
    SUMMARY_PATTERNS=("${FIO_SUMMARY_SATA[@]}")
  fi
}
