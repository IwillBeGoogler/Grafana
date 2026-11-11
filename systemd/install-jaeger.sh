#!/usr/bin/env bash
# Jaeger on the host under systemd instead of a container. Run once as root on the server, after the monitoring rollout
# has put the config in /opt/monitoring/jaeger/config.yaml (deploy-docker.sh); idempotent.
#   systemd/install-jaeger.sh [IMAGE]       default jaegertracing/jaeger:2.23.0 (the binary is taken from that image)
# Listens on the docker gateway 172.30.0.1 only (4317/4318 OTLP, 16686 UI, 16685 gRPC); containers resolve it as `jaeger`
# (--add-host in deploy-docker.sh); host nginx proxies jaeger.<domain> to 172.30.0.1:16686 with basic auth.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
IMAGE=${1:-jaegertracing/jaeger:2.23.0}
CFG=/opt/monitoring/jaeger/config.yaml
[ -r "$CFG" ] || { echo "$CFG missing: run the monitoring rollout first" >&2; exit 1; }
ip -4 addr show | grep -q 'inet 172.30.0.1/' || { echo "172.30.0.1 not on any interface (docker network iwillbegoogler)" >&2; exit 1; }
docker pull -q "$IMAGE" >/dev/null
cid=$(docker create "$IMAGE")
trap 'docker rm "$cid" >/dev/null' EXIT
docker cp "$cid:/cmd/jaeger/jaeger-linux" /usr/local/bin/jaeger.new
install -m 0755 -o root -g root /usr/local/bin/jaeger.new /usr/local/bin/jaeger
rm -f /usr/local/bin/jaeger.new
getent passwd jaeger >/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin jaeger
install -m 0644 "$(dirname "$0")/jaeger.service" /etc/systemd/system/jaeger.service
systemctl daemon-reload
systemctl enable jaeger >/dev/null
systemctl restart jaeger
for _ in $(seq 20); do curl -fsS http://172.30.0.1:16686/ >/dev/null 2>&1 && { echo "jaeger ok (172.30.0.1:16686)"; exit 0; }; sleep 1; done
journalctl -u jaeger -n 20 --no-pager >&2
exit 1
