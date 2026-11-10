# IWillBeGoogler monitoring

Prometheus + Grafana + Alertmanager + node/postgres/redis exporters. Joins the app network (`iwillbegoogler_default`), ~300M RAM total.

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
