# Роль `node_exporter`: памятка по эксплуатации

Эта памятка описывает, как использовать роль `ansible/roles/node_exporter`, какие переменные она ждёт, как она обновляет бинарник и поднимает сервис, а также быстрые команды из Makefile.

---

## Где находится

- Роль: `ansible/roles/node_exporter`
  - Основные задачи: `tasks/main.yml`
  - Юнит systemd-шаблон: `templates/node_exporter@.service.j2`
- Makefile цели:
  - `node-exporter` — развернуть/обновить на одном узле
  - `node-exporter-vpn` — развернуть/обновить на всей группе `vpn`

---

## Теги

- `node_exporter` — включает все задачи роли для установки/обновления и запуска экземпляра.

Примеры запуска:
```bash
# Один узел
make node-exporter HOST=nl-ams-1

# Все узлы в группе vpn
make node-exporter-vpn
```

---

## Переменные

Роль рассчитывает WG-адрес узла из `vpn_nodes` **автоматически** (по `name == inventory_hostname`). Отдельные `host_vars` не нужны.

Глобальные/общие (обычно в `group_vars/all.yml`):
```yaml
# Список узлов мониторинга (см. также docs/NEW_NODE.md)
vpn_nodes:
  - name: "nl-ams-1"
    wg_ip: "10.77.0.2"
    instance: "10.77.0.2:9100"
    role: "vpn"

# Версия и архитектура node_exporter
node_exporter_version: "1.8.2"
# Возможные значения arch: linux-amd64, linux-arm64, linux-armv7 и т.п.
node_exporter_arch: "linux-amd64"

# Пути и порты
node_exporter_bin_dir: "/usr/local/bin"
node_exporter_port: 9100
# Адрес для bind экземпляра (обычно WG-IP узла)
# Формируется в роли как: node_exporter_listen = "{{ wg_ip }}:{{ node_exporter_port }}"
node_exporter_textfile_dir: "/var/lib/node_exporter/textfile_collector"
```

> Если `wg_ip` для узла не указан в `vpn_nodes`, роль упадёт с понятным сообщением — добавьте запись.

---

## Что делает роль (поток)

1. **Определение WG-IP узла**  
   Если переменная `wg_ip` не задана, роль пытается найти её в `vpn_nodes` по `name == inventory_hostname`.  

2. **Проверка валидности `wg_ip`**  
   Явная валидация (через `ansible.utils.ipaddr`).

3. **Системный пользователь**  
   Создаёт `node_exporter` (system, без shell, без home).

4. **Каталог для textfile-коллектора**  
   Создаёт `{{ node_exporter_textfile_dir }}` с владельцем `node_exporter:node_exporter` и правами `0755`.

5. **Проверка установленного бинарника и версии**  
   Если бинарник уже есть — роль парсит версию из вывода `node_exporter --version`.

6. **Загрузка и установка/обновление**  
   Если установленная версия отличается от желаемой (`node_exporter_version`) — скачивает tar.gz с GitHub, распаковывает и копирует бинарник в `{{ node_exporter_bin_dir }}` с правами `0755`. Триггерит рестарт юнита.

7. **Systemd unit (@instance)**  
   Разворачивает шаблон `node_exporter@.service` в `/etc/systemd/system/`. Выполняет `daemon-reload`.

8. **Запуск сервиса**  
   Включает и запускает `node_exporter@{{ node_exporter_listen }}`, где `node_exporter_listen` — это по умолчанию `"{{ wg_ip }}:{{ node_exporter_port }}"`.

9. **UFW (опционально)**  
   Если в системе есть `ufw`, добавляет правило `allow tcp {{ node_exporter_port }}` **с ограничением по WG-подсети** (`10.77.0.0/24`), чтобы метрики были доступны только из туннеля.

---

## Как формируется `node_exporter_listen`

Роль использует WG-IP узла, определённый из `vpn_nodes`, и порт `node_exporter_port`:
```yaml
node_exporter_listen: "{{ wg_ip }}:{{ node_exporter_port }}"
```

Если нужно изменить bind-адрес (например, слушать на `127.0.0.1` и делать прокси) — задайте эту переменную явно на хост/группу.

---

## Пример systemd-шаблона `node_exporter@.service.j2` (смысл)

Шаблон должен подставлять адрес bind из `%i` (Instance):
```ini
[Unit]
Description=Prometheus Node Exporter (%i)
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart={{ node_exporter_bin_dir }}/node_exporter \
  --collector.textfile.directory={{ node_exporter_textfile_dir }} \
  --web.listen-address=%i
Restart=on-failure
RestartSec=2s
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

> Важно: имя юнита будет, например, `node_exporter@10.77.0.2:9100.service`.

---

## Быстрые команды (Makefile)

```bash
# Установить/обновить на одном узле
make node-exporter HOST=nl-ams-1

# Установить/обновить на всех vpn-узлах
make node-exporter-vpn
```

---

## Проверка и диагностика

На узле:
```bash
sudo systemctl status 'node_exporter@*.service'
sudo journalctl -u 'node_exporter@10.77.0.2:9100' -e
curl -s http://10.77.0.2:9100/metrics | head
```

С хаба:
```bash
# Проверить таргеты Prometheus (должен быть WG-IP узла:порт)
curl -s http://127.0.0.1:9090/api/v1/targets?state=active \
 | jq -r '.data.activeTargets[].labels.instance' | sort
```

---

## Частые вопросы (FAQ)

**1) Роль падает с ошибкой "wg_ip не задан/некорректен"**  
Добавьте узел в `vpn_nodes` с `name == inventory_hostname` и корректным `wg_ip`.

**2) Как ограничить доступ к метрикам снаружи**  
По умолчанию слушаем на WG-IP (частная подсеть). Дополнительно UFW открывает порт только из WG-подсети. Можно слушать на `127.0.0.1` и делать reverse-proxy/SSH-туннель.

**3) Как обновить версию node_exporter**  
Поменяйте `node_exporter_version` в vars и перезапустите роль — бинарник скачается и заменится, юнит перезапустится.

**4) Ошибка загрузки из GitHub (TLS/прокси)**  
Можно скачать архив вручную и положить в `/tmp/node_exporter-<ver>.tar.gz`, затем запустить роль повторно.

---

## Безопасность

- Экспортер слушает на WG-IP, не светится в публичной сети.
- UFW (если установлен) разрешает доступ только из WG-подсети.
- Пользователь `node_exporter` без shell и домашнего каталога.

---

_Документ хранится в `docs/node-exporter-role.md`._
