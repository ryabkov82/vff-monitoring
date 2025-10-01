# Памятка по роли `ansible/roles/hub`

Эта роль поднимает и настраивает стек мониторинга на **хабе**: Prometheus, Grafana, Alertmanager и Blackbox Exporter, а также кладёт дашборды и правила.

---

## 1) Структура задач и теги

Последовательность в `tasks/main.yml` (все блоки импортируются статически, теги наследуются):

- **setup** — базовая подготовка хоста (директории, пользователи, пакеты).
  ```yaml
  - import_tasks: setup.yml
    tags: [setup]
  ```

- **compose** — рендер `docker-compose.yml` и запуск стека (host networking, bind-mount конфигов).
  ```yaml
  - import_tasks: compose.yml
    tags: [compose]
  ```

- **grafana** — установка и провижининг Grafana: источники данных, папки, маппинг папок к файловому провайдеру.
  ```yaml
  - import_tasks: grafana.yml
    tags: [grafana]
  ```

- **prometheus** — рендер конфигурации Prometheus, rules и file_sd targets.
  ```yaml
  - import_tasks: prometheus.yml
    tags: [prometheus]
  ```

- **alertmanager** — конфиг и запуск Alertmanager.
  ```yaml
  - import_tasks: alertmanager.yml
    tags: [alertmanager]
  ```

- **blackbox** — конфиг Blackbox Exporter и таргеты.
  ```yaml
  - import_tasks: blackbox.yml
    tags: [blackbox]
  ```

- **health** — предварительная отправка хэндлеров (перечтение конфигов), затем проверки /ready и базовые curl-запросы.
  ```yaml
  - meta: flush_handlers
    tags: [health]
  - import_tasks: health.yml
    tags: [health]
  ```

- **grafana_token** — получение/обновление admin API token (по возможности).
  ```yaml
  - import_tasks: grafana_token.yml
    tags: [grafana_token]
  ```

- **grafana_export** — экспорт дашбордов из Grafana по UID (именуем файлы **по UID**, а не по title).
  ```yaml
  - import_tasks: grafana_export.yml
    tags: [grafana_export]
  ```

> ⚙️ Хэндлеры: перезапуски/релоды Prometheus, Grafana, Alertmanager, а также `/-/reload` у Prometheus.

---

## 2) Куда кладутся файлы на хосте (по умолчанию)

Корень стека: `{{ monitoring_root }}` (обычно `/opt/vff-monitoring`). Внутри:
- **Prometheus**
  - `prometheus/prometheus.yml` — основной конфиг
  - `prometheus/rules/*.yml` — rules/alerts
  - `prometheus/targets/*.json` — file_sd таргеты (nodes, bb-icmp, bb-tcp443, **ru-probe** и т.д.)
- **Grafana**
  - `grafana/dashboards/**` — дашборды (файловый провайдер)
  - именование файлов: **строго по UID** (пример: `grafana/dashboards/Reality/reality-table.json`)
- **docker-compose.yml** — в корне `{{ monitoring_root }}`

Prometheus работает в container mode с `network_mode: host`, конфиги подмонтированы read-only.

---

## 3) Prometheus: ключевые моменты

- **Новые джобы** добавляем в шаблон: `ansible/roles/hub/templates/prometheus.yml.j2`, затем Ansible рендерит на хост.
- **file_sd targets** генерируются из шаблонов в `templates/targets/*.json.j2` и кладутся в
  `{{ monitoring_root }}/prometheus/targets/*.json`.
- Примеры джоб:
  - `job_name: "prometheus"` — self-scrape `127.0.0.1:{{ prometheus_port }}`
  - `job_name: "node"` — `file_sd` → `/etc/prometheus/targets/nodes.json`
  - `job_name: "blackbox_icmp"`, `job_name: "blackbox_tcp443"` — `file_sd` и relabel для `__param_target`
  - **`job_name: "ru-probe"`** — `file_sd` → `/etc/prometheus/targets/ru-probe.json`, `scrape_interval: 15s`

> После правок: либо отправляем POST на `http://127.0.0.1:{{ prometheus_port }}/-/reload`, либо рестартуем контейнер Prometheus.

**Проверка в контейнере:**
```bash
# Убедиться, что конфиг внутри контейнера обновился:
docker compose -f /opt/vff-monitoring/docker-compose.yml exec -T prometheus sh -lc   'grep -n "job_name: ru-probe" /etc/prometheus/prometheus.yml || echo "no ru-probe"'

# Статус активных таргетов:
curl -s 'http://127.0.0.1:{{ prometheus_port }}/api/v1/targets?state=any' | jq .data.activeTargets
```

---

## 4) Grafana: дашборды, экспорт/импорт

- **Файловый провайдер** читает JSON из `grafana/dashboards/**`.
- Именование файлов — **по UID**, а не по title (избегаем дубликатов и «кривых» имён от экспорта).
  - Примеры: `VPN/wireguard-health.json`, `VPN/vpn-network-utilization.json`,
    `Marzban/marzban-online-nodes.json`, `Reality/reality-table.json`.
- Экспорт из Grafana (Ansible): задачи в `grafana_export.yml`/`grafana_export_one.yml`:
  - вытягиваем по UID через API;
  - нормализуем через `jq` (datasource Prometheus → `"Prometheus"`, `del(.id)`, берём `.dashboard`);
  - сохраняем в файл **UID.json** в папке по `meta.folderTitle`.

**Типичные проблемы и решения:**
- `the same UID is used more than once` / `dashboard title is not unique` → удаляем дубликаты файлов по title, оставляем только `UID.json`.
- `Not saving new dashboard due to restricted database access` при провижининге — это предупреждение при наличии дублей; устраняем дубли.

**Перезагрузка Grafana:**
```bash
docker compose -f /opt/vff-monitoring/docker-compose.yml restart grafana
```

---

## 5) Blackbox Exporter

- Конфигурируется в `blackbox.yml` (шаблоны и задачи роли).
- Таргеты приходят через `file_sd` (`bb-icmp.json`, `bb-tcp443.json`).
- Relabel-конвейер:
  - `__address__` из file_sd → `__param_target` (то, что пингуем)
  - `instance` = `__param_target`
  - `__address__` заменяем на `127.0.0.1:{{ blackbox_port }}` (сам blackbox_exporter)
  - Доп. метки (e.g. `target_host` без порта) — для удобства переменных в Grafana.

---

## 6) Частые операции

### Развёртывание только Prometheus+targets
```bash
ansible-playbook -i ansible/hosts.ini ansible/site.yml --limit hub --tags prometheus
```

### Загрузка/обновление дашбордов
```bash
# Полностью синхронизировать папки dashboards/** (filetree провайдер)
make grafana-dashboards
# или
ansible-playbook -i ansible/hosts.ini ansible/site.yml --limit hub --tags grafana_dashboards
docker compose -f /opt/vff-monitoring/docker-compose.yml restart grafana
```

### Экспорт конкретного дашборда по UID (в файл UID.json)
```bash
ansible-playbook -i ansible/hosts.ini ansible/site.yml --limit hub   --tags grafana_export --extra-vars 'dash_uid=<UID>'
```

### Reload Prometheus без рестарта контейнера
```bash
curl -s -X POST http://127.0.0.1:{{ prometheus_port }}/-/reload
```

### Проверка конфигов promtool
```bash
docker run --rm -v /opt/vff-monitoring/prometheus:/etc/prometheus:ro   --entrypoint /bin/promtool prom/prometheus:v2.55.1   check config /etc/prometheus/prometheus.yml
```

---

## 7) Тонкости и грабли

- После обновления шаблонов Prometheus обязательно проверить, что **внутри контейнера** конфиг обновился (bind mount есть, но контейнер мог не перечитать — помогает `/-/reload` или рестарт).
- Для **file_sd** новые файлы в `targets/*.json` подхватываются Prometheus автоматически (watcher), но с интервалом `refresh_interval`. В шаблоне можно уменьшить `refresh_interval` при необходимости.
- В Grafana избегаем дублирующих UID и титулов в одной папке. Сохраняем **только файлы по UID**.
- Если Grafana пишет про «restricted database access» — это из‑за конфликтов провижининга (обычно дубли).

---

## 8) Где править

- Prometheus:
  - `ansible/roles/hub/templates/prometheus.yml.j2`
  - `ansible/roles/hub/templates/rules/*.yml.j2`
  - `ansible/roles/hub/templates/targets/*.json.j2`
  - задачи: `ansible/roles/hub/tasks/prometheus.yml`

- Grafana:
  - дашборды: `grafana/dashboards/**` (именование — по UID)
  - экспорт: `ansible/roles/hub/tasks/grafana_export*.yml`
  - провижининг: `ansible/roles/hub/tasks/grafana.yml`

- Docker Compose:
  - шаблон: `ansible/roles/hub/templates/docker-compose.yml.j2`
  - задачи: `ansible/roles/hub/tasks/compose.yml`

---

## 9) Мини‑чеклист после изменений

1. `make grafana-dashboards` → перезапустить Grafana.
2. Рендер `prometheus.yml` и targets → `/-/reload` Prometheus.
3. `curl /api/v1/status/config` и `/api/v1/targets?state=any` — убедиться, что джобы и таргеты видны.
4. Проверить ключевые метрики и переменные Grafana (datasource `"Prometheus"`).



---

## Переменные роли

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `monitoring_root` | Корень стека мониторинга на хосте | `/opt/vff-monitoring` |
| `prometheus_port` | Порт HTTP Prometheus (в контейнере и для health) | `9090` |
| `alertmanager_port` | Порт HTTP Alertmanager | `9093` |
| `blackbox_port` | Порт HTTP Blackbox Exporter | `9115` |
| `prometheus_image` | Образ контейнера Prometheus | `prom/prometheus:v2.55.1` |
| `external_url_prometheus` | Опциональный `--web.external-url` Prometheus | `""` (не задан) |
| `grafana_image` | Образ контейнера Grafana | `grafana/grafana:10.4.5` |
| `grafana_port` | Порт Grafana (если используется; при host network) | `3000` |
| `grafana_api_url` | Базовый URL API Grafana для экспорта | `http://127.0.0.1:{{ grafana_port }}` |
| `grafana_admin_token` | API Token админа Grafana (если задан — используется вместо basic auth) | `""` |
| `grafana_admin_user` | Логин админа Grafana (если токен не задан) | `admin` |
| `grafana_admin_password` | Пароль админа Grafana (если токен не задан) | `admin` |
| `grafana_dash_dir` | Путь к каталогу с дашбордами на **хосте** | `{{ monitoring_root }}/grafana/dashboards` |
| `grafana_provider_name` | Имя файлового провайдера (для читаемости логов) | `filetree` |
| `prometheus_rules_refresh_interval` | Интервал пересканирования rules (фактически задаётся прометеем; в роли — просто файлы) | `5m` (внутр. поведение Prometheus) |
| `file_sd_refresh_interval` | Интервал пересканирования `targets/*.json` | `5m` (если не переопределён в шаблоне) |
| `marzban_exporter_enabled` | Включить scrape Marzban exporter | `false` |
| `marzban_exporter_bind_port` | Порт Marzban exporter (если включён) | `9205` |
| `marzban_exporter_protected` | Включить basic auth к exporter | `true/false` (как в инвентаре) |
| `EXPORTER_METRICS_USER` | Basic auth user для защищённых экспортеров | `metrics` |
| `EXPORTER_METRICS_PASS` | Basic auth password для защищённых экспортеров | `""` |
| `ru_probe_enabled` | Включить job `ru-probe` | `true` |
| `ru_probe_targets` | Список таргетов RU‑зондов для генерации `targets/ru-probe.json` (см. ниже) | `[]` |

### Формат `ru_probe_targets`
Список словарей; каждый элемент попадает в `targets/ru-probe.json` (file_sd). Пример:
```yaml
ru_probe_targets:
  - address: "10.77.0.1:9100"   # обязательное поле — адрес node_exporter
    labels:
      name: "RU-probe (Moscow)"
      role: "probe"
  - address: "10.88.0.2:9100"
    labels:
      name: "RU-probe (SPB)"
      role: "probe"
```
> Если роль RU‑зонда совмещена с хабом, укажите локальный адрес/порт `node_exporter` этого же сервера.

### Примечания
- В дашбордах **datasource** должен быть `"Prometheus"` (строка), не объект с `{type, uid}` — это нормализуется в экспорте.
- Имена файлов дашбордов — **по UID** (например, `Reality/reality-table.json`). Это предотвращает дубли при реэкспорте.
- `docker-compose.yml` генерируется из шаблона; контейнеры работают с `network_mode: host`, конфиги подмонтированы read‑only.
