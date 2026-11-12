#!/usr/bin/env bash
# End-to-end trace path: starts Tempo and the OTel collector with the repo's configs on a throwaway network, sends one
# span to the collector over OTLP/HTTP (the way Backend does) and fails unless Tempo returns that trace. Needs docker, curl, jq.
set -euo pipefail
net=tracing-check
tempo=$(grep -oE 'grafana/tempo:[0-9.]+' docker-compose.yml | head -1)
otel=$(grep -oE 'otel/opentelemetry-collector-contrib:[0-9.]+' docker-compose.yml | head -1)
cleanup() { docker rm -f "$net-tempo" "$net-otel" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create "$net" >/dev/null

docker run -d --name "$net-tempo" --network "$net" --network-alias tempo -p 127.0.0.1:3298:3200 \
  -v "$PWD/tempo/tempo.yml:/etc/tempo/tempo.yml:ro" "$tempo" -config.file=/etc/tempo/tempo.yml >/dev/null
docker run -d --name "$net-otel" --network "$net" -p 127.0.0.1:4398:4318 \
  -v "$PWD/otel/config.yml:/etc/otelcol/config.yml:ro" "$otel" --config=/etc/otelcol/config.yml >/dev/null

wait_for() { # description, url
  for _ in $(seq 1 60); do curl -fs "$2" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "FAIL $1 did not become ready"; docker logs "$net-tempo" 2>&1 | tail -15; docker logs "$net-otel" 2>&1 | tail -15; exit 1
}
wait_for "tempo" http://127.0.0.1:3298/ready
echo "ok   tempo ready"
# the collector has no health endpoint here: it accepts OTLP once the port answers
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:4398/v1/traces || true)
  [ "$code" = 200 ] && break
  sleep 1
done
[ "$code" = 200 ] || { echo "FAIL collector OTLP/HTTP answered '$code'"; docker logs "$net-otel" 2>&1 | tail -15; exit 1; }
echo "ok   collector accepts OTLP/HTTP"

tid=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
sid=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
now=$(date +%s)
body=$(jq -n --arg t "$tid" --arg s "$sid" --arg a "${now}000000000" --arg b "$((now + 1))000000000" '{resourceSpans:[{
  resource:{attributes:[{key:"service.name",value:{stringValue:"tracing-check"}}]},
  scopeSpans:[{spans:[{traceId:$t,spanId:$s,name:"check",kind:1,startTimeUnixNano:$a,endTimeUnixNano:$b}]}]}]}')
curl -fsS -X POST -H 'Content-Type: application/json' -d "$body" http://127.0.0.1:4398/v1/traces >/dev/null
echo "ok   sent trace $tid"

# batch timeout 5s in the collector, then Tempo's ingester serves the live trace by id
for _ in $(seq 1 45); do
  got=$(curl -fs "http://127.0.0.1:3298/api/traces/$tid" 2>/dev/null | jq -r '[.. | objects | select(has("name")) | .name] | index("check")' 2>/dev/null || true)
  if [ -n "$got" ] && [ "$got" != null ]; then echo "ok   Tempo returned the trace"; exit 0; fi
  sleep 2
done
echo "FAIL Tempo never returned trace $tid"
docker logs "$net-tempo" 2>&1 | tail -15; docker logs "$net-otel" 2>&1 | tail -15
exit 1
