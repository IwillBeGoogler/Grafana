#!/usr/bin/env bash
# Monitoring stack rollout with plain docker run (no compose). Runs on the self-hosted runner on the server
# (label iwillbegoogler-prod, deploy user), next to the app containers on the docker network `iwillbegoogler`.
#
#   env: SRC                  checkout of this repo (config files are copied to DEPLOY_DIR and bind-mounted from there)
#        TELEGRAM_BOT_TOKEN   bot token for Alertmanager and Grafana alerts (GitHub environment secret)
#        DEPLOY_DIR           default /opt/monitoring
#   The passwords come from /run/iwillbegoogler/env (rendered from Vault by iwillbegoogler-secrets). Postgres and Redis: the read-only
#   monitoring user `grafana` (pg_monitor + read-only transactions / an ACL with INFO, PING, SLOWLOG, LATENCY, MEMORY only),
#   not the app credentials.
#
# Every service is replaced one by one: the old container is kept stopped until the new one runs, otherwise it is
# restored. Data lives in docker volumes (iwillbegoogler-monitoring-*), so a rollout never touches metrics, traces or logs.
# All ports are bound to 127.0.0.1 only. Grafana is public at https://grafana.iwillbegoogler.uz (host nginx + Let's Encrypt, login
# required); the other UIs need an ssh tunnel: Grafana 3200, Prometheus 9091, Alertmanager 9093; Tempo has no public UI (traces are
# read in Grafana > Explore > Tempo; its API is on 127.0.0.1:3201).
set -euo pipefail
: "${SRC:?}" "${TELEGRAM_BOT_TOKEN:?}"
DEPLOY_DIR=${DEPLOY_DIR:-/opt/monitoring}
NETWORK=${DOCKER_NETWORK:-iwillbegoogler}
PG_HOST=${PG_HOST:-172.30.0.1}      # postgres and redis run on the host, reachable on the gateway of the docker network
REDIS_HOST=${REDIS_HOST:-172.30.0.1}
umask 022

# --- config files and secrets ---------------------------------------------------
set -a
# shellcheck disable=SC1091
. /run/iwillbegoogler/env
set +a
: "${GRAFANA_PG_PASSWORD:?}" "${GRAFANA_REDIS_PASSWORD:?}" "${EMQX_API_SECRET:?}"

install -d "$DEPLOY_DIR" "$DEPLOY_DIR/secrets"
for d in prometheus alertmanager otel tempo loki grafana; do
	rsync -a --delete "$SRC/$d/" "$DEPLOY_DIR/$d/"
done
rm -f "$DEPLOY_DIR/alertmanager/alertmanager.yml.example"
# the containers run as non-root users, so these two files must be readable; the dir is not listable by others
install -d -m 0711 "$DEPLOY_DIR/secrets"
# write to a temp file and move it over: a plain redirect into the read-only file of the previous rollout would fail
write_secret() { printf '%s' "$2" >"$1.new" && chmod 0444 "$1.new" && mv -f "$1.new" "$1"; }
write_secret "$DEPLOY_DIR/secrets/emqx_secret" "$EMQX_API_SECRET"
write_secret "$DEPLOY_DIR/secrets/telegram_token" "$TELEGRAM_BOT_TOKEN"

# --- replace one container ------------------------------------------------------
logopts=(--log-driver json-file --log-opt max-size=5m --log-opt max-file=2)
failed=()

# run NAME IMAGE MEMORY CPUS [docker run args...] [-- command args...]
run() {
	local svc=$1 name=iwillbegoogler-$1 image=$2 mem=$3 cpus=$4
	shift 4
	if docker inspect "$name" >/dev/null 2>&1; then
		docker rm -f "$name-old" >/dev/null 2>&1 || true
		docker rename "$name" "$name-old"
		docker stop -t 20 "$name-old" >/dev/null
	fi
	if docker run -d --name "$name" --network "$NETWORK" --network-alias "$svc" --restart unless-stopped \
		--memory "$mem" --cpus "$cpus" "${logopts[@]}" "$@" >/dev/null 2>&1 \
		&& sleep 6 && [ "$(docker inspect -f '{{.State.Status}}' "$name")" = running ]; then
		docker rm -f "$name-old" >/dev/null 2>&1 || true
		echo "ok   $svc ($image)"
	else
		echo "FAIL $svc" >&2
		docker logs --tail 15 "$name" >&2 || true
		docker rm -f "$name" >/dev/null 2>&1 || true
		if docker inspect "$name-old" >/dev/null 2>&1; then docker rename "$name-old" "$name" && docker start "$name" >/dev/null; fi
		failed+=("$svc")
	fi
}
vol() { echo "iwillbegoogler-monitoring-$1"; }

PROM=prom/prometheus:v3.5.0
AM=prom/alertmanager:v0.28.1
OTEL=otel/opentelemetry-collector-contrib:0.131.0
LOKI=grafana/loki:3.5.3
TEMPO=grafana/tempo:2.8.2
GRAFANA=grafana/grafana:12.1.0
NODE=prom/node-exporter:v1.9.1
PGX=prometheuscommunity/postgres-exporter:v0.17.1
REDISX=oliver006/redis_exporter:v1.74.0-alpine

for i in $PROM $AM $OTEL $LOKI $TEMPO $GRAFANA $NODE $PGX $REDISX; do docker pull -q "$i" >/dev/null; done

# datastores first, then the collector that feeds them, then Prometheus/Alertmanager, exporters, Grafana
run loki "$LOKI" 112m 0.3 -e GOMEMLIMIT=90MiB \
	-v "$DEPLOY_DIR/loki/loki.yml:/etc/loki/loki.yml:ro" -v "$(vol loki):/loki" \
	"$LOKI" -config.file=/etc/loki/loki.yml

# Tempo keeps traces on disk (volume iwillbegoogler-monitoring-tempo, 48h). The image runs as uid 10001: the volume takes
# its ownership from the image's /var/tempo on first use.
run tempo "$TEMPO" 256m 0.5 -e GOMEMLIMIT=200MiB -p 127.0.0.1:3201:3200 \
	-v "$DEPLOY_DIR/tempo/tempo.yml:/etc/tempo/tempo.yml:ro" -v "$(vol tempo):/var/tempo" \
	"$TEMPO" -config.file=/etc/tempo/tempo.yml

run otel-collector "$OTEL" 64m 0.3 -e GOMEMLIMIT=56MiB \
	-v "$DEPLOY_DIR/otel/config.yml:/etc/otelcol/config.yml:ro" \
	"$OTEL" --config=/etc/otelcol/config.yml

run prometheus "$PROM" 112m 0.5 -e GOMAXPROCS=1 -e GOMEMLIMIT=90MiB -p 127.0.0.1:9091:9090 \
	-v "$DEPLOY_DIR/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
	-v "$DEPLOY_DIR/prometheus/alerts.yml:/etc/prometheus/alerts.yml:ro" \
	-v "$DEPLOY_DIR/secrets/emqx_secret:/etc/prometheus/emqx_secret:ro" -v "$(vol prometheus):/prometheus" \
	"$PROM" --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.retention.time=2d \
	--storage.tsdb.retention.size=300MB --web.enable-lifecycle --web.enable-remote-write-receiver

run alertmanager "$AM" 32m 0.1 -p 127.0.0.1:9093:9093 \
	-v "$DEPLOY_DIR/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
	-v "$DEPLOY_DIR/secrets/telegram_token:/etc/alertmanager/telegram_token:ro" -v "$(vol alertmanager):/alertmanager" \
	"$AM" --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager --data.retention=72h \
	--cluster.listen-address=

run node-exporter "$NODE" 24m 0.1 --pid host -v /:/host:ro \
	"$NODE" --path.rootfs=/host --collector.disable-defaults --collector.cpu --collector.meminfo \
	--collector.filesystem --collector.loadavg --collector.netdev --collector.diskstats --collector.uname

run postgres-exporter "$PGX" 24m 0.1 \
	-e "DATA_SOURCE_NAME=postgres://grafana:${GRAFANA_PG_PASSWORD}@${PG_HOST}:5432/blog?sslmode=disable" \
	"$PGX" --no-collector.wal --no-collector.stat_bgwriter

run redis-exporter "$REDISX" 16m 0.1 -e "REDIS_ADDR=redis://${REDIS_HOST}:6379" -e REDIS_USER=grafana -e "REDIS_PASSWORD=${GRAFANA_REDIS_PASSWORD}" \
	"$REDISX"

run grafana "$GRAFANA" 160m 0.5 -p 127.0.0.1:3200:3000 \
	-e "GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:?}" -e GF_USERS_ALLOW_SIGN_UP=false \
	-e GF_SERVER_DOMAIN=grafana.iwillbegoogler.uz -e GF_SERVER_ROOT_URL=https://grafana.iwillbegoogler.uz \
	-e GF_SECURITY_COOKIE_SECURE=true -e GF_SECURITY_COOKIE_SAMESITE=lax -e GF_AUTH_ANONYMOUS_ENABLED=false \
	-e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
	-e GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false -e GF_PLUGINS_PREINSTALL_DISABLED=true \
	-e GF_NEWS_NEWS_FEED_ENABLED=false -e GF_UNIFIED_ALERTING_ENABLED=true -e GF_LOG_LEVEL=warn \
	-e GOMAXPROCS=1 -e GOMEMLIMIT=128MiB -e "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" \
	-v "$DEPLOY_DIR/grafana/provisioning:/etc/grafana/provisioning:ro" \
	-v "$DEPLOY_DIR/grafana/dashboards:/var/lib/grafana/dashboards:ro" -v "$(vol grafana):/var/lib/grafana" \
	"$GRAFANA"

if [ "${#failed[@]}" -gt 0 ]; then
	echo "monitoring rollout failed: ${failed[*]}" >&2
	exit 1
fi
echo "monitoring deploy ok"
