#!/usr/bin/env bash
# net_test.sh — real enp* NIC testing; unified log naming; multi-loop; final elapsed time only
set -euo pipefail

echo "[DEBUG] net_test.sh (real NIC mode, unified log naming, multi-loop)"

_user="${USER:-adlink}"

# Load config & functions (prefer local dir)
if [[ -f "./config.sh" ]]; then . ./config.sh; else . /home/${_user}/Downloads/config.sh; fi
if [[ -f "./function.sh" ]]; then . ./function.sh; else . /home/${_user}/Downloads/function.sh; fi

# One clock for whole run
log_folder
session_start   # starts the total-time clock (clock_start)

# Ask loops here (and only here)
loops_init "net_test" "${_bootLoop:-1000}"

prepare_net_tools

# We'll run exactly the remaining loops in this invocation
loops_to_run="$(loops_remaining "net_test")"
if ! [[ "${loops_to_run}" =~ ^[0-9]+$ ]]; then loops_to_run=1; fi
if (( loops_to_run < 1 )); then loops_to_run=1; fi

# Helper for iperf3 filenames
mk_iperf_name() {
  local ev="$1" od="$2" typ="$3"
  local cur=$(( ${LOOP_DONE:-0} + 1 )); local tot="${LOOP_TOTAL:-1}"
  echo "iPerf3_${ev}_n_${od}_l${cur}_of_${tot}_${typ}_$(now_ts).log"
}

# iperf3 window
IPERF_T=60; IPERF_I=3; IPERF_O=3

# Build namespaces with real NICs (once per run)
trap 'iperf3_del; netns_del' EXIT
if ! netns_add; then
  echo "[FATAL] netns_add failed (need >=2 enp* NICs)"
  exit 65
fi

for ((loop=1; loop<=loops_to_run; loop++)); do
  # Per-loop Init summary (will be renamed per result)
  summary="$(build_log_name net_test Init)"
  netsum="$(build_log_name net_summary Info)"
  : > "${summary}"; : > "${netsum}"

  {
    echo "============= Network Test ($(date '+%Y-%m-%d %H:%M:%S')) ============="
    echo "Host: $(hostname)   User: ${_user}"
    echo "API: ${_function_api_version}"
    echo "Loop: $((LOOP_DONE+1)) / ${LOOP_TOTAL}"
    echo "===================================================="
  } >> "${summary}"

  printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
    "Pair" "Speed(Mbps)" "IPv4" "IPv6" "TCP Fwd" "TCP Rev" "UDP Fwd" "UDP Rev" >> "${netsum}"

  FAILED=0

  for ((i=0; i<${#even_ethArray[@]}; i++)); do
    ev="${even_ethArray[i]}"; od="${odd_ethArray[i]}"
    pair="${ev}<->${od}"
    echo "----- Pair $i: ${pair} -----" | tee -a "${summary}"

    # supported speeds by 'ev'
    mapfile -t SPEEDS < <(sudo ip netns exec "ns_${ev}" ethtool "${ev}" 2>/dev/null | tr ' ' '\n' | grep -E '/Full$' | sed 's/[^0-9]//g' | sort -n | uniq)
    [[ ${#SPEEDS[@]} -eq 0 ]] && SPEEDS=(10 100 1000 2500)

    for sp in "${SPEEDS[@]}"; do
      echo "" | tee -a "${summary}"
      echo "### Speed = ${sp} Mbps" | tee -a "${summary}"

      # try set fixed speed
      if ! sudo ip netns exec "ns_${ev}" ethtool -s "${ev}" speed "${sp}" duplex full autoneg off 2>/dev/null; then
        sudo ip netns exec "ns_${ev}" ethtool -s "${ev}" speed "${sp}" 2>/dev/null || true
      fi
      if ! sudo ip netns exec "ns_${od}" ethtool -s "${od}" speed "${sp}" duplex full autoneg off 2>/dev/null; then
        sudo ip netns exec "ns_${od}" ethtool -s "${od}" speed "${sp}" 2>/dev/null || true
      fi
      sleep 4

      # pings
      v4_res=$(sudo ip netns exec "ns_${ev}" ping -c 4 "192.247.${i}.11" | tee -a "${summary}" | awk '/packet loss/{print ($6=="0%"?"PASS":"FAIL")}')
      [[ "${v4_res:-FAIL}" != "PASS" ]] && FAILED=1
      if command -v ping6 >/dev/null 2>&1; then
        v6_res=$(sudo ip netns exec "ns_${ev}" ping6 -6 -c 4 "fd00:2470::${i}:11" | tee -a "${summary}" | awk '/packet loss/{print ($6=="0%"?"PASS":"FAIL")}')
      else
        v6_res=$(sudo ip netns exec "ns_${ev}" ping -6 -c 4 "fd00:2470::${i}:11" | tee -a "${summary}" | awk '/packet loss/{print ($6=="0%"?"PASS":"FAIL")}')
      fi
      [[ "${v6_res:-FAIL}" != "PASS" ]] && FAILED=1

      # iperf3 logs (include loop info before timestamp)
      tcp_fwd="$(mk_iperf_name "${ev}" "${od}" "TCP")"
      tcp_rev="$(mk_iperf_name "${ev}" "${od}" "TCPReverse")"
      udp_fwd="$(mk_iperf_name "${ev}" "${od}" "UDP")"
      udp_rev="$(mk_iperf_name "${ev}" "${od}" "UDPReverse")"

      # start server on 'od'
      sudo ip netns exec "ns_${od}" iperf3 --bind "192.247.${i}.11" --server --daemon
      sleep 1

      # TCP Reverse
      sudo ip netns exec "ns_${ev}" iperf3 --bind "192.247.${i}.1" --client "192.247.${i}.11" \
           --bitrate ${sp}M --time ${IPERF_T} --interval ${IPERF_I} --omit ${IPERF_O} --reverse \
           --logfile "${tcp_rev}"

      # TCP Forward
      sudo ip netns exec "ns_${ev}" iperf3 --bind "192.247.${i}.1" --client "192.247.${i}.11" \
           --bitrate ${sp}M --time ${IPERF_T} --interval ${IPERF_I} --omit ${IPERF_O} \
           --logfile "${tcp_fwd}"

      # UDP Reverse
      sudo ip netns exec "ns_${ev}" iperf3 --bind "192.247.${i}.1" --client "192.247.${i}.11" \
           --udp --bitrate ${sp}M --time ${IPERF_T} --interval ${IPERF_I} --omit ${IPERF_O} --reverse \
           --logfile "${udp_rev}"

      # UDP Forward
      sudo ip netns exec "ns_${ev}" iperf3 --bind "192.247.${i}.1" --client "192.247.${i}.11" \
           --udp --bitrate ${sp}M --time ${IPERF_T} --interval ${IPERF_I} --omit ${IPERF_O} \
           --logfile "${udp_fwd}"

      # Extract rates (last receiver line)
      _extract_rate() { awk '/receiver$/{ln=$0} END{print ln}' "$1" | grep -oE '[0-9.]+\s+[KMG]?bits/sec' | tail -n1; }
      rate_tcp_fwd="$(_extract_rate "${tcp_fwd}")";   [[ -z "${rate_tcp_fwd}" ]] && rate_tcp_fwd="N/A"
      rate_tcp_rev="$(_extract_rate "${tcp_rev}")";   [[ -z "${rate_tcp_rev}" ]] && rate_tcp_rev="N/A"
      rate_udp_fwd="$(_extract_rate "${udp_fwd}")";   [[ -z "${rate_udp_fwd}" ]] && rate_udp_fwd="N/A"
      rate_udp_rev="$(_extract_rate "${udp_rev}")";   [[ -z "${rate_udp_rev}" ]] && rate_udp_rev="N/A"

      printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
        "${pair}" "${sp}" "${v4_res}" "${v6_res}" \
        "${rate_tcp_fwd}" "${rate_tcp_rev}" "${rate_udp_fwd}" "${rate_udp_rev}" >> "${netsum}"
    done
  done

  # close one loop
  res="Pass"; [[ $FAILED -eq 1 ]] && res="Fail"
  final="$(build_log_name net_test "${res}")"
  mv -f "${summary}" "${final}"
  echo "[RESULT] ${res}" | tee -a "${final}"

  # mark done and advance in-memory counter for filenames
  loops_mark_done "net_test" 1
  LOOP_DONE=$(( ${LOOP_DONE:-0} + 1 ))
done

# Only once at the very end: print total elapsed time
clock_end
elapsed_human "${_RUN_ELAPSED}"
