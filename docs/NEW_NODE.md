# Подключение нового узла (VPN node) к системе мониторинга и WireGuard

## TL;DR — самый быстрый способ

**Одна команда делает всё:** WireGuard на узле → агенты мониторинга (node + node_exporter + speedtest_ookla) → обновление пиров на хабе → применение роли hub.

```bash
make add-node HOST=<hostname>
```

После этого — проверь:  
```bash
make add-node-check HOST=<hostname>   # wg show + ping wg_ip + наличие таргета в Prometheus
```

> Перед запуском убедись, что узел добавлен в `ansible/hosts.ini` (в группу `[vpn]`), его параметры есть в `group_vars/all.yml → vpn_nodes`, **и настроен SSH-доступ на Ansible-контроллере** (см. шаг 0 ниже).

---

## 0) Предпосылки и доступ по SSH

- Хаб мониторинга развернут (Prometheus/Alertmanager/Grafana, reverse-proxy и т.д.).
- Роли в репозитории: `wireguard_hub`, `wireguard_node`, `node`, `node_exporter`, `speedtest_ookla`, `hub`.
- В `ansible/hosts.ini` перечисляются **только имена** хостов; параметры узлов (wg_ip, instance, role и пр.) — в `ansible/group_vars/all.yml` в ключе `vpn_nodes`.
- На Ansible-контроллере настроен SSH-доступ к узлам.

### 0.1 Установить публичный ключ на узел (если доступ пока по паролю)

Через IP/домен напрямую:
```bash
ssh-copy-id -i ~/.ssh/ds_ansible.pub root@203.0.113.10
```

Через алиас из `~/.ssh/config` (рекомендуется, см. ниже):
```bash
ssh-copy-id -i ~/.ssh/ds_ansible.pub nl-ams-1
```

> Команда запросит пароль пользователя и добавит ключ в `~/.ssh/authorized_keys` на узле.

### 0.2 Настроить конфиг SSH на контроллере (удобно для ansible/ssh)

Добавь хост в `~/.ssh/config` (пример):
```
Host nl-ams-1
  HostName 109.107.185.238
  User root
  Port 22
  IdentityFile ~/.ssh/ds_ansible
  IdentitiesOnly yes
  ServerAliveInterval 60
```

Проверь доступ и отпечаток ключа:
```bash
ssh nl-ams-1 true            # первый коннект добавит host key в known_hosts
ssh nl-ams-1 'uname -a'      # быстрая проверка
ansible -i ansible/hosts.ini nl-ams-1 -m ping   # проверка через Ansible
```

> Альтернатива: можно не править `~/.ssh/config`, а задать `ansible_host`, `ansible_user`, `ansible_port`, `ansible_ssh_private_key_file` прямо в инвентори. Но единый SSH-конфиг обычно удобнее.

---

## 1) Добавить узел в инвентори и метаданные

### 1.1 `ansible/hosts.ini`
```ini
[hub]
monitoring-hub

[vpn]
nl-ams-1
nl-ams-2    # ← новый узел
```

### 1.2 `ansible/group_vars/all.yml` → `vpn_nodes`
Минимальный набор полей: `name`, `wg_ip`, `instance`, `role`.
```yaml
vpn_nodes:
  - name: "nl-ams-1"
    instance: "10.77.0.2:9100"     # адрес node_exporter
    wg_ip: "10.77.0.2"
    role: "vpn"
    uplink_device: "ens3"          # опц.
    uplink_speed_bps: 10000000000  # опц., 10 Gbit/s

  - name: "nl-ams-2"               # ← новый
    instance: "10.77.0.22:9100"
    wg_ip: "10.77.0.22"
    role: "vpn"
```

> Важно: имя в `[vpn]` **должно совпадать** с `vpn_nodes[*].name` — это ключ для пиров и таргетов.

---

## 2) Быстрый онбординг (рекомендуется)

Запусти расширенную команду — **ставит и WG, и агенты**, и обновляет хаб:

```bash
make add-node HOST=nl-ams-2
```

Что происходит:
1. `wireguard_node` на узле (создание `/etc/wireguard/wg0.*`, запуск интерфейса).
2. **Агенты мониторинга на узел**: `node` (iperf3 + if_speed), `node_exporter`, `speedtest_ookla`.
3. Обновление пиров на хабе (`wireguard_hub`).
4. Применение роли `hub` (рендер targets/rules и пр.).

Проверка после онбординга:
```bash
make add-node-check HOST=nl-ams-2
```

> Нужна версия «с проверками в пакете»? Используй:
> ```bash
> make add-node-all HOST=nl-ams-2
> ```

---

## 3) По шагам (если нужно ручное управление)

```bash
make wg-node HOST=nl-ams-2        # только WireGuard на узле
make wg-hub                       # обновить peers на хабе
make node-bootstrap HOST=nl-ams-2 # node + node_exporter + speedtest_ookla
make wg-check                     # проверить связность (ping wg_ip с хаба)
```

---

## 4) Prometheus: таргеты и hot-reload (если используется автогенерация)

```bash
make prom-targets && make prom-reload
```
- `prom-targets` — рендерит `targets/nodes.json`, `targets/bb-icmp.json`, `targets/bb-tcp443.json` (Jinja2 из `vpn_nodes`) и копирует на хаб.
- `prom-reload` — POST `/-/reload` (требует `--web.enable-lifecycle`).

---

## 5) Grafana: дашборды и проверка

Обновить/залить дашборды:
```bash
make grafana-dashboards
```
Проверь, что переменные `$node`/`$name` видят новый узел. Ожидаемые метрики:
- `if_speed.prom` (из роли `node`),
- `speedtest_ookla.prom`,
- системные из `node_exporter`,
- (опц.) RU-проба/iperf3.

---

## 6) Быстрый чек-лист

1. Установить публичный ключ на узел (`ssh-copy-id`), настроить `~/.ssh/config`, проверить коннект.  
2. Добавить узел в `[vpn]` (`hosts.ini`) и `vpn_nodes` (`group_vars/all.yml`).  
3. **Сразу всё:** `make add-node HOST=<hostname>` → затем `make add-node-check HOST=<hostname>`.  
   **Или по шагам:** `make wg-node HOST=<hostname>` → `make wg-hub` → `make node-bootstrap HOST=<hostname>` → `make wg-check`.  
4. (Опц.) `make prom-targets && make prom-reload` — обновить Prometheus.  
5. `make grafana-dashboards` — обновить дашборды (при необходимости).  
6. Открыть Grafana и убедиться в наличии метрик.

---

## 7) Трюблшутинг

- **Нет пингов по wg0**: проверь `wg show`, firewall (UDP порт `{{ wg_listен_port }}` на хабе), `wg_ip`, MTU (в шаблоне есть `MTU = {{ wg_mtu }}`).  
- **Нет textfile-метрик**: проверь, что у `node_exporter` включен textfile-коллектор, и путь совпадает с тем, куда пишут `node`/`speedtest_ookla`.  
- **Пром-таргеты**: убеждайся, что `instance` в `vpn_nodes` соответствует адресу `node_exporter` (например, `10.77.0.22:9100`).  
- **Публичные ключи WG** не подтянулись: имя в `[vpn]` должно совпадать с `vpn_nodes[*].name`; доступ по SSH к `/etc/wireguard/wg0.pub` обязателен.

---

## 8) Справка по целям Makefile (коротко)

```text
add-node HOST=<h>        — «всё сразу»: WG + агенты (node+node_exporter+speedtest) → peers на хабе → роль hub
add-node-all HOST=<h>    — add-node + проверки (wg show, ping wg_ip, Prom targets)
add-node-check HOST=<h>  — проверки после онбординга (wg show, ping wg_ip, Prom targets)

wg-node HOST=<h>         — только WireGuard на узле (wireguard_node)
wg-hub                    — обновить peers на хабе (wireguard_hub)
wg-check                  — проверить связность (ping wg_ip с хаба)

node-bootstrap HOST=<h>   — node (iperf3+if_speed) + node_exporter + speedtest_ookla
node-only HOST=<h>        — только роль node
node-exporter HOST=<h>    — только node_exporter
node-speedtest HOST=<h>   — только speedtest (Ookla)

prom-targets              — сгенерировать file_sd таргеты из vpn_nodes
prom-reload               — hot-reload Prometheus

grafana-dashboards        — импорт/обновление дашбордов
```
