#!/usr/bin/env bash
# function.sh — hardened netns helpers for enp* pairs
# - Sanitize interface names
# - Bring links down + flush before moving
# - Move-back down/flush then up
# - Kill weird leftover namespace "ns_" and any empty file /run/netns/ns_
# - Verbose debug
set -Eeuo pipefail

export _function_api_version
: "${_function_api_version:="00.00.01"}"

# ---------- Logging & timing ----------
__ensure_dir() {
  local d="${1:?missing dir}"
  if ! mkdir -p -- "$d"; then
    echo "[FATAL] failed to create directory: $d" >&2
    return 1
  fi
}

log_folder() {
  local caller="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  local base_dir
  base_dir="$(cd "$(dirname "$(readlink -f "${caller}")")" && pwd)"
  export _toolPath="${_toolPath:-${base_dir}}"
  export _log_folder="${_toolPath}/logs"
  mkdir -p "${_log_folder}"
  cd "${_log_folder}" || return 1
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

# ---------- loops arguement ----------
parse_loops_arg() {
  local _loops="${1:-1}"
  if ! [[ "${_loops}" =~ ^[0-9]+$ ]] || [[ "${_loops}" -lt 1 ]]; then
    echo "[FATAL] Invalid loop count: '${_loops}'. Using default: 1"
    _loops=1
  fi
  export _bLoops="${_loops}"
  echo "[INFO] Running ${_bLoops} time(s)"
}

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
    echo "[DBG] move-back ${ifn} from ${ns} -> root"
    sudo ip netns exec "${ns}" ip link set dev "${ifn}" down 2>/dev/null || true
    sudo ip netns exec "${ns}" ip addr flush dev "${ifn}" 2>/dev/null || true
    sudo ip netns exec "${ns}" ip link set "${ifn}" netns 1 2>/dev/null || true
    sudo ip link set dev "${ifn}" up 2>/dev/null || true
  fi
}

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
  echo "[DBG] root enp*: ${_ethArray[*]}"
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
    echo "[DBG] prepare ${ifn} -> ${ns}"
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
    echo "[DBG] address ${even_ethArray[i]} & ${odd_ethArray[i]}"
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

netns_reset() { netns_del; netns_add; }
