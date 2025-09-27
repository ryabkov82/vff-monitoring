# Grafana (роль `hub`): памятка по эксплуатации

Эта памятка описывает, как работать с задачами Grafana в роли `hub`:

- `ansible/roles/hub/tasks/grafana.yml` — директории, provisioning и загрузка дашбордов на хаб  
- `ansible/roles/hub/tasks/grafana_token.yml` — автоматическое создание service account и токена, запись `.env.grafana`  
- `ansible/roles/hub/tasks/grafana_export.yml` и `grafana_export_one.yml` — экспорт дашбордов из Grafana в репозиторий

---

## Быстрый старт

1) **Выдать токен для экспорта** (разово или для ротации):
```bash
make grafana-token \
  ANSIBLE_FLAGS='-e grafana_token_refresh=true'
# В результате создаётся .env.grafana (в корне репо), добавляется в .gitignore
```

2) **Экспорт дашбордов из Grafana → репозиторий**:
```bash
# Все дашборды
make grafana-pull

# Только выбранные UID
make grafana-pull \
  ANSIBLE_FLAGS='-e grafana_export_uids=["availability","node-exporter-full"]'
```

3) **Заливка дашбордов на хаб** (hot-reload подхватит):
```bash
make grafana-dashboards
```

> Если Grafana доступна только локально на хабе, используйте SSH-туннель:
> `ssh -L 3000:127.0.0.1:3000 hub` и ставьте `grafana_api_url=http://127.0.0.1:3000`.

---

## Теги роли

- `grafana` — общий тег для задач Grafana  
- `grafana_provisioning` — только provisioning (`datasources.yml`, `dashboards.yml`)  
- `grafana_dashboards` — синхронизация JSON-дашбордов на хаб  
- `grafana_token` — выпуск service account токена и запись `.env.grafana`  
- `grafana_export` — экспорт дашбордов из Grafana в репозиторий

Примеры:
```bash
# Только provisioning
ansible-playbook -i ansible/hosts.ini ansible/site.yml --limit hub --tags grafana_provisioning

# Только загрузка дашбордов на хаб
ansible-playbook -i ansible/hosts.ini ansible/site.yml --limit hub --tags grafana_dashboards
```

---

## Переменные

### В `group_vars/hub/main.yml` (окружение)
```yaml
monitoring_root: /opt/vff-monitoring
grafana_dashboards_use_rsync: true    # rsync-зеркалирование (удаляет лишние)
grafana_port: 3000
grafana_domain: grafana-new.vpn-for-friends.com
# grafana_admin_user/grafana_admin_password — хранить в vault
```

### В `roles/hub/defaults/main.yml` (умные дефолты)
```yaml
mon_root: "{{ monitoring_root | default('/opt/vff-monitoring') }}"
grafana_dir: "{{ mon_root }}/grafana"
grafana_provisioning_dir: "{{ grafana_dir }}/provisioning"
grafana_dashboards_dir: "{{ grafana_dir }}/dashboards"
grafana_plugins_dir: "{{ grafana_dir }}/plugins"
grafana_dashboards_repo_dir: "{{ playbook_dir }}/../grafana/dashboards"

grafana_api_url: "http://127.0.0.1:{{ grafana_port }}"
grafana_admin_user: "admin"
grafana_admin_password: null
grafana_admin_token: ""
grafana_token_refresh: false

# service account
grafana_sa_name: "export-bot"
grafana_sa_role: "Viewer"
grafana_sa_token_name: "export-token"
grafana_sa_ttl_seconds: 31536000  # 1 год

# экспорт
grafana_export_limit: 5000
grafana_export_jq_filter: >
  .dashboard
  | del(.id)
  | (.. | objects | select(has("datasource")) | .datasource)
      |= (if type=="object" and .type=="prometheus" then "Prometheus" else . end)

# файлы на контрол-ноде
repo_root: "{{ lookup('ansible.builtin.pipe','git rev-parse --show-toplevel', errors='ignore') | default(playbook_dir ~ '/..', true) }}"
grafana_env_file: "{{ repo_root }}/.env.grafana"
grafana_dash_dir: "{{ repo_root }}/grafana/dashboards"
```

---

## Что делают задачи

### `grafana.yml`
- Создаёт деревья каталогов (`grafana`, `provisioning`, `dashboards`, `plugins`) с владельцем **472:472** и правами **0755/0644**.
- Рендерит `provisioning/datasources.yml` и `provisioning/dashboards.yml` → `notify: Restart grafana`.
- Синхронизирует `grafana/dashboards/**` из репозитория на хаб (`copy` или `rsync` в зависимости от `grafana_dashboards_use_rsync`) без рестартов — Grafana подхватывает изменения сама (hot-reload).

### `grafana_token.yml`
- Если `.env.grafana` отсутствует **или** `grafana_token_refresh=true`:
  - Пытается использовать **Service Accounts API**:
    - Находит/создаёт SA `export-bot` (Viewer).  
    - Создаёт токен (при проблемах с `secondsToLive` — делает повтор без TTL).  
  - Если SA API недоступен — фолбэк на **legacy API key**.
  - Пишет `.env.grafana` (режим `0600`) и добавляет его в `.gitignore`.

### `grafana_export.yml` / `grafana_export_one.yml`
- Получает список дашбордов (или использует `grafana_export_uids`).
- По каждому UID тянет JSON, нормализует `jq` (убирает `id`, приводит datasource) и сохраняет в `grafana/dashboards/<Folder>/<Title>.json`.

---

## Makefile цели

```makefile
grafana-token:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_token $(ANSIBLE_FLAGS)

grafana-pull:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_export $(ANSIBLE_FLAGS)

grafana-dashboards:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_dashboards $(ANSIBLE_FLAGS)
```

Примеры:
```bash
# Выпустить токен (форс)
make grafana-token ANSIBLE_FLAGS='-e grafana_token_refresh=true'

# Экспорт всех дашбордов
make grafana-pull

# Экспорт конкретных UID
make grafana-pull ANSIBLE_FLAGS='-e grafana_export_uids=["availability"]'

# Заливка дашбордов на хаб
make grafana-dashboards
```

---

## Тонкости и отладка

- **Nginx 401 на внешнем домене:** это basic-auth прокси. Либо работайте через внутренний URL (`http://127.0.0.1:3000`, SSH-туннель), либо добавляйте `-u user:pass` к `curl`.
- **201 Created от API:** для `/api/serviceaccounts` и `/tokens` мы принимаем `200/201` как успех.
- **400 Bad request при создании токена:** у некоторых сборок ломается `secondsToLive` — роль автоматически повторяет запрос **без TTL**.
- **UID/GID 472:** права владельца каталогов и файлов Grafana ставятся на `472:472`.
- **hot-reload:** дашборды подхватываются без рестарта, provisioning — с рестартом сервиса.
- **`jq`**: требуется на контрол-ноде для нормализации JSON.

---

## Безопасность

- `.env.grafana` добавляется в `.gitignore` автоматически; права файла — `0600`.  
- Не публикуйте токены в CI/логах. Для ротации токена используйте `grafana_token_refresh=true`.  
- По необходимости можно добавить переменную `grafana_org_id` (число) — тогда роль будет явно указывать `X-Grafana-Org-Id` в запросах.
