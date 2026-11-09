# IWillBeGoogler monitoring

Prometheus + Grafana + postgres/redis exporters. Joins app network, ~250M RAM total.

```bash
cp .env.example .env
printf '<emqx api secret>' > emqx_secret
docker compose up -d
```

- Grafana: http://localhost:3200
- Prometheus: http://localhost:9091
