#!/usr/bin/env bash
# net_test.sh — IPv4/IPv6 connectivity + throughput, parallel pair execution
#
# Usage:
#   ./net_test.sh [loops]
#
# Parallel design:
#   - All pairs start simultaneously (background &)
#   - Each pair runs all its speeds independently
#   - Each pair writes to its own log: net_test_pair<N>_*.log
#   - Main log records pair START/DONE events only
#   - iperf3 server per pair is tracked by PID and killed after that pair finishes
#   - Summary is assembled after all pairs complete (wait)
#
# Changelog:
#   v00.00.03  Parallel pair execution; per-pair log; PID-tracked iperf3 cleanup
#   v00.00.02  Odd NIC skip + N/A summary row (skipped_ethArray)
#   v00.00.01  Initial version
set -Eeuo pipefail

export _net_test_version
: "${_net_test_version:="00.00.03"}"

echo "[INFO] running net_test.sh v${_net_test_version}."

# ---------- Locate & source companions ----------
_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
_entry_dir="$(cd "$(dirname "${_entry}")" && pwd)"

find_and_source() {
  local _name="$1"
  local search_dirs=(
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

# ---------- Parse CLI ----------
parse_common_cli "$@"
set -- "${REM_ARGS[@]}"

# ---------- Cleanup on exit ----------
# iperf3_del (from function.sh) kills all iperf3 processes system-wide.
# netns_del restores all namespaced NICs to root.
trap 'iperf3_del; netns_del' EXIT

# ---------- Tools ----------
prepare_net_tools
ethtool_install
iperf3_install

# ---------- Log folder ----------
log_dir "" 1
log_root="${_session_log_dir}"

# ---------- Counter ----------
counter_init "net" "${_target_loop:-1}"

_loops_this_run=$(counter_loops_this_run)
if [[ "${_loops_this_run}" -le 0 ]]; then
  echo "[INFO] Already completed (${_n}/${_m}). Nothing to do."
  exit 0
fi

setup_session

# ---------- Timestamps ----------
: "${_session_ts:=$(now_ts)}"
_run_ts="${_session_ts}"
_netlog="${_session_log_dir}/net_test_${_run_ts}.log"
_netsum="${_session_log_dir}/net_summary_${_run_ts}.log"

run_time || true

# ---------- Main log header ----------
if [[ ! -f "${_netlog}" ]]; then
  {
    echo "============= Network Test (${_run_ts}) ============="
    echo "Host: $(hostname)   User: $(whoami)"
    echo "Mode: parallel pairs"
    echo "API: ${_function_api_version}   FeatureFlag: ${FEATURE_USE_NEW_NET_TOOLING:-0}"
    echo "===================================================="
  } > "${_netlog}"
fi

# ---------- Summary header ----------
: > "${_netsum}"
printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
  "Pair" "Speed(Mbps)" "IPv4" "IPv6" \
  "TCP Fwd (recv)" "TCP Rev (recv)" "UDP Fwd (recv)" "UDP Rev (recv)" >> "${_netsum}"

# ---------- Build topology ----------
netns_del
if ! netns_add; then
  echo "[FATAL] netns_add failed" | tee -a "${_netlog}"
  exit 65
fi

if (( ${#even_ethArray[@]} == 0 || ${#odd_ethArray[@]} == 0 )); then
  echo "[FATAL] No interface pairs were created." | tee -a "${_netlog}"
  exit 66
fi

# Warn about skipped NICs (odd count)
if (( ${#skipped_ethArray[@]} > 0 )); then
  for _sk in "${skipped_ethArray[@]}"; do
    echo "[WARN] NIC '${_sk}' has no pair (odd NIC count) — skipped. Will appear as N/A in summary." \
      | tee -a "${_netlog}"
  done
fi

# ---------- Helpers ----------

# Append a timestamped line to the main log.
# Using >> which is atomic for small writes on Linux, safe for parallel callers.
_main_log() { echo "[$(date '+%F %T')] $*" >> "${_netlog}"; }

_ping_check() {
  # usage: _ping_check <ns> <addr> <v6:0|1> <logfile>
  # Prints PASS or FAIL to stdout; detail goes to logfile.
  local ns="$1" addr="$2" v6="$3" logfile="$4"
  local tmpf; tmpf="$(mktemp)"
  if [[ "$v6" == "1" ]]; then
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" ping6 -6 -c 4 "${addr}" \
      | tee "${tmpf}" >> "${logfile}"
  else
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" ping -c 4 "${addr}" \
      | tee "${tmpf}" >> "${logfile}"
  fi
  grep -q " 0% packet loss" "${tmpf}" && echo "PASS" || echo "FAIL"
  rm -f "${tmpf}"
}

_extract_rate() {
  local f="$1"
  local line
  line="$(awk '/receiver$/{ln=$0} END{print ln}' "$f")"
  printf "%s\n" "$line" | grep -oE '[0-9.]+\s+[KMG]?bits/sec' | tail -n1
}

_set_speed() {
  local ns="$1" ifn="$2" spd="$3"
  if ! echo "${_pwd}" | sudo -S ip netns exec "${ns}" \
        ethtool -s "${ifn}" speed "${spd}" duplex full autoneg off 2>/dev/null; then
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" \
        ethtool -s "${ifn}" speed "${spd}" 2>/dev/null || true
  fi
}

# Kill a specific iperf3 server by PID
_kill_iperf3_pid() {
  local pid="$1"
  [[ -z "${pid}" ]] && return 0
  sudo kill -TERM "${pid}" 2>/dev/null || true
  sleep 0.3
  sudo kill -KILL "${pid}" 2>/dev/null || true
}

# Show a progress line on the terminal while an iperf3 test runs.
# Runs in the background alongside the iperf3 client; caller must wait for it.
# Usage: _iperf3_progress <label> <duration_sec> &
#        progress_pid=$!
#        ... run iperf3 ...
#        wait ${progress_pid} 2>/dev/null || true
_iperf3_progress() {
  local label="$1"
  local total="$2"
  local elapsed=0
  while (( elapsed < total )); do
    printf "\r  [%-40s] %3ds / %3ds  %s" \
      "$(printf '#%.0s' $(seq 1 $(( elapsed * 40 / total + 1 ))))" \
      "${elapsed}" "${total}" "${label}" >&2
    sleep 1
    (( elapsed++ )) || true
  done
  printf "\r  %-78s\r" "" >&2   # clear the progress line
}

# ---------- Per-pair worker ----------
# Runs in a subshell (called with &).
# Each pair has its own detail log and a temp summary file.
# Temp summary files are merged into _netsum after all pairs finish.
_run_pair() {
  local pair_idx="$1"
  local ev="$2"
  local od="$3"
  local _k="$4"
  local _mm="$5"

  local pair="${ev}<->${od}"
  local pairlog="${log_root}/net_test_pair${pair_idx}_${_run_ts}.log"
  local pair_sum="${log_root}/.pair${pair_idx}_sum_${_run_ts}.tmp"

  {
    echo "============= Pair ${pair_idx}: ${pair} ============="
    echo "Start: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "====================================================="
  } > "${pairlog}"

  _main_log "[Pair ${pair_idx}] START  ${pair}"

  # Gather supported full-duplex speeds
  local _speed_list
  _speed_list="$(echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" ethtool "${ev}" \
    | tr ' ' '\n' | grep '/Full' | sed 's/[^0-9]//g' | sort -n | uniq)"
  [[ -z "${_speed_list}" ]] && _speed_list="10 100 1000 2500"

  : > "${pair_sum}"

  for _netspd in ${_speed_list}; do
    {
      echo ""
      echo "### Speed = ${_netspd} Mbps"
      echo "----- Iteration ${_k} of ${_mm} -----"
      echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
    } >> "${pairlog}"

    _set_speed "ns_${ev}" "${ev}" "${_netspd}"
    _set_speed "ns_${od}" "${od}" "${_netspd}"
    sleep 4

    # IPv4 ping
    echo "[IPv4 ICMP] ${ev} -> 192.247.${pair_idx}.11" >> "${pairlog}"
    local v4_res
    v4_res=$(_ping_check "ns_${ev}" "192.247.${pair_idx}.11" "0" "${pairlog}")

    echo "" >> "${pairlog}"

    # IPv6 ping
    echo "[IPv6 ICMP] ${ev} -> fd00:2470::${pair_idx}:11" >> "${pairlog}"
    local v6_res
    v6_res=$(_ping_check "ns_${ev}" "fd00:2470::${pair_idx}:11" "1" "${pairlog}")

    echo "" >> "${pairlog}"

    # Start iperf3 server on odd side (no --pidfile; use pgrep after start)
    echo "${_pwd}" | sudo -S ip netns exec "ns_${od}" \
      iperf3 --bind "192.247.${pair_idx}.11" --server --daemon 2>/dev/null || true
    sleep 1

    # Find the server PID: look for iperf3 listening on our bind address inside the ns
    local srv_pid=""
    srv_pid="$(sudo ip netns exec "ns_${od}" \
      pgrep -f "iperf3.*192\.247\.${pair_idx}\.11" 2>/dev/null | head -n1 || true)"

    # iperf3 log filenames include speed so parallel runs don't collide
    local tcp_fwd tcp_rev udp_fwd udp_rev
    tcp_fwd="${log_root}/iPerf3_${ev}_n_${od}_TCP_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"
    tcp_rev="${log_root}/iPerf3_${ev}_n_${od}_TCPRev_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"
    udp_fwd="${log_root}/iPerf3_${ev}_n_${od}_UDP_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"
    udp_rev="${log_root}/iPerf3_${ev}_n_${od}_UDPRev_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"

    local _iperf_time=60   # must match --time below
    local _prog_pid

    echo "[TCP Reverse] ${ev} <- ${od} @ ${_netspd} Mbps" >> "${pairlog}"
    _iperf3_progress "P${pair_idx} TCP Rev  ${ev}<-${od} @${_netspd}M" "${_iperf_time}" &
    _prog_pid=$!
    echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" iperf3 \
        --bind "192.247.${pair_idx}.1" --client "192.247.${pair_idx}.11" \
        --bitrate "${_netspd}M" --time "${_iperf_time}" --interval 3 --omit 3 --reverse \
        --logfile "${tcp_rev}" || true
    wait "${_prog_pid}" 2>/dev/null || true

    echo "[TCP Forward] ${ev} -> ${od} @ ${_netspd} Mbps" >> "${pairlog}"
    _iperf3_progress "P${pair_idx} TCP Fwd  ${ev}->${od} @${_netspd}M" "${_iperf_time}" &
    _prog_pid=$!
    echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" iperf3 \
        --bind "192.247.${pair_idx}.1" --client "192.247.${pair_idx}.11" \
        --bitrate "${_netspd}M" --time "${_iperf_time}" --interval 3 --omit 3 \
        --logfile "${tcp_fwd}" || true
    wait "${_prog_pid}" 2>/dev/null || true

    echo "[UDP Reverse] ${ev} <- ${od} @ ${_netspd} Mbps" >> "${pairlog}"
    _iperf3_progress "P${pair_idx} UDP Rev  ${ev}<-${od} @${_netspd}M" "${_iperf_time}" &
    _prog_pid=$!
    echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" iperf3 \
        --bind "192.247.${pair_idx}.1" --client "192.247.${pair_idx}.11" \
        --udp --bitrate "${_netspd}M" --time "${_iperf_time}" --interval 3 --omit 3 --reverse \
        --logfile "${udp_rev}" || true
    wait "${_prog_pid}" 2>/dev/null || true

    echo "[UDP Forward] ${ev} -> ${od} @ ${_netspd} Mbps" >> "${pairlog}"
    _iperf3_progress "P${pair_idx} UDP Fwd  ${ev}->${od} @${_netspd}M" "${_iperf_time}" &
    _prog_pid=$!
    echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" iperf3 \
        --bind "192.247.${pair_idx}.1" --client "192.247.${pair_idx}.11" \
        --udp --bitrate "${_netspd}M" --time "${_iperf_time}" --interval 3 --omit 3 \
        --logfile "${udp_fwd}" || true
    wait "${_prog_pid}" 2>/dev/null || true

    # Kill iperf3 server for this speed now that all four tests are done
    _kill_iperf3_pid "${srv_pid}"

    # Extract rates
    local rate_tcp_fwd rate_tcp_rev rate_udp_fwd rate_udp_rev
    rate_tcp_fwd="$(_extract_rate "${tcp_fwd}")"; [[ -z "${rate_tcp_fwd}" ]] && rate_tcp_fwd="N/A"
    rate_tcp_rev="$(_extract_rate "${tcp_rev}")"; [[ -z "${rate_tcp_rev}" ]] && rate_tcp_rev="N/A"
    rate_udp_fwd="$(_extract_rate "${udp_fwd}")"; [[ -z "${rate_udp_fwd}" ]] && rate_udp_fwd="N/A"
    rate_udp_rev="$(_extract_rate "${udp_rev}")"; [[ -z "${rate_udp_rev}" ]] && rate_udp_rev="N/A"

    printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
      "${pair}" "${_netspd}" "${v4_res}" "${v6_res}" \
      "${rate_tcp_fwd}" "${rate_tcp_rev}" "${rate_udp_fwd}" "${rate_udp_rev}" \
      >> "${pair_sum}"

    echo "[Speed ${_netspd} Mbps done]" >> "${pairlog}"
  done

  echo "End: $(date '+%Y-%m-%d %H:%M:%S')" >> "${pairlog}"
  _main_log "[Pair ${pair_idx}] DONE   ${pair}"
}

# ---------- Main test loop ----------
for (( loop_n=1; loop_n<=_loops_this_run; loop_n++ )); do
  echo "------------------------------------------------------------"
  echo "[$(counter_next_tag)] Network test... (parallel pairs)"
  _km="$(counter_next_tag)"
  _k="${_km%%/*}"
  _mm="${_km##*/}"

  _main_log "=== Iteration ${_k}/${_mm} START — ${#even_ethArray[@]} pair(s) launching in parallel ==="

  # Launch all pairs in background
  _pair_pids=()
  for (( i=0; i<${#even_ethArray[@]}; i++ )); do
    _run_pair "${i}" "${even_ethArray[i]}" "${odd_ethArray[i]}" "${_k}" "${_mm}" &
    _pair_pids+=($!)
    echo "[INFO] Pair ${i} (${even_ethArray[i]}<->${odd_ethArray[i]}) launched (PID ${_pair_pids[-1]})"
  done

  # Wait for all pair workers to finish
  _failed=0
  for pid in "${_pair_pids[@]}"; do
    wait "${pid}" || { echo "[WARN] Pair worker PID ${pid} exited with error"; _failed=1; }
  done
  (( _failed )) && echo "[WARN] One or more pairs reported errors — check per-pair logs."

  _main_log "=== Iteration ${_k}/${_mm} DONE ==="

  # Merge per-pair temp summaries into main summary (ordered by pair index)
  _tmp=""
  for (( i=0; i<${#even_ethArray[@]}; i++ )); do
    _tmp="${log_root}/.pair${i}_sum_${_run_ts}.tmp"
    if [[ -f "${_tmp}" ]]; then
      cat "${_tmp}" >> "${_netsum}"
      rm -f "${_tmp}"
    fi
  done

  # N/A rows for skipped NICs
  if (( ${#skipped_ethArray[@]} > 0 )); then
    for _sk in "${skipped_ethArray[@]}"; do
      printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
        "${_sk}(no pair)" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" >> "${_netsum}"
    done
  fi

  counter_tick
done

# ---------- Done ----------
elp_time | tee -a "${_netlog}"
echo "[INFO] Main log : ${_netlog}"
echo "[INFO] Summary  : ${_netsum}"
echo "[INFO] Pair logs: ${log_root}/net_test_pair*_${_run_ts}.log"
cd "${_tool_path}"
