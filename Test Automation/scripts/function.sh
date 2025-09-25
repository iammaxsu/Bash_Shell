#!/usr/bin/env bash
# function.sh - Shared utilities (API 00.00.02), unified log naming, real-NIC namespaces (no veth)
set -euo pipefail
_function_api_version="00.00.02"

# -------------------- paths / folders --------------------
init_paths() {
  local entry="${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}"
  local entry_dir; entry_dir="$(cd "$(dirname "$entry")" && pwd)"
  if [[ -z "${_toolPath:-}" || "${_toolPath}" = "/" ]]; then _toolPath="${entry_dir}"; fi
  if [[ -z "${_logPath:-}" || "${_logPath}" = "/logs" ]]; then _logPath="${_toolPath}/logs"; fi
}
log_folder() { init_paths; mkdir -p "${_logPath}"; cd "${_logPath}" || return 1; }

# -------------------- timers (total test time) --------------------
clock_start() { : "${_RUN_T0:=$(date +%s)}"; }
clock_end()   { local _t1; _t1="$(date +%s)"; : "${_RUN_T0:=$(date +%s)}"; _RUN_ELAPSED=$(( _t1 - _RUN_T0 )); }
elapsed_human() {
  local t="${1:-${_RUN_ELAPSED:-0}}"
  if   (( t < 60 ));  then printf "[Elapsed time: %d sec]\n" "$t"
  elif (( t < 3600 ));then printf "[Elapsed time: %d min %d sec]\n" $((t/60)) $((t%60))
  else                    printf "[Elapsed time: %d hrs %d min %d sec]\n" $((t/3600)) $(((t%3600)/60)) $((t%60))
  fi
}

# -------------------- session --------------------
session_start() {
  init_paths; mkdir -p "${_logPath}"
  # start the total-time clock once per run
  clock_start
  # session id for grouping logs from the same boot/run if you need it
  local _sessionFile="${_logPath}/session_id"
  if [[ -f "${_sessionFile}" ]]; then
    _date2="$(sed -n '1p' "${_sessionFile}")"
    _bootLoop="$(sed -n '2p' "${_sessionFile}")"
  else
    _date2="$(date '+%Y%m%d%H%M%S')"; : "${_bootLoop:=1000}"
    printf "%s\n%s\n" "${_date2}" "${_bootLoop}" > "${_sessionFile}"
  fi
}

log() { local msg="${1:-}"; local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"; echo -e "[${ts}] ${msg}"; }

# -------------------- loops (formerly cycles) --------------------
loops_state_file() { echo "${_logPath}/${1}_loops.state"; }
loops_init() {
  local name="$1"; local def_total="${2:-1000}"; local f; f="$(loops_state_file "${name}")"; local total done
  if [[ -f "$f" ]]; then
    total="$(sed -n '1p' "$f" 2>/dev/null)"; [[ "$total" =~ ^[0-9]+$ ]] || total="$def_total"
    done="$(sed -n '2p' "$f" 2>/dev/null)"; [[ "$done"  =~ ^[0-9]+$ ]] || done="0"
    if (( done >= total )); then read -r -p "How many loops to run the test? (default: ${def_total}): " input_loops || true; total="${input_loops:-$def_total}"; done="0"; printf "%s\n%s\n" "$total" "$done" > "$f"; fi
  else read -r -p "How many loops to run the test? (default: ${def_total}): " input_loops || true; total="${input_loops:-$def_total}"; done="0"; printf "%s\n%s\n" "$total" "$done" > "$f"; fi
  LOOP_TOTAL="$total"; LOOP_DONE="$done"; LOOP_NAME="$name"
}
loops_mark_done() { local name="$1"; local inc="${2:-1}"; local f; f="$(loops_state_file "${name}")"; local total done; total="$(sed -n '1p' "$f" 2>/dev/null)"; [[ "$total" =~ ^[0-9]+$ ]] || total="0"; done="$(sed -n '2p' "$f" 2>/dev/null)"; [[ "$done" =~ ^[0-9]+$ ]] || done="0"; done=$(( done + inc )); printf "%s\n%s\n" "$total" "$done" > "$f"; }
loops_remaining() { local f; f="$(loops_state_file "${1}")"; local total done; total="$(sed -n '1p' "$f" 2>/dev/null)"; [[ "$total" =~ ^[0-9]+$ ]] || total="0"; done="$(sed -n '2p' "$f" 2>/dev/null)"; [[ "$done" =~ ^[0-9]+$ ]] || done="0"; echo $(( total - done )); }
loops_is_complete() { local f; f="$(loops_state_file "${1}")"; local total done; total="$(sed -n '1p' "$f" 2>/dev/null)"; [[ "$total" =~ ^[0-9]+$ ]] || total="0"; done="$(sed -n '2p' "$f" 2>/dev/null)"; [[ "$done" =~ ^[0-9]+$ ]] || done="0"; (( done >= total )); }

# -------------------- unified log naming (uses loops) --------------------
now_ts() { date '+%Y%m%d%H%M%S'; }
_result_title() {
  local r="${1:-Done}"; r="${r,,}"
  case "$r" in
    pass) echo "Pass" ;;
    fail) echo "Fail" ;;
    init) echo "Init" ;;
    cancel|cancelled) echo "Cancel" ;;
    warn|warning) echo "Warn" ;;
    info) echo "Info" ;;
    *) echo "Done" ;;
  esac
}
# build_log_name <program> <result>
build_log_name() {
  local program="$1"; local result_titled; result_titled="$(_result_title "${2:-Done}")"
  local cur=$(( ${LOOP_DONE:-0} + 1 )); local tot="${LOOP_TOTAL:-1}"
  echo "${program}_l${cur}_of_${tot}_$(now_ts)_${result_titled}.log"
}

# -------------------- net helpers (real NIC namespaces only) --------------------
_pkg_install() {
  local pkg="$1"
  if command -v apt >/dev/null 2>&1; then sudo apt update -y && sudo apt install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then sudo yum install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y "$pkg"
  fi
}
ethtool_install() { command -v ethtool >/dev/null 2>&1 || _pkg_install ethtool || true; }
iperf3_install()  { command -v iperf3  >/dev/null 2>&1 || _pkg_install iperf3  || true; }
prepare_net_tools() { : "${FEATURE_USE_NEW_NET_TOOLING:=1}"; command -v ip >/dev/null 2>&1 || _pkg_install iproute2 || true; ethtool_install; iperf3_install; }

# Move real enp* NICs into dedicated namespaces in pairs; assign IPs; record for cleanup.
netns_add() {
  unset even_ethArray odd_ethArray
  declare -g -a even_ethArray=() odd_ethArray=()

  mapfile -t ENPS < <(ip -o link | awk -F': ' '{print $2}' | grep -E '^enp' || true)
  if (( ${#ENPS[@]} < 2 )); then
    echo "[FATAL] Need at least two enp* NICs for testing" >&2
    return 1
  fi

  local moved_file="${_logPath}/.moved_ifaces"
  : > "${moved_file}"

  local idx=0 pair=0
  while (( idx+1 < ${#ENPS[@]} )); do
    local ev="${ENPS[idx]}"; local od="${ENPS[idx+1]}"
    sudo ip netns del "ns_${ev}" 2>/dev/null || true
    sudo ip netns del "ns_${od}" 2>/dev/null || true
    sudo ip netns add "ns_${ev}"
    sudo ip netns add "ns_${od}"

    # move devices
    sudo ip link set "$ev" netns "ns_${ev}"
    sudo ip link set "$od" netns "ns_${od}"
    echo "${ev} ns_${ev}" >> "${moved_file}"
    echo "${od} ns_${od}" >> "${moved_file}"

    # bring up and assign IPs
    sudo ip netns exec "ns_${ev}" ip link set lo up
    sudo ip netns exec "ns_${ev}" ip link set "$ev" up
    sudo ip netns exec "ns_${ev}" ip addr add "192.247.${pair}.1/24" dev "$ev"
    sudo ip netns exec "ns_${ev}" ip -6 addr add "fd00:2470::${pair}:1/64" dev "$ev"

    sudo ip netns exec "ns_${od}" ip link set lo up
    sudo ip netns exec "ns_${od}" ip link set "$od" up
    sudo ip netns exec "ns_${od}" ip addr add "192.247.${pair}.11/24" dev "$od"
    sudo ip netns exec "ns_${od}" ip -6 addr add "fd00:2470::${pair}:11/64" dev "$od"

    even_ethArray+=("$ev"); odd_ethArray+=("$od")
    idx=$((idx+2)); pair=$((pair+1))
  done
  export even_ethArray odd_ethArray
  return 0
}

# Move devices back to root namespace and remove namespaces.
netns_del() {
  local moved_file="${_logPath}/.moved_ifaces"
  if [[ -f "${moved_file}" ]]; then
    while read -r dev ns; do
      [[ -z "${dev:-}" || -z "${ns:-}" ]] && continue
      if ip netns exec "${ns}" ip link show "${dev}" >/dev/null 2>&1; then
        sudo ip netns exec "${ns}" ip link set "${dev}" down || true
        sudo ip netns exec "${ns}" ip link set "${dev}" netns 1 || true
      fi
      sudo ip netns del "${ns}" 2>/dev/null || true
    done < "${moved_file}"
    rm -f "${moved_file}"
  else
    for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
      if [[ "$ns" == ns_enp* ]]; then sudo ip netns del "$ns" 2>/dev/null || true; fi
    done
  fi
}

iperf3_del() {
  for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
    sudo ip netns exec "$ns" pkill -9 iperf3 2>/dev/null || true
  done
  pkill -9 iperf3 2>/dev/null || true
}
