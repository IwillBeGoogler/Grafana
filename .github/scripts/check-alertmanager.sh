#!/usr/bin/env bash
# Validates alertmanager.yml and asserts the routing: which receiver gets which alert. Needs docker.
set -euo pipefail
image=$(grep -oE 'prom/alertmanager:[v0-9.]+' docker-compose.yml | head -1)
tmp=$(mktemp -d); touch "$tmp/telegram_token"
am() { docker run --rm --entrypoint amtool -v "$PWD/alertmanager/alertmanager.yml:/a.yml:ro" -v "$tmp/telegram_token:/etc/alertmanager/telegram_token:ro" "$image" "$@"; }

am check-config /a.yml

fail=0
expect() { # receiver, labels...
  local want=$1; shift
  local got; got=$(am config routes test --config.file /a.yml "$@" | tail -1)
  if [ "$got" = "$want" ]; then echo "ok   $* -> $got"; else echo "FAIL $* -> $got (want $want)"; fail=1; fi
}
expect null               alertname=Watchdog severity=none
expect telegram-critical  alertname=TargetDown severity=critical
expect telegram-warning   alertname=HostCpuHigh severity=warning
expect telegram-warning   alertname=SomethingNew
exit "$fail"
