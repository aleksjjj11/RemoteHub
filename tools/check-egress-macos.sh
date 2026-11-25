#!/usr/bin/env bash
# Runtime network check of a built Remote Hub app on macOS (plan 24.6, M3).
#
# Usage: tools/check-egress-macos.sh "<path>/Remote Hub.app" [--host] [--seconds N]
#
#   --host       start in the host role with access on (writes only the Remote Hub
#                config of this user: ~/Library/Preferences/com.carriez.RemoteHub)
#   --seconds N  how long to observe (default 60)
#
# Launches the app, samples every inet socket of its processes once per second,
# then quits it and prints what it saw. Fails if any process
#   * listens on anything but 127.0.0.1:22118 (and only in --host mode), or
#   * has a connection to an address outside loopback and the Tailscale ranges.
# Traffic of the Tailscale daemon itself is not attributed to the app.
#
# Exit codes: 0 pass, 1 policy violation, 2 bad arguments or the app did not start.
set -euo pipefail

APP="${1:-}"
[[ -d "$APP" ]] || { echo "usage: $0 <Remote Hub.app> [--host] [--seconds N]" >&2; exit 2; }
shift
HOST=0
SECONDS_TO_WATCH=60
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST=1; shift ;;
    --seconds) SECONDS_TO_WATCH="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

CONF_DIR="$HOME/Library/Preferences/com.carriez.RemoteHub"
CONF="$CONF_DIR/RemoteHub2.toml"
if [[ -e "$CONF" ]]; then
  echo "refusing to touch an existing Remote Hub configuration: $CONF" >&2
  exit 2
fi
if [[ $HOST == 1 ]]; then
  mkdir -p "$CONF_DIR"
  printf "[options]\nremote-hub-role = 'host'\nremote-hub-host-enabled = 'Y'\n" > "$CONF"
fi

EXE="$APP/Contents/MacOS"
open -n "$APP"
SAMPLES="$(mktemp)"
trap 'rm -f "$SAMPLES"' EXIT
started=0
for _ in $(seq 1 "$SECONDS_TO_WATCH"); do
  PIDS="$(pgrep -f "$EXE" | paste -sd, - || true)"
  if [[ -n "$PIDS" ]]; then
    started=1
    lsof -nP -a -p "$PIDS" -i 2>/dev/null | tail -n +2 >> "$SAMPLES" || true
  fi
  sleep 1
done
pkill -f "$EXE" || true
[[ $started == 1 ]] || { echo "the app did not start" >&2; exit 2; }

python3 - "$SAMPLES" "$HOST" <<'PY'
import ipaddress, re, sys
lines = open(sys.argv[1]).read().splitlines()
host = sys.argv[2] == "1"
allowed_nets = [ipaddress.ip_network(n) for n in
                ("127.0.0.0/8", "::1/128", "100.64.0.0/10", "fd7a:115c:a1e0::/48")]
def ip_of(endpoint):
    ep = endpoint.split("->")[-1]
    ep = ep.rsplit(":", 1)[0].strip("[]")
    return ep
seen, bad = set(), []
for line in lines:
    parts = line.split()
    if len(parts) < 9:
        continue
    cmd, proto, name = parts[0], parts[7], " ".join(parts[8:])
    key = (cmd, proto, name)
    if key in seen:
        continue
    seen.add(key)
    print(f"{cmd:12} {proto:4} {name}")
    if "(LISTEN)" in name or (proto == "UDP" and "->" not in name):
        local = name.split()[0]
        if not (host and proto == "TCP" and local == "127.0.0.1:22118"):
            bad.append(f"listener {proto} {local}")
    elif "->" in name:
        ip = ip_of(name.split()[0])
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            bad.append(f"unparsed peer {name}")
            continue
        if not any(addr in n for n in allowed_nets):
            bad.append(f"connection to {addr}")
if host and not any("127.0.0.1:22118 (LISTEN)" in k[2] for k in seen):
    bad.append("host mode: 127.0.0.1:22118 was not listening")
print()
for b in sorted(set(bad)):
    print("FAIL", b)
print("PASS" if not bad else f"{len(set(bad))} violation(s)")
sys.exit(1 if bad else 0)
PY
