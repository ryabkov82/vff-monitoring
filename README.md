# vff-monitoring

## Runbooks

- Добавление нового VPN-узла: [docs/NEW_NODE.md](docs/NEW_NODE.md)
- **Роль Node** (iperf3, if_speed, REALITY, WireGuard-метрики): [docs/node_role.md](docs/node_role.md)
- Роль Grafana (provisioning, экспорт/импорт дашбордов, токены): [docs/grafana-role.md](docs/grafana-role.md)
- Роли WireGuard (hub/node): [docs/wireguard-roles.md](docs/wireguard-roles.md)
- Роль node_exporter: [docs/node-exporter-role.md](docs/node-exporter-role.md)
- Роль Nginx (reverse-proxy, certs, htpasswd): [docs/nginx-role.md](docs/nginx-role.md)
- Роль Docker (установка Docker Engine + Compose v2): [docs/docker-role.md](docs/docker-role.md)
- Роль RU Probe (iperf3 throughput): [docs/ru-probe-role.md](docs/ru-probe-role.md)
- Роль Speedtest (Ookla) (textfile метрики для node_exporter): [docs/speedtest_ookla.md](docs/speedtest_ookla.md)

## Grafana — основные команды

### Токен сервисного аккаунта (разово/ротация)
```bash
make grafana-token   ANSIBLE_FLAGS='-e grafana_token_refresh=true'
```

### Экспорт дашбордов из Grafana → репозиторий
Все:
```bash
make grafana-pull
```

Только выбранные UID:
```bash
make grafana-pull   ANSIBLE_FLAGS='-e grafana_export_uids=["availability","node-exporter-full"]'
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

## node_exporter — основные команды

```bash
# Один узел
make node-exporter HOST=<hostname>

# Все vpn-узлы
make node-exporter-vpn
```

## Nginx — основные команды

```bash
# Полный прогон роли Nginx на хабе
make nginx

# Проверка/перезагрузка вручную
ansible -i ansible/hosts.ini hub -m shell -a 'nginx -t && systemctl reload nginx'
```

## Docker — основные команды

```bash
# Установка/обновление Docker (Engine + Compose v2) на хабе
make docker

# Полный прогон стека на хабе (включая Docker)
make hub-full
```
