# vff-monitoring

## Runbooks

- Добавление нового VPN-узла: [docs/NEW_NODE.md](docs/NEW_NODE.md)
- Роль Grafana (provisioning, экспорт/импорт дашбордов, токены): [docs/grafana-role.md](docs/grafana-role.md)

## Grafana — основные команды

### Токен сервисного аккаунта (разово/ротация)
```bash
make grafana-token \
  ANSIBLE_FLAGS='-e grafana_token_refresh=true'
```

### Экспорт дашбордов из Grafana → репозиторий
Все:
```bash
make grafana-pull
```

Только выбранные UID:
```bash
make grafana-pull \
  ANSIBLE_FLAGS='-e grafana_export_uids=["availability","node-exporter-full"]'
```

### Загрузка дашбордов на хаб (hot-reload)
```bash
make grafana-dashboards
```

### Логи Grafana
```bash
make logs-grafana         # хвост логов
make flogs-grafana        # live-логи (follow)
```
