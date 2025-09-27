# WireGuard роли (`wireguard_hub`, `wireguard_node`): памятка

Этот документ — краткая шпаргалка по ролям WireGuard. **Пошаговый онбординг нового узла вынесен в отдельный runbook:**  
👉 см. [docs/NEW_NODE.md](docs/NEW_NODE.md).

---

## Что где

- `ansible/roles/wireguard_hub/tasks/main.yml` — настройка **хаба**: ключи, сбор pubkey'ев узлов, рендер `/etc/wireguard/<iface>.conf`, UFW, запуск `wg-quick`.
- `ansible/roles/wireguard_node/tasks/main.yml` — настройка **узла**: ключи, получение pubkey хаба, рендер `/etc/wireguard/<iface>.conf`, запуск `wg-quick`.

Роли вызываются из `ansible/site.yml` и удобнее запускать через цели Makefile (см. ниже).

---

## Теги ролей

- `wg` — общий тег для WG-задач (хаб и узлы).
- `wg_hub` — только задачи роли `wireguard_hub`.
- `wg_node` — только задачи роли `wireguard_node`.

Примеры:
```bash
ansible-playbook -i ansible/hosts.ini ansible/site.yml --limit hub --tags wg_hub
ansible-playbook -i ansible/hosts.ini ansible/site.yml --limit vpn --tags wg_node
```

---

## Переменные

Все ключевые параметры для узлов задаём через `vpn_nodes` в `group_vars/all.yml`. Для хаба — через `group_vars/hub/*.yml`.

Общие (могут лежать в `group_vars/all.yml`):
```yaml
wg_iface: wgmon0
wg_listen_port: 51821
wg_mtu: 1280
```

Хаб (в `group_vars/hub/main.yml` или vault):
```yaml
# Вариант A: BYO-ключ из Vault (если задан — пара ключей не генерится)
hub_wg_private_key: !vault |
  <секрет>

# (опц.) Публичный ключ хаба, если хотите раздавать его без делегированного чтения:
hub_wg_pubkey: "..."  # обычно не требуется
```

Узлы — через список `vpn_nodes` (в `group_vars/all.yml`):
```yaml
vpn_nodes:
  - name: "nl-ams-1"            # должно совпадать с inventory_hostname
    wg_ip: "10.77.0.2"          # WG /32 адрес узла (обязателен)
    instance: "10.77.0.2:9100"  # адрес таргета node_exporter для Prometheus
    role: "vpn"
  # - name: "nl-ams-2"
  #   wg_ip: "10.77.0.3"
  #   instance: "10.77.0.3:9100"
  #   role: "vpn"
```

> Роль `wireguard_node` **не требует** `host_vars`: она находит `wg_ip` по записи в `vpn_nodes`, где `name == inventory_hostname`. Если записи нет — задача упадёт с понятной ошибкой (нужно добавить узел в `vpn_nodes`).

---

## Поток роли `wireguard_hub`

1. Установка пакетов (`apt`).  
2. Каталог `/etc/wireguard` (0750).  
3. Ключи:
   - если `hub_wg_private_key` задан — пишем `.key`, считаем `.pub`;
   - иначе — генерируем пару (идемпотентно).  
4. Права на ключи: `.key` — 0600, `.pub` — 0644.  
5. Считываем приватный ключ в факт `hub_wg_privkey_runtime` (не логируем).  
6. Собираем pubkey'и узлов (delegated slurp) → `vpn_pubmap`.  
7. Рендерим `/etc/wireguard/<iface>.conf` из `wg-hub.conf.j2` → notify: `Restart wg-quick`.  
8. (Если есть UFW) открываем UDP-порт.  
9. Включаем и стартуем `wg-quick@<iface>`.

---

## Поток роли `wireguard_node`

1. Установка пакетов (`apt`).  
2. Каталог `/etc/wireguard` (0750).  
3. Генерация пары ключей (если `.key` отсутствует) + права (0600/0644).  
4. Читаем свой pubkey в `node_wg_pubkey`.  
5. Определяем `wg_ip` (или берём из `vpn_nodes`).  
6. Читаем pubkey хаба делегированно или используем `hub_wg_pubkey`.  
7. Рендерим `/etc/wireguard/<iface>.conf` из `wg-node.conf.j2` → notify: `Restart wg-quick`.  
8. Включаем и стартуем `wg-quick@<iface>`.

---

## Makefile (основные цели)

```bash
# Роль узла / всей группы vpn
make wg-node
# Роль хаба
make wg-hub
# Хаб + узлы
make wg
# Статусы интерфейсов на хабе и узлах
make wg-status

# Онбординг узла (шаги 1–3) — подробности в docs/NEW_NODE.md
make add-node HOST=<hostname>
# Проверки после онбординга (шаг 7 runbook'а)
make add-node-check HOST=<hostname> [WG_IP=10.77.0.X] [NODE_PORT=9100]
# Полный онбординг + проверка
make add-node-all HOST=<hostname> [WG_IP=10.77.0.X] [NODE_PORT=9100]
```

---

## Отладка и безопасность

- Смотрите `wg show`, `systemctl status wg-quick@wgmon0`, `journalctl -u wg-quick@wgmon0 -e`.  
- Приватные ключи никогда не печатаются в логах (`no_log: true`), лежат на хостах с правами 0600.  
- Если UFW включён — правило открытия порта WG добавляется автоматически.  
- Для дистрибутивов без APT добавьте собственные таски установки пакетов.

---

_Документ: `docs/wireguard-roles.md`. Подробный онбординг: `docs/NEW_NODE.md`._
