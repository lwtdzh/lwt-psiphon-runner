#!/usr/bin/env bash
set -euo pipefail
ORIGINAL_ARGS=("$@")

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT_DIR/psiphon-tunnel-core-x86_64"
BASE_CONFIG="$ROOT_DIR/client.config"
FORWARDER="$ROOT_DIR/tcp-forward.py"
INSTANCES_DIR="$ROOT_DIR/instances"
PUBLIC_BIND="0.0.0.0"

usage() {
  cat <<'USAGE'
Usage:
  ./run-psiphon.sh run [-l LOCATION|--location LOCATION] [-p PORT|--port PORT]
  ./run-psiphon.sh [-l LOCATION|--location LOCATION] [-p PORT|--port PORT]
  ./run-psiphon.sh service start [-l LOCATION|--location LOCATION] [-p PORT|--port PORT]
  ./run-psiphon.sh service stop [-l LOCATION|--location LOCATION] [-p PORT|--port PORT]
  ./run-psiphon.sh status
  ./run-psiphon.sh stop [-l LOCATION|--location LOCATION] [-p PORT|--port PORT]
  ./run-psiphon.sh locations

Notes:
  - PORT is the public SOCKS5 listener on 0.0.0.0.
  - The public HTTP listener uses PORT+1 because Psiphon requires separate ports.
  - Each LOCATION+PORT pair gets an isolated working directory, config, log, and PIDs.
  - Psiphon listens on private 127.0.0.1 ports; TCP forwarders expose 0.0.0.0.
USAGE
}

locations() {
  cat <<'LOCATIONS'
Supported location inputs:
  US  United States
  CA  Canada
  GB  United Kingdom
  DE  Germany
  FR  France
  NL  Netherlands
  JP  Japan
  SG  Singapore
  AU  Australia
  AT  Austria
  BE  Belgium
  BG  Bulgaria
  CH  Switzerland
  CZ  Czech Republic
  DK  Denmark
  ES  Spain
  FI  Finland
  HU  Hungary
  IE  Ireland
  IT  Italy
  NO  Norway
  PL  Poland
  RO  Romania
  SE  Sweden
LOCATIONS
}

normalize_location() {
  local raw
  raw="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/[[:space:]_-]+/ /g')"
  case "$raw" in
    US|USA|"UNITED STATES"|"UNITED STATES OF AMERICA"|AMERICA) echo US ;;
    CA|CANADA) echo CA ;;
    GB|UK|"UNITED KINGDOM"|"GREAT BRITAIN"|BRITAIN) echo GB ;;
    DE|GERMANY|DEUTSCHLAND) echo DE ;;
    FR|FRANCE) echo FR ;;
    NL|NETHERLANDS|HOLLAND) echo NL ;;
    JP|JAPAN) echo JP ;;
    SG|SINGAPORE) echo SG ;;
    AU|AUSTRALIA) echo AU ;;
    AT|AUSTRIA) echo AT ;;
    BE|BELGIUM) echo BE ;;
    BG|BULGARIA) echo BG ;;
    CH|SWITZERLAND) echo CH ;;
    CZ|CZECH|"CZECH REPUBLIC"|CZECHIA) echo CZ ;;
    DK|DENMARK) echo DK ;;
    ES|SPAIN) echo ES ;;
    FI|FINLAND) echo FI ;;
    HU|HUNGARY) echo HU ;;
    IE|IRELAND) echo IE ;;
    IT|ITALY) echo IT ;;
    NO|NORWAY) echo NO ;;
    PL|POLAND) echo PL ;;
    RO|ROMANIA) echo RO ;;
    SE|SWEDEN) echo SE ;;
    *) return 1 ;;
  esac
}

die() {
  echo "error: $*" >&2
  exit 1
}

resolve_location_port() {
  local location="${1:-}" socks_port="${2:-}"
  if [[ -z "$location" ]]; then
    locations
    printf 'Which country/location? '
    read -r location
  fi
  RESOLVED_LOCATION="$(normalize_location "$location")" || die "unsupported location: $location"

  if [[ -z "$socks_port" ]]; then
    printf 'Which SOCKS5 port should listen on 0.0.0.0? '
    read -r socks_port
  fi
  validate_port "$socks_port"
  RESOLVED_PORT="$socks_port"
}

need_root() {
  if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      exec sudo -n -- "$0" "${ORIGINAL_ARGS[@]}"
    fi
    die "this runner needs root or passwordless sudo to expose 0.0.0.0 ports, including low ports"
  fi
}

need_files() {
  [[ -x "$BIN" ]] || die "missing executable: $BIN"
  [[ -r "$BASE_CONFIG" ]] || die "missing config: $BASE_CONFIG"
  [[ -x "$FORWARDER" ]] || die "missing forwarder: $FORWARDER"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "port must be a number"
  (( port >= 1 && port <= 65534 )) || die "port must be between 1 and 65534"
}

port_available() {
  local host="$1" port="$2"
  python3 - "$host" "$port" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind((host, port))
except OSError as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)
finally:
    s.close()
PY
}

free_loopback_port() {
  python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

generate_config() {
  local location="$1" socks_port="$2" http_port="$3" out="$4"
  if command -v jq >/dev/null 2>&1; then
    jq \
      --arg region "$location" \
      --argjson socks "$socks_port" \
      --argjson http "$http_port" \
      '.EgressRegion=$region | .LocalSocksProxyPort=$socks | .LocalHttpProxyPort=$http' \
      "$BASE_CONFIG" > "$out"
  else
    python3 - "$BASE_CONFIG" "$out" "$location" "$socks_port" "$http_port" <<'PY'
import json, sys
src, dst, region, socks, http = sys.argv[1:]
with open(src, "r", encoding="utf-8") as f:
    cfg = json.load(f)
cfg["EgressRegion"] = region
cfg["LocalSocksProxyPort"] = int(socks)
cfg["LocalHttpProxyPort"] = int(http)
with open(dst, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  fi
}

cmdline_contains() {
  local pid="$1" needle="$2"
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" | grep -F -- "$needle" >/dev/null
}

running_psiphon_pid() {
  local pid_file="$1" conf="$2"
  [[ -s "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmdline_contains "$pid" "$conf" || cmdline_contains "$pid" "./client.config" || return 1
  printf '%s\n' "$pid"
}

running_forwarder_pid() {
  local pid_file="$1" public_port="$2"
  [[ -s "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmdline_contains "$pid" "tcp-forward.py" || return 1
  cmdline_contains "$pid" "--port $public_port" || return 1
  printf '%s\n' "$pid"
}

wait_for_port() {
  local port="$1" timeout="${2:-45}" deadline
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_region() {
  local log_file="$1" timeout="${2:-90}" deadline
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    grep -q '"noticeType":"ConnectedServerRegion"' "$log_file" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

status_all() {
  need_root "$@"
  mkdir -p "$INSTANCES_DIR"
  local found=0
  for pid_file in "$INSTANCES_DIR"/*/psiphon.pid; do
    [[ -e "$pid_file" ]] || continue
    found=1
    local dir conf pid label
    dir="$(dirname "$pid_file")"
    conf="$dir/client.config"
    label="$(basename "$dir")"
    if pid="$(running_psiphon_pid "$pid_file" "$conf")"; then
      local PUBLIC_SOCKS_PORT="?" PUBLIC_HTTP_PORT="?" INTERNAL_SOCKS_PORT="?" INTERNAL_HTTP_PORT="?"
      [[ -r "$dir/ports.env" ]] && source "$dir/ports.env"
      local socks_forward_pid http_forward_pid
      socks_forward_pid="$(running_forwarder_pid "$dir/socks-forward.pid" "$PUBLIC_SOCKS_PORT" 2>/dev/null || true)"
      http_forward_pid="$(running_forwarder_pid "$dir/http-forward.pid" "$PUBLIC_HTTP_PORT" 2>/dev/null || true)"
      echo "$label running psiphon_pid=$pid socks=0.0.0.0:$PUBLIC_SOCKS_PORT socks_forward_pid=${socks_forward_pid:-stopped} http=0.0.0.0:$PUBLIC_HTTP_PORT http_forward_pid=${http_forward_pid:-stopped} internal_socks=127.0.0.1:$INTERNAL_SOCKS_PORT internal_http=127.0.0.1:$INTERNAL_HTTP_PORT"
    else
      echo "$label stopped"
    fi
  done
  (( found == 1 )) || echo "no runner instances"
}

service_unit_name() {
  local location="$1" socks_port="$2"
  printf 'lwt-psiphon-%s-%s.service' "$(printf '%s' "$location" | tr '[:upper:]' '[:lower:]')" "$socks_port"
}

service_start() {
  need_root "$@"
  need_files
  resolve_location_port "${1:-}" "${2:-}"
  local location="$RESOLVED_LOCATION" socks_port="$RESOLVED_PORT"
  local unit
  unit="$(service_unit_name "$location" "$socks_port")"
  local unit_path="/etc/systemd/system/$unit"

  command -v systemctl >/dev/null 2>&1 || die "systemctl is not available on this host"

  cat > "$unit_path" <<EOF
[Unit]
Description=LWT Psiphon runner $location on port $socks_port
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ROOT_DIR
ExecStart=$ROOT_DIR/run-psiphon.sh run -l $location -p $socks_port
ExecStop=$ROOT_DIR/run-psiphon.sh stop -l $location -p $socks_port
TimeoutStartSec=180
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$unit"
  systemctl --no-pager --full status "$unit" | sed -n '1,18p' || true
}

service_stop() {
  need_root "$@"
  resolve_location_port "${1:-}" "${2:-}"
  local location="$RESOLVED_LOCATION" socks_port="$RESOLVED_PORT"
  local unit
  unit="$(service_unit_name "$location" "$socks_port")"

  command -v systemctl >/dev/null 2>&1 || die "systemctl is not available on this host"

  systemctl disable --now "$unit" 2>/dev/null || true
  systemctl daemon-reload
  echo "service stopped: $unit"
}

start_instance() {
  need_root "$@"
  need_files

  resolve_location_port "${1:-}" "${2:-}"
  local location="$RESOLVED_LOCATION" socks_port="$RESOLVED_PORT"
  local http_port=$((socks_port + 1))

  local instance_dir="$INSTANCES_DIR/${location}-${socks_port}"
  local conf="$instance_dir/client.config"
  local log_file="$instance_dir/psiphon.log"
  local pid_file="$instance_dir/psiphon.pid"
  local socks_forward_pid_file="$instance_dir/socks-forward.pid"
  local http_forward_pid_file="$instance_dir/http-forward.pid"
  local lock_file="$instance_dir/runner.lock"
  local ports_file="$instance_dir/ports.env"

  mkdir -p "$instance_dir"
  exec 9>"$lock_file"
  flock -n 9 || die "instance $location/$socks_port is locked by another start"

  local pid
  if pid="$(running_psiphon_pid "$pid_file" "$conf")"; then
    echo "already running: location=$location socks=0.0.0.0:$socks_port http=0.0.0.0:$http_port pid=$pid"
    exit 0
  fi

  port_available "$PUBLIC_BIND" "$socks_port" || die "SOCKS port $socks_port is not available"
  port_available "$PUBLIC_BIND" "$http_port" || die "HTTP port $http_port is not available"
  local internal_socks_port internal_http_port
  internal_socks_port="$(free_loopback_port)"
  internal_http_port="$(free_loopback_port)"
  port_available 127.0.0.1 "$internal_socks_port" || die "internal SOCKS port allocation failed"
  port_available 127.0.0.1 "$internal_http_port" || die "internal HTTP port allocation failed"

  generate_config "$location" "$internal_socks_port" "$internal_http_port" "$conf"
  cat > "$ports_file" <<EOF
PUBLIC_SOCKS_PORT=$socks_port
PUBLIC_HTTP_PORT=$http_port
INTERNAL_SOCKS_PORT=$internal_socks_port
INTERNAL_HTTP_PORT=$internal_http_port
EOF

  : > "$log_file"
  (
    cd "$instance_dir"
    nohup "$BIN" -config ./client.config > "$log_file" 2>&1 &
    echo $! > "$pid_file"
  )
  pid="$(cat "$pid_file")"

  if ! wait_for_port "$internal_socks_port" 45; then
    tail -80 "$log_file" >&2 || true
    die "internal SOCKS port $internal_socks_port did not open"
  fi
  wait_for_port "$internal_http_port" 15 || true

  nohup python3 "$FORWARDER" --listen "$PUBLIC_BIND" --port "$socks_port" --target-host 127.0.0.1 --target-port "$internal_socks_port" > "$instance_dir/socks-forward.log" 2>&1 &
  echo $! > "$socks_forward_pid_file"
  nohup python3 "$FORWARDER" --listen "$PUBLIC_BIND" --port "$http_port" --target-host 127.0.0.1 --target-port "$internal_http_port" > "$instance_dir/http-forward.log" 2>&1 &
  echo $! > "$http_forward_pid_file"

  if ! wait_for_port "$socks_port" 15; then
    cat "$instance_dir/socks-forward.log" >&2 || true
    die "public SOCKS port $socks_port did not open"
  fi
  wait_for_port "$http_port" 15 || true
  wait_for_region "$log_file" 90 || true

  echo "started: location=$location socks=0.0.0.0:$socks_port http=0.0.0.0:$http_port pid=$pid"
  echo "internal: socks=127.0.0.1:$internal_socks_port http=127.0.0.1:$internal_http_port"
  echo "log: $log_file"
}

stop_instance() {
  need_root "$@"
  resolve_location_port "${1:-}" "${2:-}"
  local location="$RESOLVED_LOCATION" socks_port="$RESOLVED_PORT"

  local instance_dir="$INSTANCES_DIR/${location}-${socks_port}"
  local conf="$instance_dir/client.config"
  local pid_file="$instance_dir/psiphon.pid"
  local http_port=$((socks_port + 1))

  local item fpid_file public_port fpid
  for item in "$instance_dir/socks-forward.pid:$socks_port" "$instance_dir/http-forward.pid:$http_port"; do
    fpid_file="${item%%:*}"
    public_port="${item##*:}"
    if fpid="$(running_forwarder_pid "$fpid_file" "$public_port" 2>/dev/null)"; then
      kill "$fpid" || true
    fi
  done

  local pid
  if pid="$(running_psiphon_pid "$pid_file" "$conf")"; then
    kill "$pid"
    echo "stopped: location=$location socks=$socks_port pid=$pid"
  else
    echo "not running: location=$location socks=$socks_port"
  fi
}

main() {
  local mode="start" service_action="" location="" port=""

  if (($# > 0)); then
    case "$1" in
      status) status_all "$@"; exit 0 ;;
      locations) locations; exit 0 ;;
      run) mode="start"; shift ;;
      service)
        mode="service"
        shift
        [[ $# -ge 1 ]] || die "service requires start or stop"
        service_action="$1"
        shift
        case "$service_action" in
          start|stop) ;;
          *) die "service action must be start or stop" ;;
        esac
        ;;
      stop) mode="stop"; shift ;;
      -h|--help) usage; exit 0 ;;
    esac
  fi

  while (($#)); do
    case "$1" in
      -l|--location)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        location="$2"; shift 2 ;;
      --location=*)
        location="${1#*=}"; shift ;;
      -p|--port)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        port="$2"; shift 2 ;;
      --port=*)
        port="${1#*=}"; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "unknown argument: $1" ;;
    esac
  done

  case "$mode" in
    start) start_instance "$location" "$port" ;;
    stop) stop_instance "$location" "$port" ;;
    service)
      case "$service_action" in
        start) service_start "$location" "$port" ;;
        stop) service_stop "$location" "$port" ;;
      esac
      ;;
  esac
}

main "$@"
