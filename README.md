# vff-monitoring

Мониторинг VPN‑инфраструктуры: Prometheus + Grafana + Alertmanager + Blackbox, метрики узлов (node_exporter + textfile), RU‑probe (iperf3), Speedtest (Ookla), WireGuard, REALITY (xray/sing‑box) и E2E‑проверки.

---

## Содержание

- [Архитектура](#архитектура)
- [Интеграции и внешние проекты](#интеграции-и-внешние-проекты)
- [Runbooks / Документация по ролям](#runbooks--документация-по-ролям)
- [Быстрый старт (Make)](#быстрый-старт-make)
- [Полезные команды (Make)](#полезные-команды-make)
- [Требования](#требования)
- [Структура репозитория](#структура-репозитория)
- [Поддержка и вклад](#поддержка-и-вклад)

---

## Архитектура

<details>
<summary><strong>Mermaid-схема</strong></summary>

```mermaid
flowchart LR
  %% =========================
  %% CONTROL PLANE (ANSIBLE)
  %% =========================
  subgraph CONTROL[Ansible управление]
    A1[Роль hub<br/>ansible/roles/hub]
    A2[Роль node<br/>ansible/roles/node]
    A3[Прочие роли<br/>wireguard_*, node_exporter,<br/>speedtest_ookla, ru_probe,<br/>sing_box, reality_e2e, nginx, docker, grafana]
  end

  %% =========================
  %% HUB
  %% =========================
  subgraph HUB[Monitoring Hub]
    direction TB
    H1[(Prometheus)]
    H2[(Grafana)]
    H3[(Alertmanager)]
    H4[(Blackbox Exporter)]
    H5[(Nginx reverse-proxy)]
    H6[(Docker Engine + Compose)]
    H7[(RU iperf3 probe<br/>textfile)]
    H8[(REALITY E2E probes<br/>textfile)]
    H9[(Prometheus rules<br/>recording и alerts)]
    H10[(Marzban exporter)]
    H11[[Scrape job<br/>backup — file_sd nodes-backup.json<br/>keep backup_*]]
    H12[[Scrape job<br/>node — file_sd nodes.json<br/>drop backup_*]]
  end

  %% =========================
  %% NODES (VPN)
  %% =========================
  subgraph NODES[VPN узлы группа vpn]
    direction TB
    N1[node_exporter :9100<br/>включая textfile]
    N2[if_speed_bps<br/>textfile]
    N3[WireGuard metrics<br/>textfile]
    N4[REALITY svc health<br/>textfile]
    N5[Speedtest Ookla<br/>textfile]
  end

  %% =========================
  %% BACKUP CLIENTS
  %% =========================
  subgraph BACKUPS[Backup клиенты группа backup_clients]
    direction TB
    B2[(Backup system<br/>restic/скрипт → .prom<br/>backup метрики)]
    B1[node_exporter :9100<br/>textfile с backup метриками]
  end

  %% =========================
  %% EXTERNAL
  %% =========================
  subgraph EXT[Внешние системы]
    S1[(Speedtest servers Ookla)]
    M1[(Marzban panel)]
    T1[(Notifiers<br/>Telegram bot)]
  end

  %% =========================
  %% WIREGUARD OVERLAY
  %% =========================
  WGNET((WireGuard overlay))

  %% -------- Ansible раскатка --------
  A1 -->|deploy cfg provisioning| HUB
  A2 -->|install agents| NODES
  A2 -->|install agents| BACKUPS
  A3 --> HUB
  A3 --> NODES
  A3 --> BACKUPS

  %% -------- Скрейпы Prometheus --------
  N1 -->|/metrics| H1
  N2 -->|textfile| N1
  N3 -->|textfile| N1
  N4 -->|textfile| N1
  N5 -->|textfile| N1

  B2 -->|writes .prom| B1
  B1 -->|/metrics backup| H1

  H7 -->|textfile| H1
  H8 -->|textfile| H1
  H10 -->|/metrics| H1

  %% Привязка scrape jobs (логическая)
  H12 -. собирает с .-> NODES
  H11 -. собирает с .-> BACKUPS

  %% Blackbox проверяет ИМЕННО VPN-узлы
  H4 -->|/probe icmp tcp| NODES
  H1 <-->|scrape blackbox| H4

  %% Связность и правила
  H1 --> H9
  H1 -->|alerts| H3
  H3 -->|notify| T1
  H2 -->|dashboards provisioned| H1
  H5 --- H1
  H5 --- H2
  H5 --- H3

  %% Speedtest использует внешние сервера
  N5 -. использует .-> S1

  %% WireGuard оверлей между хабом и нодами и бэкап-клиентами
  HUB -. WG .- WGNET -. WG .- NODES
  HUB -. WG .- WGNET -. WG .- BACKUPS

  %% RU iperf3 проба — через WG к узлам
  H7 -->|iperf3 via WG| NODES

  %% REALITY E2E — к узлам через SOCKS (sing box), не через WG
  H8 -->|via SOCKS sing_box| NODES

  %% Marzban exporter на хабе тянет метрики с внешней панели
  H10 <-->|pull| M1

```
</details>

---

## Интеграции и внешние проекты

- **Marzban Exporter (Prometheus):** https://github.com/kutovoys/marzban-exporter
- **Marzban (панель управления):** https://github.com/Gozargah/Marzban

---

## Runbooks / Документация по ролям

- Роль **Hub** (Prometheus/Grafana/Alertmanager/Blackbox): [docs/hub-role.md](docs/hub-role.md)
- Роль **Node** (iperf3, if_speed, REALITY, WireGuard‑метрики): [docs/node_role.md](docs/node_role.md)
- Роль Grafana (provisioning, экспорт/импорт дашбордов, токены): [docs/grafana-role.md](docs/grafana-role.md)
- Роли WireGuard (hub/node): [docs/wireguard-roles.md](docs/wireguard-roles.md)
- Роль node_exporter: [docs/node-exporter-role.md](docs/node-exporter-role.md)
- Роль Nginx (reverse‑proxy, certs, htpasswd): [docs/nginx-role.md](docs/nginx-role.md)
- Роль Docker (установка Docker Engine + Compose v2): [docs/docker-role.md](docs/docker-role.md)
- Роль RU Probe (iperf3 throughput): [docs/ru-probe-role.md](docs/ru-probe-role.md)
- Роль Speedtest (Ookla) (textfile‑метрики для node_exporter): [docs/speedtest_ookla.md](docs/speedtest_ookla.md)
- Роль sing_box (установка бинаря sing‑box): [docs/sing_box-role.md](docs/sing_box-role.md)
- Роль Reality E2E (sing‑box энд‑ту‑энд проверка): [docs/reality_e2e-role.md](docs/reality_e2e-role.md)
- **Развёртывание RU‑зонда (ru_zondes):** [docs/NEW_RU_ZONDE.md](docs/NEW_RU_ZONDE.md)
- **Подключение нового VPN‑узла:** [docs/NEW_NODE.md](docs/NEW_NODE.md)
- **Интеграция бэкапов (backup-клиенты + метрики):** [docs/BACKUPS_MONITORING.md](docs/BACKUPS_MONITORING.md)

---

## Быстрый старт (Make)

Минимальный путь для «чистого» хаба:

```bash
# Установить Docker/Compose на хабе
make docker

# Применить роль Hub (Prometheus, Grafana, Alertmanager, Blackbox)
make hub

# Залить provisioning и дашборды Grafana
make grafana
```

Онбординг нового VPN‑узла (WG + агенты + обновления на хабе): [docs/NEW_NODE.md](docs/NEW_NODE.md)

```bash
# Полный сценарий
make add-node HOST=nl-ams-2

# Проверка после онбординга
make add-node-check HOST=nl-ams-2
```

Онбординг **RU‑зонда** (на отдельном хосте или на самом хабе): [docs/NEW_RU_ZONDE.md](docs/NEW_RU_ZONDE.md)

```bash
# Все роли на одном зонде + пересборка WG на хабе + обновление Prometheus
make ru-zondes-setup-host HOST=ru-msk-1

# Все зонды группы + пересборка WG на хабе + обновление Prometheus
make ru-zondes-setup
```

---

## Полезные команды (Make)

```bash
# Общие
make help                         # Справка и примеры
make hub-full                     # Все роли для хаба (site.yml --limit hub)
make status                       # Состояние docker compose стека на хабе
make logs-grafana                 # Хвост логов Grafana (TAIL=200 по умолчанию)
make prom-reload                  # Горячая перезагрузка Prometheus

# Grafana
make grafana-dashboards           # Горячая синхронизация дашбордов
make grafana-pull                 # Экспорт дашбордов из Grafana → репо
make grafana-token                # Выпуск/ротация токена серв. пользователя

# Узлы
make node-bootstrap HOST=<h>      # node + node_exporter + speedtest_ookla
make node-if-speed HOST=<h>       # публиковать/обновить if_speed_bps
make node-speedtest HOST=<h>      # раскатка speedtest (бинарь, юниты, таймер)

# WireGuard
make wg                           # все задачи WG (hub + nodes)
make wg-status                    # 'wg show' на хабе и узлах
make wg-metrics-install HOST=<h>  # раскатка textfile-метрик WG

# REALITY / E2E
make reality-install HOST=<h>     # health‑скрипт (svc) на узле
make reality-e2e                  # роли и таймеры E2E на хабе
make reality-e2e-run PROFILE=p    # разовый запуск сервиса профиля

# RU‑зонды
make ru-zondes-setup-host HOST=<h># все роли на одном зонде → wg-hub → prom-rules
make ru-zondes-setup              # все роли на всех зондах → wg-hub → prom-rules
```

> Любой таргет можно запускать с переменной `ANSIBLE_FLAGS`, например:
> `make grafana-dashboards ANSIBLE_FLAGS='-e grafana_dashboards_use_rsync=true'`

---

## Требования

- Ansible 2.15+
- Docker Engine + Docker Compose v2 на хабе (роль `docker`)
- Доступ по SSH к хабу и узлам, корректные `ansible/hosts.ini`
- Для экспорта/импорта Grafana — сервисный токен или admin‑логин/пароль
- Для E2E: установленный `sing-box` (роль `sing_box`).

---

## Структура репозитория

```
ansible/
  roles/
    hub/                 # стек мониторинга на хабе
    node/                # агенты и скрипты на узлах
    wireguard_*          # WG (hub/node)
    ...
docs/
  *.md                   # runbooks по ролям
grafana/
  dashboards/...         # JSON-дешборды по UID
  provisioning/...       # datasources, dashboards.yml
```

---

## Поддержка и вклад

PR приветствуются: дополнения к ролям, новые дашборды и правила, улучшения документации. Старайтесь сопровождать изменения коротким описанием и примерами проверки.

---

© [VPN for Friends](https://t.me/vpn_for_myfriends_bot) · Monitoring Stack
