#!/usr/bin/env bash
# net_test.sh — IPv4/IPv6 connectivity + throughput with consolidated logs & summary (v2)
# Improvements:
# 1) After changing speed, also configure odd-side NIC; try autoneg off + duplex full; add settle sleep
# 2) Add a blank line between IPv4 and IPv6 blocks in net_test_*.log
# 3) Fix elapsed time (call run_time at start)
# 4) Summary table aligned; extract true bitrate (e.g., "2.35 Gbits/sec") for TCP/UDP receiver lines
set -Eeuo pipefail

export _net_test_version
: "${_net_test_version:="00.00.01"}"

echo "[DEBUG] running enhanced net_test.sh v2"

_user=adlink
_pwd=adlink

# Load config/session + shared funcs
. /home/${_user}/Downloads/config.sh
. ./function.sh

# Always cleanup on exit (success or failure)
trap 'iperf3_del; netns_del' EXIT

# Optional feature-flagged prep
prepare_net_tools

# Ensure tools and logs
ethtool_install
iperf3_install
log_folder
setup_session

# Start elapsed timer now (fix 00:00:00 issue)
run_time

# Define consolidated logs
export _netlog="net_test_${_date_format2}.log"
_netsum="net_summary_${_date_format2}.log"
: > "${_netlog}"
{
  echo "============= Network Test (${_date_format2}) ============="
  echo "Host: $(hostname)   User: ${_user}"
  echo "API: ${_function_api_version}   FeatureFlag: ${FEATURE_USE_NEW_NET_TOOLING:-0}"
  echo "===================================================="
} >> "${_netlog}"

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
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" ping6 -6 -c 4 "${addr}" | tee "${tmpf}" >> "${_netlog}"
  else
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" ping -c 4 "${addr}" | tee "${tmpf}" >> "${_netlog}"
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

parse_loops_arg "${1:-}"

# Main per-pair loop
for (( loop_n=1; loop_n<=_bLoops; loop_n++ )); do
  echo "------------------------------------------------------------"
  echo "[$loop_n/$_bLoops] Network test..."
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

      # IPv4 ping (even -> odd)
      echo "[IPv4 ICMP] ${ev} -> 192.247.${i}.11" | tee -a "${_netlog}"
      v4_res=$(_ping_check "ns_${ev}" "192.247.${i}.11" "0")

      # blank line between IPv4 and IPv6 sections to reduce confusion
      echo "" >> "${_netlog}"

      # IPv6 ping
      echo "[IPv6 ICMP] ${ev} -> fd00:2470::${i}:11" | tee -a "${_netlog}"
      v6_res=$(_ping_check "ns_${ev}" "fd00:2470::${i}:11" "1")

      # Start iperf3 server on odd side
      echo "${_pwd}" | sudo -S ip netns exec ns_${od} iperf3 --bind 192.247.${i}.11 --server --daemon
      sleep 1

      # Log filenames
      tcp_fwd="iPerf3_${ev}_n_${od}_TCP_${_date_format2}.log"
      tcp_rev="iPerf3_${ev}_n_${od}_TCPReverse_${_date_format2}.log"
      udp_fwd="iPerf3_${ev}_n_${od}_UDP_${_date_format2}.log"
      udp_rev="iPerf3_${ev}_n_${od}_UDPReverse_${_date_format2}.log"

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
done

# Done
elp_time | tee -a "${_netlog}"
cd "${_toolPath}"
