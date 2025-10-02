# Памятка по роли `ansible/roles/hub`

Роль поднимает и настраивает **стек мониторинга на хабе**: Prometheus, Grafana, Alertmanager, Blackbox Exporter, а также кладёт дашборды, targets и правила.

---

## 1) Структура задач и теги

Все блоки импортируются статически из `tasks/main.yml` — можно запускать по тегам.

- **setup** — базовая подготовка хоста (директории, пользователи, пакеты).
  ```yaml
  - import_tasks: setup.yml
    tags: [setup]
  ```

- **compose** — рендер `docker-compose.yml` и запуск/обновление стека.
  ```yaml
  - import_tasks: compose.yml
    tags: [compose]
  ```

- **grafana** — провижининг Grafana: datasources, folders, файловый провайдер дашбордов.
  ```yaml
  - import_tasks: grafana.yml
    tags: [grafana]
  ```

- **prometheus** — рендер конфигурации Prometheus, rules и file_sd targets.
  ```yaml
  - import_tasks: prometheus.yml
    tags: [prometheus]
  ```

- **alertmanager** — рендер конфигурации Alertmanager и перезапуск при изменениях.
  ```yaml
  - import_tasks: alertmanager.yml
    tags: [alertmanager]
  ```

- **blackbox** — конфигурация Blackbox Exporter и таргетов.
  ```yaml
  - import_tasks: blackbox.yml
    tags: [blackbox]
  ```

- **health** — `meta: flush_handlers` + проверки `/ready`/`/health` curl‑запросами.
  ```yaml
  - meta: flush_handlers
    tags: [health]
  - import_tasks: health.yml
    tags: [health]
  ```

- **grafana_token** — получение/обновление admin API token (по флагу).
  ```yaml
  - import_tasks: grafana_token.yml
    tags: [grafana_token]
  ```

- **grafana_export** — экспорт дашбордов по UID (файлы именуются **по UID**).
  ```yaml
  - import_tasks: grafana_export.yml
    tags: [grafana_export]
  ```

> Хэндлеры: рестарт/релод Prometheus, Grafana, Alertmanager; у Prometheus также `/-/reload`.

---

## 2) Куда кладутся файлы на хосте

Корень стека: `{{ monitoring_root }}` (по умолчанию `/opt/vff-monitoring`).

- **Prometheus**
  - `prometheus/prometheus.yml` — основной конфиг
  - `prometheus/rules/*.yml` — recording/alerting rules
  - `prometheus/targets/*.json` — file_sd targets (nodes, bb-icmp, bb-tcp443, ru-probe и т.д.)

- **Grafana**
  - `grafana/dashboards/**` — JSON дашбордов для файлового провайдера
  - ⚠️ **Именование файлов = UID**: `VPN/wireguard-health.json`, `Marzban/marzban-online-nodes.json`, `Reality/reality-table.json`

- **Alertmanager**
  - `alertmanager/alertmanager.yml` — конфиг (монтируется каталогом)

- **Docker Compose**
  - `docker-compose.yml` — общий файл стека (контейнеры в `network_mode: host`, конфиги bind‑mount read‑only)

---

## 3) Prometheus (основное)

- Новые джобы правим в `templates/prometheus.yml.j2`, targets — в `templates/targets/*.json.j2`.
- file_sd обновляется автоматически по `refresh_interval` (см. переменные ниже).
- Reload без рестарта:
  ```bash
  curl -fsS -X POST http://127.0.0.1:{{ prometheus_port }}/-/reload
  ```
- Проверки:
  ```bash
  curl -s 'http://127.0.0.1:{{ prometheus_port }}/api/v1/targets?state=any' | jq .data.activeTargets
  ```

---

## 4) Grafana (дашборды: импорт/экспорт)

- Провижининг из `grafana/dashboards/**` (файловый провайдер).
- При экспорте Ansible вытягивает по UID, нормализует через `jq`, сохраняет как `UID.json` в папку по `meta.folderTitle`.
- Типовые проблемы:
  - `same UID is used more than once` / `title is not unique` → удалить дубликаты по title, оставить только `UID.json`.
  - `Not saving new dashboard due to restricted database access` → следствие дублей, также лечится их удалением.
- Горячая подгрузка: достаточно обновить файл + перезапустить Grafana (иногда хватает авто‑сканирования).
  ```bash
  docker compose -f {{ monitoring_root }}/docker-compose.yml restart grafana
  ```

---

## 5) Alertmanager (Telegram)

- Конфиг генерируется шаблоном `templates/alerts.yml.j2` в `{{ monitoring_root }}/alertmanager/alertmanager.yml`.
- Схема по умолчанию — один receiver Telegram или «blackhole», с разумными group_* интервалами.
- Для работы Telegram определите секреты в `group_vars/hub/vault.yml` (см. ниже).

Пример содержания генерируемого файла (по умолчанию):
```yaml
global:
  resolve_timeout: 5m

route:
  receiver: tg
  group_by: [alertname, instance]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 2h

receivers:
- name: tg
  telegram_configs:
  - bot_token: "<token>"
    chat_id: 123456
    api_url: "https://api.telegram.org"
    parse_mode: ""
    send_resolved: true
- name: blackhole
```

> Мы **монтируем каталог** `{{ monitoring_root }}/alertmanager:/etc/alertmanager:ro` (а не единичный файл), чтобы Alertmanager гарантированно видел свежий `alertmanager.yml` после обновления Ansible.

---

## 6) Blackbox Exporter

- Конфиг `blackbox.yml` + `file_sd` таргеты `bb-icmp.json`, `bb-tcp443.json`.
- Relabel: `__param_target` ← `__address__` из file_sd, `instance` = target, `__address__` → адрес самого blackbox (127.0.0.1:{{ blackbox_port }}).

---

## 7) Частые операции

```bash
# Полный стек Grafana (provisioning + dashboards)
make grafana

# Синхронизировать дашборды без рестартов
make grafana-dashboards

# Экспорт дашбордов по UID
make grafana-pull   ANSIBLE_FLAGS='--tags grafana_export -e grafana_export_uids=["wireguard-health","reality-table"]'

# Только правила Prometheus (recording/alerts) + health
make prom-rules

# Reload Prometheus без рестарта
make prom-reload
```

---

## 8) Vault: секреты и их использование

Файл: `ansible/group_vars/hub/vault.yml` — **зашифрованный** через Ansible Vault.

### Минимальный пример содержимого
```yaml
grafana_admin_password: ""

# Basic‑auth для внутренних экспортеров (если включено в шаблонах)
EXPORTER_METRICS_USER: "metrics"
EXPORTER_METRICS_PASS: ""

# Telegram Alertmanager
am_telegram_bot_token: ""
am_telegram_chat_id: 123456789

# Nginx basic‑auth для внешних сайтов (прокси)
nginx_passwords:
  admin: ""

# Marzban exporter (если используется)
MARZBAN_USERNAME: ""
MARZBAN_PASSWORD: ""

# Общие параметры для reality_e2e профилей (если нужны по умолчанию)
reality_e2e_shared:
  uuid: ""
  public_key: ""
  short_id: ""
  sni: ""        # опционально
```

### Команды Ansible Vault
```bash
# Отредактировать (рекомендуемо):
ansible-vault edit ansible/group_vars/hub/vault.yml

# Создать с нуля:
ansible-vault create ansible/group_vars/hub/vault.yml

# Зашифровать уже существующий открытый файл:
ansible-vault encrypt ansible/group_vars/hub/vault.yml

# Расшифровать (временная операция, обычно не требуется):
ansible-vault decrypt ansible/group_vars/hub/vault.yml
```

> При запуске playbooks добавьте `--ask-vault-pass` (или используйте vault‑id). Пример:
> ```bash
> make hub ANSIBLE_FLAGS=--ask-vault-pass
> ```

### Как шаблоны используют секреты
- Grafana admin пароль → `docker-compose.yml.j2` (переменные окружения контейнера).
- Alertmanager Telegram → `alerts.yml.j2`.
- Nginx basic‑auth → генерация `.htpasswd` из `nginx_passwords` (через роль `nginx`).
- Marzban exporter → переменные окружения контейнера (если включён).

---

## 9) Переменные роли

### Основные
| Переменная | Назначение | По умолчанию |
|---|---|---|
| `monitoring_root` | Корень стека мониторинга на хосте | `/opt/vff-monitoring` |
| `prometheus_image` | Образ Prometheus | `prom/prometheus:v2.55.1` |
| `grafana_image` | Образ Grafana | `grafana/grafana:10.4.5` |
| `alertmanager_image` | Образ Alertmanager | `prom/alertmanager:v0.27.0` |
| `blackbox_image` | Образ Blackbox Exporter | `prom/blackbox-exporter:v0.25.0` |
| `prometheus_port` | Порт Prometheus | `9090` |
| `grafana_port` | Порт Grafana | `3000` |
| `alertmanager_port` | Порт Alertmanager | `9093` |
| `blackbox_port` | Порт Blackbox Exporter | `9115` |
| `external_url_prometheus` | `--web.external-url` Prometheus | `""` |
| `external_url_grafana` | Базовый внеш. URL Grafana (для reverse‑proxy) | `""` |
| `external_url_alerts` | `--web.external-url` Alertmanager | `""` |
| `file_sd_refresh_interval` | Интервал ресканирования targets | `5m` |

### Grafana / экспорт
| Переменная | Назначение | По умолчанию |
|---|---|---|
| `grafana_dash_dir` | Каталог дашбордов на хосте | `{{ monitoring_root }}/grafana/dashboards` |
| `grafana_provider_name` | Имя файлового провайдера | `filetree` |
| `grafana_api_url` | URL API Grafana (для экспорта) | `http://127.0.0.1:{{ grafana_port }}` |
| `grafana_admin_token` | API токен админа (если указан — предпочтительнее basic) | `""` |
| `grafana_admin_user` | Логин админа | `admin` |
| `grafana_admin_password` | Пароль админа (**секрет, хранить в vault**) | `admin` |

### Alertmanager / Telegram
| Переменная | Назначение | По умолчанию |
|---|---|---|
| `am_global_resolve_timeout` | `global.resolve_timeout` | `5m` |
| `am_route_group_by` | Список label для группировки | `['alertname','instance']` |
| `am_route_group_wait` | Время ожидания первой нотификации | `30s` |
| `am_route_group_interval` | Интервал между группами | `5m` |
| `am_route_repeat_interval` | Период повтора | `2h` |
| `am_telegram_bot_token` | Bot token (**vault**) | `""` |
| `am_telegram_chat_id` | Chat ID (**vault**) | `null` |
| `am_telegram_api_url` | URL API | `https://api.telegram.org` |
| `am_telegram_parse_mode` | Режим форматирования | `""` |
| `am_telegram_send_resolved` | Отправлять восстановление | `true` |

### Экспортеры/прокси
| Переменная | Назначение | По умолчанию |
|---|---|---|
| `MARZBAN_USERNAME` | Логин к панели Marzban (**vault**) | `""` |
| `MARZBAN_PASSWORD` | Пароль к панели Marzban (**vault**) | `""` |
| `EXPORTER_METRICS_USER` | Basic‑auth user для экспортёров (**vault**) | `metrics` |
| `EXPORTER_METRICS_PASS` | Basic‑auth pass (**vault**) | `""` |
| `nginx_passwords` | Словарь пользователей для `.htpasswd` (**vault**) | `{admin: ""}` |

---

## 10) Практические советы

- Если Grafana ведёт себя странно (401 после логина) — **очистите куки/кеш сайта** проблемного браузера. Через curl всё ок — значит виноваты куки.
- При проблемах с провижинингом дашбордов — проверьте **дублирующие UID/тайтлы** в каталоге dashboards.
- Конфиги монтируются read‑only; при обновлении файлов **перезапустите соответствующий контейнер** (Grafana/Alertmanager) или отправьте `/-/reload` в Prometheus.
- Держите все секреты только в `vault.yml`; не коммитьте открытые значения в репозиторий.
