# Роль `node` — памятка

Роль ставит и настраивает вспомогательные агенты/скрипты на **VPN‑узлах** для мониторинга и диагностики. Поддерживаемые компоненты:
- **iperf3 server** — TCP/UDP тестовый сервер, привязанный к WG‑IP узла.
- **if_speed** — публикация метрики `if_speed_bps` (скорость uplink‑интерфейса) через textfile.
- **REALITY (XRAY/Marzban) health exporter** — скрипт, проверяющий контейнер XRAY/Marzban и порт 443, отдаёт textfile‑метрики.
- **WireGuard textfile exporter** — скрипт, публикующий метрики по пир‑соединениям WireGuard.

> Роль вызывается на группе `vpn` в `ansible/site.yml` и может запускаться точечно по тегам через Makefile.

---

## Что ставит и где пишет

### 1) iperf3 server
- Юнит: `iperf3@<port>.service` (по умолчанию порт **5201**).
- Байндинг: на WG‑IP узла (`wg_ip`) — берётся из `group_vars/all.yml:vpn_nodes[*].wg_ip`, либо можно задать в host_vars.
- UFW: открывает порт для хаба/подсети WG.
- Теги: `node`, `node_iperf`, `iperf3`.

### 2) if_speed (textfile)
- Файл метрик: `/var/lib/node_exporter/textfile/if_speed.prom`.
- Берёт значения:
  - `uplink_device` (интерфейс, по умолчанию `ens3`),
  - `uplink_speed_bps` (числом в бит/с; пример 10 Gbit/с: `10000000000`).
- Теги: `node_if_speed`.

### 3) REALITY (XRAY/Marzban) health exporter
- Скрипт: `/usr/local/bin/reality_svc_health.sh`.
- Юниты: `reality-svc.service` (oneshot), `reality-svc.timer` (по умолчанию каждые 60с).
- Конфиг (опционально): `/etc/default/reality_svc`.
- Метрики (textfile): `/var/lib/node_exporter/textfile/reality_svc.prom`.
- Теги: `node_reality`, `reality`.

Ожидаемые переменные (пример в `host_vars/<host>.yml` или `group_vars/vpn.yml`):
```yaml
node_reality_enabled: true
node_reality_container_name: "^marzban-.*$"  # имя или регэксп контейнера
node_reality_port: 443
node_reality_node_name: "nl-ams-2"           # должен совпадать с labels.name в job=node
node_reality_textfile_dir: "/var/lib/node_exporter/textfile"
```
> Если контейнера на узле нет — можно не включать `node_reality_enabled` или не ставить конфиг: метрика покажет `docker:not_found`.

### 4) WireGuard textfile exporter
- Скрипт: `/usr/local/bin/wg_textfile.sh`.
- Юниты: `wg-metrics.service` (oneshot), `wg-metrics.timer` (каждые 15с).
- Метрики (textfile): `/var/lib/node_exporter/textfile/wg.prom`.
- Теги: `node_wg_metrics`.

---

## Переменные (сводно)

Часть берётся из `vpn_nodes` в `ansible/group_vars/all.yml`:
```yaml
vpn_nodes:
  - name: "nl-ams-1"
    wg_ip: "10.77.0.2"
    instance: "10.77.0.2:9100"
    role: "vpn"
    uplink_device: "ens3"            # опционально
    uplink_speed_bps: 10000000000    # опционально
```

Переменные роли/подролей (опционально, если отличия от дефолтов):
```yaml
# if_speed
uplink_device: "ens3"
uplink_speed_bps: 10000000000

# reality exporter
node_reality_enabled: true
node_reality_container_name: "marzban-marzban-1"   # или регэксп
node_reality_port: 443
node_reality_node_name: "{{ inventory_hostname }}"
node_reality_textfile_dir: "/var/lib/node_exporter/textfile"
```

---

## Теги роли

| Подзадача                            | Теги                                 |
|-------------------------------------|---------------------------------------|
| iperf3 server                       | `node`, `node_iperf`, `iperf3`        |
| if_speed (textfile)                 | `node_if_speed`                       |
| REALITY health exporter (script)    | `node_reality`, `reality`             |
| WireGuard textfile exporter         | `node_wg_metrics`                     |

> Для полной установки всего набора на узле используй `node` + смежные теги (`node_exporter`, `speedtest_ookla`) через цель Makefile `node-bootstrap`.

---

## Быстрые команды (Makefile)

### Полный бутстрап узла
```bash
make node-bootstrap HOST=<host>   # iperf3 + if_speed + node_exporter + speedtest_ookla
```

### Только iperф3
```bash
make iperf-node HOST=<host>
make iperf-status HOST=<host> [PORT=5201]
make iperф-logs HOST=<host>   [PORT=5201] [TAIL=200]
make iperф-vpn                 # на всех vpn
```

### if_speed
```bash
make node-if-speed HOST=<host>
make node-if-speed-vpn
```

### REALITY exporter
```bash
make reality-install HOST=<host>      # раскатка скрипта/юнитов
make reality-run HOST=<host>          # разовый запуск
make reality-status HOST=<host>
make reality-logs HOST=<host> [TAIL=200]
make reality-metrics HOST=<host>
```

### WireGuard metrics exporter
```bash
make wg-metrics-install HOST=<host>
make wg-metrics-install-vpn
make wg-metrics-run HOST=<host>
make wg-metrics-status HOST=<host>
make wg-metrics-logs HOST=<host> [TAIL=200]
make wg-metrics-metrics HOST=<host>
```

---

## Примеры сценариев

**1) Поднять iperf3 и опубликовать скорость интерфейса:**
```bash
make iperf-node HOST=nl-ams-2
make node-if-speed HOST=nl-ams-2
```

**2) Включить REALITY мониторинг на узле с Marzban:**
```yaml
# host_vars/nl-ams-2.yml
node_reality_enabled: true
node_reality_container_name: "^marzban-.*$"
node_reality_node_name: "nl-ams-2"
```
```bash
make reality-install HOST=nl-ams-2
make reality-run     HOST=nl-ams-2
make reality-metrics HOST=nl-ams-2
```

**3) WireGuard метрики:**
```bash
make wg-metrics-install HOST=nl-ams-2
make wg-metrics-run     HOST=nl-ams-2
make wg-metrics-metrics HOST=nl-ams-2
```

---

## Troubleshooting (кратко)

- **iperf3 не стартует**: проверь `wg_ip` у узла, UFW правила, порт (по умолчанию 5201), логи `make iperf-logs HOST=<h>`.
- **if_speed.prom пустой**: проверь переменные `uplink_device`/`uplink_speed_bps`, права на каталог textfile.
- **reality_svc_up=0**: проверь имя контейнера/регэксп (`node_reality_container_name`) и порт; `docker ps` должен видеть контейнер.
- **wg.prom пустой**: убедись, что `wg` установлен и `wg show all dump` работает под root (юнит запускается от root).

---

## Где править
- Роль: `ansible/roles/node`
- Шаблоны скриптов и юнитов: `ansible/roles/node/templates/`
- Таски по компонентам: `ansible/roles/node/tasks/*.yml`
- Хэндлеры: `ansible/roles/node/handlers/main.yml`
- Варсы узлов: `ansible/group_vars/all.yml` (`vpn_nodes`) и `host_vars/<host>.yml`
