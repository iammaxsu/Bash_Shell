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
  # 用法：__pkg_install pkg1 [pkg2 ...]
  local pkgs=("$@")
  if __is_debian_like; then
    if [[ "${_APT_UPDATED:-0}" != "1" ]]; then
      sudo DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
      _APT_UPDATED=1
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif __is_redhat_like; then
    if command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y "${pkgs[@]}"
    else
      sudo yum install -y "${pkgs[@]}"
    fi
  else
    echo "[WARN] Unknown distro; please install: ${pkgs[*]}" >&2
    return 1
  fi
}

fio_install()       { command -v fio       >/dev/null 2>&1 && return 0; __pkg_install fio; }
ethtool_install()   { command -v ethtool   >/dev/null 2>&1 && return 0; __pkg_install ethtool; }
iperf3_install()    { command -v iperf3    >/dev/null 2>&1 && return 0; __pkg_install iperf3; }
smartctl_install()  { command -v smartctl  >/dev/null 2>&1 && return 0; __pkg_install smartmontools; }
hdparm_install()    { command -v hdparm    >/dev/null 2>&1 && return 0; __pkg_install hdparm; }

ensure_tools() {
  # 用法：ensure_tools smartctl hdparm iperf3
  local t
  for t in "$@"; do
    case "$t" in
      smartctl) smartctl_install >/dev/null 2>&1 || true ;;
      hdparm)   hdparm_install   >/dev/null 2>&1 || true ;;
      iperf3)   iperf3_install   >/dev/null 2>&1 || true ;;
      fio)      fio_install      >/dev/null 2>&1 || true ;;
      ethtool)  ethtool_install  >/dev/null 2>&1 || true ;;
      *) : ;;
    esac
  done
}

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

# ---------- USB helpers (reusable by detect_usb / detect_storage) ----------

# 由 block 裝置名 (e.g. sda) 找到對應的 USB sysfs 節點路徑；回傳空字串代表不是 USB。
usb_sysnode_for_block() {
  # usage: usb_sysnode_for_block sda
  local name="$1" sys cur
  sys="/sys$(udevadm info -q path -n "/dev/${name}" 2>/dev/null || true)"
  [[ -z "$sys" ]] && return 1
  cur="$sys"
  while [[ -n "$cur" && "$cur" != "/" ]]; do
    # USB 裝置節點通常會有 /speed 與 /busnum /devnum
    if [[ -f "$cur/speed" && -f "$cur/busnum" && -f "$cur/devnum" ]]; then
      printf '%s\n' "$cur"; return 0
    fi
    cur="$(dirname "$cur")"
  done
  return 1
}

# 讀取目前連線速率 (Mb/s)；回傳數字（如 480/5000/10000/20000），失敗回 "?"
usb_current_speed_mbps() {
  # usage: usb_current_speed_mbps /sys/bus/usb/devices/1-3/...
  local node="$1" v
  if [[ -r "$node/speed" ]]; then
    v="$(tr -d $'\r\n' < "$node/speed")"
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  fi
  printf '?\n'
}

# 讀取 USB bcdUSB（裝置宣稱的 USB 版本），例如 2.00 / 3.20；失敗回 "?"
usb_bcd_version() {
  local node="$1" v
  if [[ -r "$node/version" ]]; then
    v="$(tr -d $'\r\n' < "$node/version")"
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  fi
  printf '?\n'
}

# Mb/s → 人類可讀（支援小數）
usb_fmt_speed() {
  # usage: usb_fmt_speed 5000   -> "5 Gb/s"
  #        usb_fmt_speed 1.5    -> "1.5 Mb/s"
  local mbps="$1"

  # 空值或問號直接回傳
  [[ -z "${mbps:-}" || "${mbps}" == "?" ]] && { echo "?"; return; }

  # 必須是數字（允許小數）
  if [[ ! "$mbps" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "?"
    return
  fi

  # 用 awk 做浮點比較與格式化（避免 [[ -ge ]] 的整數限制）
  awk -v x="$mbps" 'BEGIN{
    if (x >= 1000) { printf "%.0f Gb/s", x/1000.0 }
    else           { printf "%g Mb/s",  x }
  }'
}

# 從 lsusb 解析 *宣稱支援* 的 SuperSpeedPlus 模式（Gen 1x1/2x1/2x2…），回「逗號分隔的列表」。
# 需要 busnum/devnum；抓不到就回空字串。
usb_supported_gens_from_lsusb() {
  # usage: usb_supported_gens_from_lsusb 001 005
  local bus="$1" dev="$2" out modes
  command -v lsusb >/dev/null 2>&1 || { echo ""; return 0; }
  out="$(lsusb -s "${bus}:${dev}" -v 2>/dev/null || true)"
  [[ -z "$out" ]] && { echo ""; return 0; }

  # 解析 SuperSpeedPlus 區段的支援模式行（不同版本 lsusb 字樣略有差異）
  modes="$(printf '%s\n' "$out" \
    | awk '
      /SuperSpeedPlus USB Device Capability/ {ss=1; next}
      ss && /Supported operating modes/ {so=1; next}
      ss && so {
        if ($0 ~ /^[[:space:]]*$/) exit
        g=$0; sub(/^[[:space:]]*/,"",g); sub(/[[:space:]]*$/,"",g)
        # 常見輸出例： "Gen 2x1", "Gen 1x2", "Gen 2x2"
        if (g ~ /^Gen [0-9]+x[0-9]+$/) { print g }
      }
    ' \
    | paste -sd', ' -)"
  echo "$modes"
}

# 將 Gen NxM 映射為速率文字（粗略對照：Gen1=5Gb/s, Gen2=10Gb/s；Nx2 ≈ *2）
usb_gen_to_speed_label() {
  # usage: usb_gen_to_speed_label "Gen 2x2" -> "20 Gb/s"
  local g="$1" n m base
  n="$(printf '%s' "$g" | sed -n 's/Gen \([0-9]\+\)x\([0-9]\+\)/\1/p')"
  m="$(printf '%s' "$g" | sed -n 's/Gen \([0-9]\+\)x\([0-9]\+\)/\2/p')"
  [[ -z "$n" || -z "$m" ]] && { echo "?"; return; }
  # Gen1 ~= 5, Gen2 ~= 10（實際還有編碼差異，這裡取常見名義速率即可）
  if [[ "$n" -eq 1 ]]; then base=5
  elif [[ "$n" -eq 2 ]]; then base=10
  elif [[ "$n" -eq 3 ]]; then base=20   # USB4/3.2 Gen3 名義 20
  else base=$((n*5))
  fi
  echo "$((base*m)) Gb/s"
}

# 匯總：輸入 USB sysfs 節點 → 印一行概要：Current, bcdUSB, SupportedModes
usb_summarize_node() {
  local node="$1"
  local cur_mbps="" cur_human="" ver=""
  local bus="" dev=""
  local gens="" gen_speeds="" t s
  local -a arr=()

  cur_mbps="$(usb_current_speed_mbps "$node")"
  cur_human="$(usb_fmt_speed "$cur_mbps")"
  ver="$(usb_bcd_version "$node")"

  if [[ -r "$node/busnum" && -r "$node/devnum" ]]; then
    bus="$(tr -d $'\r\n' < "$node/busnum")"
    dev="$(tr -d $'\r\n' < "$node/devnum")"
    gens="$(usb_supported_gens_from_lsusb "$bus" "$dev")" || gens=""
  fi

  # 把 gens 轉成速率說明
  if [[ -n "$gens" ]]; then
    IFS=',' read -r -a arr <<<"$gens"
    for t in "${arr[@]}"; do
      t="$(echo "$t" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      s="$(usb_gen_to_speed_label "$t")"
      if [[ -z "$gen_speeds" ]]; then
        gen_speeds="${t}(${s})"
      else
        gen_speeds="${gen_speeds}, ${t}(${s})"
      fi
    done
    printf 'Current=%s  bcdUSB=%s  Supported=%s\n' "$cur_human" "${ver}" "$gen_speeds"
  else
    printf 'Current=%s  bcdUSB=%s\n' "$cur_human" "${ver}"
  fi
}

# 由 lsusb 的 Bus/Device 反查對應的 USB 裝置 sysfs 節點（整數化比較，避免 001 vs 1 對不上）
usb_sysnode_from_bus_dev() {
  local bus_raw="$1" dev_raw="$2"
  # 轉成十進位整數（去前導 0）
  local bus dev fb fd p base
  bus=$((10#$bus_raw))
  dev=$((10#$dev_raw))

  for p in /sys/bus/usb/devices/*; do
    [[ -r "$p/busnum" && -r "$p/devnum" ]] || continue
    fb=$(tr -d $'\r\n' < "$p/busnum" 2>/dev/null || echo "")
    fd=$(tr -d $'\r\n' < "$p/devnum"  2>/dev/null || echo "")
    # 也把檔案內容整數化
    [[ -n "$fb" && -n "$fd" ]] || continue
    fb=$((10#$fb))
    fd=$((10#$fd))
    if (( fb == bus && fd == dev )); then
      base="$(basename "$p")"
      printf '/sys/bus/usb/devices/%s\n' "${base%%:*}"
      return 0
    fi
  done
  return 1
}

# 列出某個 Hub 的所有連接埠；逐埠顯示 Connected/Not Connected
# usage: usb_list_hub_ports <bus> <dev>
usb_list_hub_ports() {
  local bus="$1" dev="$2" node="" base="" prefix="" sep="" ports="" i child child_node
  node="$(usb_sysnode_from_bus_dev "$bus" "$dev" 2>/dev/null || true)" || node=""
  [[ -z "$node" ]] && return 1

  # 取得埠數（bNbrPorts）
  if command -v lsusb >/dev/null 2>&1; then
    ports="$(lsusb -s "${bus}:${dev}" -v 2>/dev/null | awk '/^[[:space:]]*bNbrPorts[[:space:]]/{print $2; exit}')"
  fi
  [[ -z "$ports" ]] && ports=0

  base="$(basename "$node")"
  if [[ "$base" == usb* ]]; then
    # root hub：prefix 是 bus 編號（usb1 -> "1"），子節點長 "1-1", "1-2"
    prefix="${base#usb}"
    sep="-"
  else
    # 外接 hub：prefix 是自身節點名（如 "1-3"），子節點長 "1-3.1", "1-3.2"
    prefix="$base"
    sep="."
  fi

  for (( i=1; i<=ports; i++ )); do
    child="${prefix}${sep}${i}"
    child_node="/sys/bus/usb/devices/${child}"
    if [[ -d "$child_node" ]]; then
      # 有裝置接在該埠
      printf "  Port %-2d : Connected  " "$i"
      usb_summarize_node "$child_node"
    else
      printf "  Port %-2d : Not Connected\n" "$i"
    fi
  done
}

# ---------- PCIe link helpers (shared by detect_pcie_ethernet / detect_storage) ----------

# 由 block 名稱 (e.g. nvme0n1) 回推 PCIe BDF（走 /sys）
pcie_bdf_from_block() {
  local name="$1" p
  p="$(readlink -f "/sys/block/${name}/device" 2>/dev/null || true)"
  while [[ -n "$p" && "$p" != "/" ]]; do
    case "$(basename "$p")" in
      ????\:??\:??\.[0-7]) printf '%s\n' "$(basename "$p")"; return 0 ;;
    esac
    p="$(dirname "$p")"
  done
  return 1
}

# 從 BDF 讀取 LnkCap/LnkSta 與 ASPM（mawk/BusyBox 友善；set -u 安全）
pcie_link_info() {
  # usage: pcie_link_info 0000:3b:00.0
  local bdf="${1:-}" dump cap_line sta_line ctl_line cap_s="" cap_w="" sta_s="" sta_w="" aspm=""
  [[ -z "$bdf" ]] && { echo "||||"; return 1; }
  dump="$(LANG=C lspci -vv -s "$bdf" 2>/dev/null || true)"
  [[ -z "$dump" ]] && { echo "||||"; return 1; }

  cap_line="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*LnkCap:' || true)"
  sta_line="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*LnkSta:' || true)"
  ctl_line="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*LnkCtl:' || true)"

  # 例如：LnkCap: Port #0, Speed 16GT/s, Width x4, ASPM not supported
  [[ -n "$cap_line" ]] && cap_s="$(printf '%s\n' "$cap_line" | sed -n 's/.*Speed \([^,]*\),.*/\1/p')"
  [[ -n "$cap_line" ]] && cap_w="$(printf '%s\n' "$cap_line" | sed -n 's/.*Width x\([0-9]\+\).*/\1/p')"
  # 例如：LnkSta: Speed 8GT/s (ok), Width x4 (ok)
  [[ -n "$sta_line" ]] && sta_s="$(printf '%s\n' "$sta_line" | sed -n 's/.*Speed \([^,]*\).*/\1/p')"
  [[ -n "$sta_line" ]] && sta_w="$(printf '%s\n' "$sta_line" | sed -n 's/.*Width x\([0-9]\+\).*/\1/p')"
  # ASPM：不同平台出現在 LnkCtl 或 LnkCap 註記裡，盡力抓一個可讀狀態
  if [[ -n "$ctl_line" ]]; then
    aspm="$(printf '%s\n' "$ctl_line" | sed -n 's/.*ASPM[[:space:]]*\([^,;)]*\).*/\1/p')"
  fi
  if [[ -z "$aspm" && -n "$cap_line" ]]; then
    aspm="$(printf '%s\n' "$cap_line" | sed -n 's/.*ASPM[[:space:]]*\([^,;)]*\).*/\1/p')"
  fi

  [[ -z "$cap_s"  ]] && cap_s="?"
  [[ -z "$cap_w"  ]] && cap_w="?"
  [[ -z "$sta_s"  ]] && sta_s="?"
  [[ -z "$sta_w"  ]] && sta_w="?"
  [[ -z "$aspm"   ]] && aspm="?"

  printf '%s|%s|%s|%s|%s\n' "$cap_s" "$cap_w" "$sta_s" "$sta_w" "$aspm"
}

# ---------- SATA helpers (shared) ----------
# 從 smartctl 解析「SATA 版本 與 協商速率」；抓不到回 "?|?"
_sata_proto_speed_from_smartctl() {
  local dev="$1" line="" proto="" speed=""
  line="$(smartctl -i "$dev" 2>/dev/null | grep -m1 -i 'SATA Version' || true)"
  if [[ -n "$line" ]]; then
    # 例：SATA Version is: SATA 3.3, 6.0 Gb/s (current: 6.0 Gb/s)
    proto="$(printf '%s\n' "$line" | sed -n 's/.*SATA Version[^:]*:[[:space:]]*\([^,]*\).*/\1/p')"
    speed="$(printf '%s\n' "$line" | sed -n 's/.*\([0-9]\+\(\.[0-9]\+\)\?[[:space:]]*Gb\/s\).*/\1/p')"
  fi
  [[ -z "$proto" ]] && proto="?"
  [[ -z "$speed" ]] && speed="?"
  printf '%s|%s\n' "$proto" "$speed"
}

# 內部：優先無 sudo，失敗再 sudo -n，最後 sudo（都靜默）
_hdparm_try() {  # $1=-i|-I  $2=/dev/sdX
  local mode="$1" dev="$2"
  hdparm "$mode" "$dev" 2>/dev/null \
  || sudo -n hdparm "$mode" "$dev" 2>/dev/null \
  || sudo hdparm "$mode" "$dev" 2>/dev/null
}

# 從 hdparm / smartctl 解析「已啟用的 UDMA 模式」
_sata_udma_mode() {
  local dev="$1" udma="" line=""

  if command -v hdparm >/dev/null 2>&1; then
    # A1) 先試 -I 的「DMA: ... *udmaN」同一行（你的機器是這種）
    udma="$(_hdparm_try -I "$dev" \
           | tr -d '\r' \
           | sed -n 's/.*DMA:.*\*\(udma[0-9]\+\).*/\1/p')" || true

    # A2) 抓不到再掃 -I 的「UDMA modes:」區塊（有些機器長這樣）
    if [[ -z "$udma" ]]; then
      udma="$(_hdparm_try -I "$dev" \
             | tr -d '\r' \
             | sed -n '/UDMA[[:space:]]*modes:/,/^[[:space:]]*$/p' \
             | tr '\n' ' ' \
             | sed -n 's/.*UDMA[[:space:]]*modes:[^*]*\*\(udma[0-9]\+\).*/\1/p')" || true
    fi

    # B) 再抓不到，改用 -i（舊式「UDMA modes: ... *udmaN」）
    if [[ -z "$udma" ]]; then
      udma="$(_hdparm_try -i "$dev" \
             | tr -d '\r' \
             | sed -n 's/.*UDMA[[:space:]]*modes:[[:space:]]*.*\*\(udma[0-9]\+\).*/\1/p')" || true
    fi
  fi

  # C) 最後以 smartctl 備援（"UDMA Mode: udma6"）
  if [[ -z "$udma" ]] && command -v smartctl >/dev/null 2>&1; then
    line="$(smartctl -i "$dev" 2>/dev/null | tr -d '\r' | grep -m1 -i 'UDMA Mode' || true)"
    [[ -n "$line" ]] && udma="$(printf '%s\n' "$line" | sed -n 's/.*UDMA[[:space:]]*Mode:[[:space:]]*\([^ ]*\).*/\1/p')" || true
  fi

  [[ -z "$udma" ]] && udma="?"
  printf '%s\n' "$udma"
}

# 一次匯總：輸入 /dev/sdX → 回傳 "proto|link|udma"
sata_summarize_dev() {
  local dev="$1"
  local proto="?" link="?" udma="?" line p l gen dump

  # 1) smartctl：抓 "SATA Version ..., 6.0 Gb/s (current: ...)"
  if command -v smartctl >/dev/null 2>&1; then
    line="$(smartctl -i "$dev" 2>/dev/null | grep -m1 -i 'SATA Version' || true)"
    if [[ -n "$line" ]]; then
      p="$(printf '%s\n' "$line" | sed -n 's/.*SATA Version[^:]*:[[:space:]]*\([^,]*\).*/\1/p')"
      l="$(printf '%s\n' "$line" | sed -n 's/.*\([0-9]\+\(\.[0-9]\+\)\?[[:space:]]*Gb\/s\).*/\1/p')"
      [[ -n "$p" ]] && proto="$p"
      [[ -n "$l" ]] && link="$l"
      if [[ "$link" == "?" ]]; then
        # 再退一步抓冒號後第一個 Gb/s
        [[ -n "$l" ]] && l="$(printf '%s\n' "$l" | sed -E 's/([0-9])\s*(Gb\/s|Mb\/s)/\1 \2/')"
        [[ -n "$l" ]] && link="$l"
      fi
    fi
  fi

  # 2) 若還是異常（空或 "0 Gb/s"），用 hdparm -I 的 "GenX signaling speed (...Gb/s)" 補
  if [[ -z "$link" || "$link" == "?" || "$link" == "0 Gb/s" ]]; then
    if command -v hdparm >/dev/null 2>&1; then
      # 例： "Gen1 signaling speed (1.5Gb/s)"、"Gen2 ... (3.0Gb/s)"、"Gen3 ... (6.0Gb/s)"
      local hl gennum rate
      hl="$(_hdparm_try -I "$dev" | tr -d '\r' | sed -n 's/.*Gen\([0-9]\+\)[^()]*(\([0-9]\+\(\.[0-9]\+\)\?Gb\/s\)).*/\1|\2/p' | head -n1)"
      if [[ -n "$hl" ]]; then
        gennum="${hl%%|*}"
        rate="${hl##*|}"
        # 正規化速率：1.5Gb/s → 1.5 Gb/s
        rate="$(printf '%s\n' "$rate" | sed -E 's/([0-9])\s*(Gb\/s|Mb\/s)/\1 \2/')"
        link="$rate"
        # 依 Gen 直接決定 proto
        case "$gennum" in
          1) proto="SATA 1.x" ;;
          2) proto="SATA 2.x" ;;
          3) proto="SATA 3.x" ;;
          4) proto="SATA 4.x" ;;
        esac
      else
        # 抓不到 Gen，僅有速率時用 hdparm 另一個式子抓速率
        l="$(_hdparm_try -I "$dev" \
            | tr -d '\r' \
            | sed -n 's/.*Gen[1234][^()]*(\([0-9]\+\(\.[0-9]\+\)\?Gb\/s\)).*/\1/p' \
            | head -n1)"
        if [[ -n "$l" ]]; then
          l="$(printf '%s\n' "$l" | sed -E 's/([0-9])\s*(Gb\/s|Mb\/s)/\1 \2/')"
          link="$l"
          # 由速率反推 proto
          case "$l" in
            1.5\ Gb/s) proto="SATA 1.x" ;;
            3.0\ Gb/s) proto="SATA 2.x" ;;
            6.0\ Gb/s) proto="SATA 3.x" ;;
            12.0\ Gb/s) proto="SATA 4.x" ;;
          esac
        fi
      fi
    fi
  fi

  # 3) 再不行，用 udev Gen → 速率對照
  if [[ -z "$link" || "$link" == "?" || "$link" == "0 Gb/s" ]]; then
    if command -v udevadm >/dev/null 2>&1; then
      dump="$(udevadm info -q property -n "$dev" 2>/dev/null || true)"
      if printf '%s\n' "$dump" | grep -q '^ID_ATA_SATA=1$'; then
        if   printf '%s\n' "$dump" | grep -q '^ID_ATA_SATA_SIGNAL_RATE_GEN3=1$'; then gen=3
        elif printf '%s\n' "$dump" | grep -q '^ID_ATA_SATA_SIGNAL_RATE_GEN2=1$'; then gen=2
        elif printf '%s\n' "$dump" | grep -q '^ID_ATA_SATA_SIGNAL_RATE_GEN1=1$'; then gen=1
        fi
        [[ -n "$gen" ]] && {
          [[ "$proto" == "?" ]] && proto="SATA 3.x"
          case "$gen" in
            1) link="1.5 Gb/s" ;;
            2) link="3.0 Gb/s" ;;
            3) link="6.0 Gb/s" ;;
            4) link="12.0 Gb/s" ;;
          esac
        }
      fi
    fi
  fi

  # 4) UDMA 一律用穩定的解析器（你已驗證 OK）
  udma="$(_sata_udma_mode "$dev")"

  printf '%s|%s|%s\n' "${proto:-?}" "${link:-?}" "${udma:-?}"
}

_sata_rate_for_gen() {
  # $1 = 1|2|3|…  回 1.5 Gb/s | 3.0 Gb/s | 6.0 Gb/s（未知回 ?）
  case "$1" in
    1) echo "1.5 Gb/s" ;;
    2) echo "3.0 Gb/s" ;;
    3) echo "6.0 Gb/s" ;;
    4) echo "12.0 Gb/s" ;;  # SATA 4.0（少見，預留）
    *) echo "?" ;;
  esac
}
