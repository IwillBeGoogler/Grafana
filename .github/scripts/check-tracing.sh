#!/usr/bin/env bash
# End-to-end trace path: starts Prometheus, Tempo and the OTel collector with the repo's configs on a throwaway network,
# sends a client+server span pair to the collector over OTLP/HTTP (the way Backend does) and fails unless Tempo returns that
# trace AND its metrics generator has pushed the service-graph edge into Prometheus. Needs docker, curl, jq.
set -euo pipefail
net=tracing-check
tempo=$(grep -oE 'grafana/tempo:[0-9.]+' docker-compose.yml | head -1)
otel=$(grep -oE 'otel/opentelemetry-collector-contrib:[0-9.]+' docker-compose.yml | head -1)
prom=$(grep -oE 'prom/prometheus:v[0-9.]+' docker-compose.yml | head -1)
cleanup() { docker rm -f "$net-prom" "$net-tempo" "$net-otel" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create "$net" >/dev/null

# Prometheus with a minimal config plus the remote-write receiver Tempo pushes into
docker run -d --name "$net-prom" --network "$net" --network-alias prometheus -p 127.0.0.1:3297:9090 \
  -v "$PWD/.github/scripts/check-prometheus.yml:/etc/prometheus/prometheus.yml:ro" "$prom" \
  --config.file=/etc/prometheus/prometheus.yml --web.enable-remote-write-receiver >/dev/null
docker run -d --name "$net-tempo" --network "$net" --network-alias tempo -p 127.0.0.1:3298:3200 \
  -v "$PWD/tempo/tempo.yml:/etc/tempo/tempo.yml:ro" "$tempo" -config.file=/etc/tempo/tempo.yml >/dev/null
docker run -d --name "$net-otel" --network "$net" -p 127.0.0.1:4398:4318 \
  -v "$PWD/otel/config.yml:/etc/otelcol/config.yml:ro" "$otel" --config=/etc/otelcol/config.yml >/dev/null

dump() { docker logs "$net-tempo" 2>&1 | tail -20; docker logs "$net-otel" 2>&1 | tail -15; }
wait_for() { # description, url
  for _ in $(seq 1 60); do curl -fs "$2" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "FAIL $1 did not become ready"; dump; exit 1
}
wait_for "prometheus" http://127.0.0.1:3297/-/ready
wait_for "tempo" http://127.0.0.1:3298/ready
echo "ok   prometheus and tempo ready"

# the collector has no health endpoint here: it accepts OTLP once the port answers
code=
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:4398/v1/traces || true)
  [ "$code" = 200 ] && break
  sleep 1
done
[ "$code" = 200 ] || { echo "FAIL collector OTLP/HTTP answered '$code'"; dump; exit 1; }
echo "ok   collector accepts OTLP/HTTP"

tid=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
cid=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n') # client span; the server span is its child
sid=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
now=$(date +%s)
# a service graph edge needs a client span (kind 3) in one service and its server span (kind 2) in another
span() { # service spanId parentSpanId name kind
  jq -n --arg svc "$1" --arg t "$tid" --arg s "$2" --arg p "$3" --arg n "$4" --argjson k "$5" \
    --arg a "${now}000000000" --arg b "$((now + 1))000000000" \
    '{resource:{attributes:[{key:"service.name",value:{stringValue:$svc}}]},
      scopeSpans:[{spans:[{traceId:$t,spanId:$s,parentSpanId:$p,name:$n,kind:$k,startTimeUnixNano:$a,endTimeUnixNano:$b}]}]}'
}
body=$(jq -n --argjson c "$(span check-web "$cid" "" check 3)" --argjson s "$(span check-api "$sid" "$cid" check-call 2)" '{resourceSpans:[$c,$s]}')
curl -fsS -X POST -H 'Content-Type: application/json' -d "$body" http://127.0.0.1:4398/v1/traces >/dev/null
echo "ok   sent trace $tid (check-web -> check-api)"

# collector batches for 5s, then Tempo's ingester serves the live trace by id
found=
for _ in $(seq 1 45); do
  idx=$(curl -fs "http://127.0.0.1:3298/api/traces/$tid" 2>/dev/null | jq -r '[.. | objects | select(has("name")) | .name] | index("check-call")' 2>/dev/null || true)
  if [ -n "$idx" ] && [ "$idx" != null ]; then found=1; break; fi
  sleep 2
done
[ -n "$found" ] || { echo "FAIL Tempo never returned trace $tid"; dump; exit 1; }
echo "ok   Tempo returned the trace"

# the generator pairs the two spans, then remote-writes the edge to Prometheus
q='traces_service_graph_request_total{client="check-web",server="check-api"}'
for _ in $(seq 1 60); do
  n=$(curl -fsG --data-urlencode "query=$q" http://127.0.0.1:3297/api/v1/query 2>/dev/null | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true)
  if [ -n "$n" ] && [ "$n" != 0 ]; then echo "ok   Prometheus has the service graph edge check-web -> check-api ($n)"; exit 0; fi
  sleep 2
done
echo "FAIL no service graph edge in Prometheus"; dump; exit 1
