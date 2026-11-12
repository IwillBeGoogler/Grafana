#!/usr/bin/env bash
# Starts Grafana with the provisioning files and fails when datasources, contact point, notification policy
# or alert rules do not load. Needs docker.
set -euo pipefail
name=grafana-check
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker rm -f "$name" >/dev/null 2>&1 || true

image=$(grep -oE 'grafana/grafana:[0-9.]+' docker-compose.yml | head -1)
docker run -d --name "$name" -p 127.0.0.1:3299:3000 \
  -e GF_SECURITY_ADMIN_PASSWORD=check -e GF_UNIFIED_ALERTING_ENABLED=true -e TELEGRAM_BOT_TOKEN=0:check \
  -v "$PWD/grafana/provisioning:/etc/grafana/provisioning:ro" -v "$PWD/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  "$image" >/dev/null

for _ in $(seq 1 40); do
  curl -fs -u admin:check http://127.0.0.1:3299/api/health >/dev/null 2>&1 && break
  sleep 2
done
sleep 5

api() { curl -fsS -u admin:check "http://127.0.0.1:3299$1"; }
fail=0
check() { # description, jq filter, expected substring
  local got; got=$(api "$2" | jq -r "$3" | tr '\n' ' ')
  if [[ $got == *"$4"* ]]; then echo "ok   $1: $got"; else echo "FAIL $1: expected '$4', got '$got'"; fail=1; fi
}
check "datasources"   /api/datasources                         '.[].name'  "Prometheus"
check "tempo"         /api/datasources/uid/tempo               '.type + " " + .url'  "tempo http://tempo:3200"
check "service map"   /api/datasources/uid/tempo              '.jsonData.serviceMap.datasourceUid'  "prometheus"
check "loki to tempo" /api/datasources/uid/loki                '.jsonData.derivedFields[0].datasourceUid'  "tempo"
if api /api/datasources | jq -e '[.[].type] | index("jaeger")' >/dev/null; then echo "FAIL a Jaeger datasource is still provisioned"; fail=1; fi
check "contact point" /api/v1/provisioning/contact-points      '.[].name'  "telegram"
check "policy"        /api/v1/provisioning/policies            '.receiver' "telegram"
check "alert rules"   /api/v1/provisioning/alert-rules         '.[].title' "ApiErrorRate"

if docker logs "$name" 2>&1 | grep -E 'level=error' | grep -E 'provisioning' | grep -vE 'plugins'; then
  echo "FAIL provisioning errors in the Grafana log"; fail=1
fi
exit "$fail"
