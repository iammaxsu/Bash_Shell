#!/usr/bin/env bash
# net_test.sh ??IPv4/IPv6 connectivity + throughput with consolidated logs & summary (v2)
# Improvements:
# 1) After changing speed, also configure odd-side NIC; try autoneg off + duplex full; add settle sleep
# 2) Add a blank line between IPv4 and IPv6 blocks in net_test_*.log
# 3) Fix elapsed time (call run_time at start)
# 4) Summary table aligned; extract true bitrate (e.g., "2.35 Gbits/sec") for TCP/UDP receiver lines
set -Eeuo pipefail

export _net_test_version
: "${_net_test_version:="00.00.01"}"

echo "[INFO] running net_test.sh v${_net_test_version}."

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
# ---------- Parse CLI parameters ----------
parse_common_cli "$@"

# If have the loops argument, parse it now to set _target_loops.
#if [[ -n "${_cli_loops:-}" ]]; then
#  parse_loops_arg "${_cli_loops}"
#  _target_loops="${_cli_loops:-1}"
#fi

# Rebuild REM_ARGS to exclude loops argument (already parsed)
# Ex.
# ./net_test.sh (default: auto, 1 loop)
# ./net_test.sh 10 sticky
# ./net_test.sh --sticky -n 
# ./net_test.sh --session-id=batch_20251009
set -- "${REM_ARGS[@]}"

# If your loops is in "_target_loops", it is already set by parse_loops_arg above.
#counter_init "net" "${_target_loops:-1}"

# Always cleanup on exit (success or failure)
trap 'iperf3_del; netns_del' EXIT

# Optional feature-flagged prep
prepare_net_tools

# Ensure tools and logs
ethtool_install
iperf3_install

# ---------- Log folder ----------
log_dir "" 1
log_root="${_session_log_dir}"

# Initialize, m = _target_loop
counter_init "net" "${_target_loop:-1}"

# Calculate how many loops to do
_loops_this_run=$(counter_loops_this_run)
if [[ "${_loops_this_run}" -le 0 ]]; then
  echo "[INFO] Already completed (${_n}/${_m}). Nothing to do."
  exit 0
fi

setup_session

# Start elapsed timer now (fix 00:00:00 issue)
#run_time

# Timestamp per loop & log folders
: "${_session_ts:=$(now_ts)}"
_run_ts="${_session_ts}"
_netlog="${_session_log_dir}/net_test_${_run_ts}.log"
_netsum="${_session_log_dir}/net_summary_${_run_ts}.log"

# ---------- Test Header ----------
## ---------- Start elapsed time now ----------
run_time || true

if [[ ! -f "${_netlog}" ]]; then
  {
  echo "============= Network Test (${_run_ts}) ============="
  echo "Host: $(hostname)   User: $(whoami)"
  echo "API: ${_function_api_version}   FeatureFlag: ${FEATURE_USE_NEW_NET_TOOLING:-0}"
  echo "===================================================="
} > "${_netlog}"
fi

: > "${_netsum}"
{
  printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
    "Pair" "Speed(Mbps)" "IPv4" "IPv6" "TCP Fwd (recv)" "TCP Rev (recv)" "UDP Fwd (recv)" "UDP Rev (recv)"
} >> "${_netsum}"

# Fresh topology: explicit delete first (handles prior interruption), then add
netns_del
if ! netns_add; then
  echo "[FATAL] netns_add failed" | tee -a "${_netlog}"
  exit 65
fi

# Abort if no pairs
if (( ${#even_ethArray[@]} == 0 || ${#odd_ethArray[@]} == 0 )); then
  echo "[FATAL] No interface pairs were created." | tee -a "${_netlog}"
  exit 66
fi

# Helpers
_ping_check() {
  local ns="$1" addr="$2" v6="$3"
  local tmpf
  tmpf="$(mktemp)"
  if [[ "$v6" == "1" ]]; then
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" ping6 -6 -c 4 "${addr}" \
      | tee "${tmpf}" \
      | tee -a "${_netlog}" > /dev/null
  else
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" ping -c 4 "${addr}" \
      | tee "${tmpf}" \
      | tee -a "${_netlog}" > /dev/null
  fi
  if grep -q " 0% packet loss" "${tmpf}"; then
    echo "PASS"
  else
    echo "FAIL"
  fi
  rm -f "${tmpf}"
}

# Extract "X.Y [KMG]?bits/sec" that appears on the receiver summary line
_extract_rate() {
  local f="$1"
  local line
  line="$(awk '/receiver$/{ln=$0} END{print ln}' "$f")"
  printf "%s\n" "$line" | grep -oE '[0-9.]+\s+[KMG]?bits/sec' | tail -n1
}

# Try to set interface speed in ns with best-effort fallbacks
_set_speed() {
  local ns="$1" ifn="$2" spd="$3"
  # prefer autoneg off + duplex full when allowed
  if ! echo "${_pwd}" | sudo -S ip netns exec "${ns}" ethtool -s "${ifn}" speed "${spd}" duplex full autoneg off 2>/dev/null; then
    # fallback: just speed
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" ethtool -s "${ifn}" speed "${spd}" 2>/dev/null || true
  fi
}

#if [[ -n "${1:-}" ]]; then
#  parse_loops_arg "${1:-}"
#fi

# Main per-pair loop
for (( loop_n=1; loop_n<=_loops_this_run; loop_n++ )); do
  echo "------------------------------------------------------------"
  #echo "[$loop_n/$_target_loops] Network test..."
  echo "[$(counter_next_tag)] Network test..."
  _km="$(counter_next_tag)"    # e.g. "3/10"
  _k="${_km%%/*}"               # "3"
  _mm="${_km##*/}"              # "10"
  for ((i=0; i<${#even_ethArray[@]}; i++)); do
    ev="${even_ethArray[i]}"; od="${odd_ethArray[i]}"
    pair="${ev}<->${od}"
    echo "----- Pair $i: ${pair} -----" | tee -a "${_netlog}"

    # Gather supported full-duplex speeds from even side
    _speed_list="$(echo "${_pwd}" | sudo -S ip netns exec ns_${ev} ethtool ${ev} | tr ' ' '\n' | grep '/Full' | sed 's/[^0-9]//g' | sort -n | uniq)"
    [[ -z "${_speed_list}" ]] && _speed_list="10 100 1000 2500"

    for _netspd in ${_speed_list}; do
      echo "" | tee -a "${_netlog}"
      echo "### Speed = ${_netspd} Mbps" | tee -a "${_netlog}"

      # Configure both ends to the same speed; allow time to settle
      _set_speed "ns_${ev}" "${ev}" "${_netspd}"
      _set_speed "ns_${od}" "${od}" "${_netspd}"
      sleep 4

      # Loop 
      echo "----- Iteration ${_k} of ${_mm} -----" | tee -a "${_netlog}"
      echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${_netlog}"

      # IPv4 ping (even -> odd)
      echo "[IPv4 ICMP] ${ev} -> 192.247.${i}.11" | tee -a "${_netlog}"
      v4_res=$(_ping_check "ns_${ev}" "192.247.${i}.11" "0")

      # blank line between IPv4 and IPv6 sections to reduce confusion
      echo "" >> "${_netlog}"

      # IPv6 ping
      echo "[IPv6 ICMP] ${ev} -> fd00:2470::${i}:11" | tee -a "${_netlog}"
      v6_res=$(_ping_check "ns_${ev}" "fd00:2470::${i}:11" "1")

      # Start iperf3 server on odd side
      ensure_tools iperf3 ethtool

      echo "${_pwd}" | sudo -S ip netns exec ns_${od} iperf3 --bind 192.247.${i}.11 --server --daemon
      sleep 1

      # Log filenames
      tcp_fwd="${log_root}/iPerf3_${ev}_n_${od}_TCP_${_k}_of_${_mm}_${_run_ts}.log"
      tcp_rev="${log_root}/iPerf3_${ev}_n_${od}_TCPReverse_${_k}_of_${_mm}_${_run_ts}.log"
      udp_fwd="${log_root}/iPerf3_${ev}_n_${od}_UDP_${_k}_of_${_mm}_${_run_ts}.log"
      udp_rev="${log_root}/iPerf3_${ev}_n_${od}_UDPReverse_${_k}_of_${_mm}_${_run_ts}.log"

      # TCP reverse (receiver = even side)
      echo "[TCP Reverse] ${ev} <- ${od} @ ${_netspd} Mbps" | tee -a "${_netlog}"
      echo "${_pwd}" | sudo -S ip netns exec ns_${ev} iperf3 --bind 192.247.${i}.1 --client 192.247.${i}.11 \
          --bitrate ${_netspd}M --time 60 --interval 3 --omit 3 --reverse \
          --logfile "${tcp_rev}"

      # TCP forward
      echo "[TCP Forward] ${ev} -> ${od} @ ${_netspd} Mbps" | tee -a "${_netlog}"
      echo "${_pwd}" | sudo -S ip netns exec ns_${ev} iperf3 --bind 192.247.${i}.1 --client 192.247.${i}.11 \
          --bitrate ${_netspd}M --time 60 --interval 3 --omit 3 \
          --logfile "${tcp_fwd}"

      # UDP reverse
      echo "[UDP Reverse] ${ev} <- ${od} @ ${_netspd} Mbps" | tee -a "${_netlog}"
      echo "${_pwd}" | sudo -S ip netns exec ns_${ev} iperf3 --bind 192.247.${i}.1 --client 192.247.${i}.11 \
          --udp --bitrate ${_netspd}M --time 60 --interval 3 --omit 3 --reverse \
          --logfile "${udp_rev}"

      # UDP forward
      echo "[UDP Forward] ${ev} -> ${od} @ ${_netspd} Mbps" | tee -a "${_netlog}"
      echo "${_pwd}" | sudo -S ip netns exec ns_${ev} iperf3 --bind 192.247.${i}.1 --client 192.247.${i}.11 \
          --udp --bitrate ${_netspd}M --time 60 --interval 3 --omit 3 \
          --logfile "${udp_fwd}"

      # Extract rates for summary (receiver lines)
      rate_tcp_fwd="$(_extract_rate "${tcp_fwd}")";   [[ -z "${rate_tcp_fwd}" ]] && rate_tcp_fwd="N/A"
      rate_tcp_rev="$(_extract_rate "${tcp_rev}")";   [[ -z "${rate_tcp_rev}" ]] && rate_tcp_rev="N/A"
      rate_udp_fwd="$(_extract_rate "${udp_fwd}")";   [[ -z "${rate_udp_fwd}" ]] && rate_udp_fwd="N/A"
      rate_udp_rev="$(_extract_rate "${udp_rev}")";   [[ -z "${rate_udp_rev}" ]] && rate_udp_rev="N/A"

      # Summary line (aligned)
      printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
        "${pair}" "${_netspd}" "${v4_res}" "${v6_res}" \
        "${rate_tcp_fwd}" "${rate_tcp_rev}" "${rate_udp_fwd}" "${rate_udp_rev}" >> "${_netsum}"
    done
  done
  counter_tick
done

# Done
elp_time | tee -a "${_netlog}"
cd "${_tool_path}"
