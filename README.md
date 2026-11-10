# IWillBeGoogler monitoring

Prometheus + Grafana + Alertmanager + node/postgres/redis exporters + OpenTelemetry Collector, Tempo + Jaeger (traces), Loki (logs). Joins the app network (`iwillbegoogler_default`), ~660M RAM total.

```bash
cp .env.example .env                       # set GRAFANA_ADMIN_PASSWORD, POSTGRES_PASSWORD, REDIS_PASSWORD
printf '<emqx api secret>' > emqx_secret
touch telegram_token
docker compose up -d
```

| Service      | URL                    |
|--------------|------------------------|
| Grafana      | http://localhost:3200  |
| Prometheus   | http://localhost:9091  |
| Alertmanager | http://localhost:9093  |
| Jaeger       | http://localhost:16686 |
| Jaeger UI    | http://localhost:16686 |

## OpenTelemetry

Backend already exports traces, metrics and logs over OTLP/HTTP. Point it at the collector (same docker network):

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
```

Collector routes: traces to Tempo and Jaeger (Jaeger keeps the last 20k traces in memory), logs to Loki, metrics to `otel-collector:8889` (scraped by Prometheus, job `otel`). In Grafana: Explore > Tempo / Jaeger / Loki; trace and log views link by trace id.

## Telegram alerts

```bash
cp alertmanager/alertmanager.yml.example alertmanager/alertmanager.yml   # set chat_id
printf '<bot token>' > telegram_token
docker compose restart alertmanager
```

## Alerts

- `iwillbegoogler-diagrams`: Yjs writes/compaction, diagram API 5xx, webhook failures.
- `infra`: target down, host memory/disk/CPU.

Config files are bind-mounted: after editing, run `docker compose restart <service>`.
