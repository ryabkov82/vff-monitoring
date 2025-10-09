# Развёртывание RU‑зонда (RU zonde) для VFF Monitoring

Этот документ описывает, как развернуть RU‑зонд — отдельный хост, выполняющий **RU iperf3‑пробу** и публикующий метрики в Prometheus хаба. 
Зонд подключается к **хабу по WireGuard** (для публикации метрик, доступ к Prometheus) и **напрямую к VPN‑узлам по публичным адресам** для измерений iperf3. 
Допускается размещение зонда **на самом хабе** (при этом роль `wireguard_node` охранно пропускает любые WG‑мутации).

---

## TL;DR — самый быстрый способ

**Одна команда делает всё на зонд(е) и приводит хаб/Prometheus в актуальное состояние:**

```bash
# Один конкретный зонд:
make ru-zondes-setup-host HOST=<hostname>

# Все хосты группы ru_zondes:
make ru-zondes-setup
```

Под капотом выполняется: роли для зонда (`wireguard_node`* → `node_exporter` → `ru_probe`) →
**обновление правил iptables на VPN‑нодах** (`node-iperf-public-vpn`) →
пересборка пиров на хабе (`wg-hub`) → обновление правил/таргетов Prometheus (`prom-rules`).

\* На хабе роль `wireguard_node` безопасно **пропускает** мутацию WG (см. «Особые случаи»).

---

## 0) Предпосылки и SSH‑доступ

- Хаб мониторинга развернут и доступен (Prometheus/Alertmanager/Grafana, reverse‑proxy).
- Роли в репозитории: `wireguard_hub`/`wireguard`, `wireguard_node`, `node_exporter`, `ru_probe`, `hub`.
- Отдельный плейбук для зондов `ansible/playbooks/ru_zondes.yml` (плей с тегом **`ru_zondes_play`**), например:
  ```yaml
  - name: RU zondes (probes)
    hosts: ru_zondes
    tags: [ru_zondes_play]
    roles:
      - { role: wireguard_node, tags: [wg, wg_node] }
      - { role: node_exporter, tags: [node_exporter] }
      - { role: ru_probe, when: ru_probe_enabled | bool, tags: [ru_probe] }
  ```
- На Ansible‑контроллере настроен SSH‑доступ к зондами и **ssh‑aliases** для VPN‑узлов в `~/.ssh/config` (используются для извлечения публичных IP/FQDN для пробы).

### 0.1 Установить публичный ключ на зонд (если пока пароль)
```bash
ssh-copy-id -i ~/.ssh/ds_ansible.pub root@203.0.113.50
# либо через алиас из ~/.ssh/config:
ssh-copy-id -i ~/.ssh/ds_ansible.pub ru-msk-1
```

### 0.2 Удобный SSH‑алиас (пример)
```
Host ru-msk-1
  HostName 203.0.113.50
  User root
  Port 22
  IdentityFile ~/.ssh/ds_ansible
  IdentitiesOnly yes
  ServerAliveInterval 60
```
Проверка:
```bash
ssh ru-msk-1 'uname -a'
ansible -i ansible/hosts.ini ru-msk-1 -m ping
```

---

## 1) Инвентори и метаданные

### 1.1 `ansible/hosts.ini`
```ini
[hub]
monitoring-hub

[ru_zondes]
ru-msk-1             # ← новый зонд
# monitoring-hub     # опционально: можно сделать зондом сам хаб
```

### 1.2 `ansible/group_vars/all.yml` → `ru_zondes`
Минимум: `name`, `wg_ip`, `instance`, `role: probe`.
```yaml
ru_zondes:
  - name: "ru-msk-1"
    instance: "10.77.10.1:9100"    # адрес node_exporter по WG
    wg_ip: "10.77.10.1"
    role: "probe"
    labels:
      city: "Moscow"
      country: "RU"

  # Пример зонда на самом хабе
  - name: "monitoring-hub"
    instance: "10.77.0.1:9100"
    wg_ip: "10.77.0.1"
    role: "probe"
    labels:
      name: "RU-probe (hub)"
```

> Имя в `[ru_zondes]` **совпадает** с `ru_zondes[*].name` — ключ для таргетов и автосбора ключей WG.

---

## 2) Быстрый онбординг зонда (рекомендуется)

### Вариант A: один конкретный зонд
```bash
make ru-zondes-setup-host HOST=ru-msk-1
```
Сделает на хосте: `wireguard_node` → `node_exporter` → `ru_probe`,
затем: `node-iperf-public-vpn` → `wg-hub` → `prom-rules`.

### Вариант B: все зонды группы
```bash
make ru-zondes-setup
```

---

## 3) По шагам (ручной режим)

```bash
# 1. Только роли для зонда (без затрагивания хаба):
ansible-playbook -i ansible/hosts.ini ansible/playbooks/ru_zondes.yml \
  --limit ru-msk-1 --tags ru_zondes_play

# 2. Разрешения iptables на VPN‑нодах (доступ зондов к iperf3 public):
make node-iperf-public-vpn

# 3. Обновить WireGuard config на хабе (пиры vpn_nodes + ru_zondes):
make wg-hub

# 4. Обновить Prometheus (rules + targets/ru-probe.json) и сделать hot‑reload:
make prom-rules
```

---

## 4) Как выбираются цели для RU‑пробы

Роль `ru_probe` формирует список целей вида `name;ip;port` из `vpn_nodes`. 
IP берётся **из SSH‑конфига контроллера** (`~/.ssh/config → Host → HostName`). 
Если вместо IP указан FQDN — он резолвится в IPv4 через `getent`. 
Если соответствия нет, используются фолбэки: `public_ip` → `wg_ip`.
Порт берётся как `hostvars[<node>].iperf_public_port` (если определён), иначе глобальный `ru_probe_port_default` (по умолчанию 5202).

Это позволяет **не светить публичные IP** в ansible‑vars и централизованно управлять адресацией через SSH‑алиасы.

---

## 5) Проверка

### 5.1 WireGuard
На хабе:
```bash
wg show
ping -c3 10.77.10.1            # wg_ip зонда
```

На зонде:
```bash
wg show
ping -c3 10.77.0.1             # wg_ip хаба
```

### 5.2 RU‑проба (systemd)
На зонде:
```bash
systemctl status ru-iperf-probe.timer
journalctl -u ru-iperf-probe.service -n 200 --no-pager
```
Разовый запуск:
```bash
systemctl start ru-iperf-probe.service
```

### 5.3 Метрики
На зонде:
```bash
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
test -f $TEXTFILE_DIR/ru_iperf.prom && cat $TEXTFILE_DIR/ru_iperf.prom || echo "no metrics yet"
```

В Prometheus на хабе: проверь `targets/ru-probe.json` и метрики `ru_probe_*`/`ru:wg:*`.

---

## 6) Make‑цели для зондов (кратко)

```
ru-zondes-setup-host HOST=<h>  — роли на одном зонде → node-iperf-public-vpn → wg-hub → prom-rules
ru-zondes-setup               — роли на всей группе  → node-iperf-public-vpn → wg-hub → prom-rules

ru-proбе HOST=<h>             — только роль ru_probe на одном зонде
ru-probe-zondes               — только роль ru_probe на всей группе

node-iperf-public-vpn         — обновить iptables на всех VPN‑нодах (доступ с RU‑зондов)
wg-hub                        — пересобрать конфиг WG на хабе (пиры vpn_nodes + ru_zondes)
prom-rules                    — обновить правила/таргеты Prometheus и выполнить /-/reload
```

---

## 7) Таргеты Prometheus для зондов

Шаблон `ansible/roles/hub/templates/targets/ru-probe.json.j2` строится из `ru_zondes`:
```jinja
[
{% set items = (ru_zondes | default([])) | selectattr('instance', 'defined') | list -%}
{%- for z in items %}
  {
    "targets": ["{{ z.instance }}"],
    "labels": {{ (
      {'name': z.name, 'role': (z.role | default('probe'))}
      | combine(z.labels | default({}))
    ) | to_json }}
  }{% if not loop.last %},{% endif %}
{%- endfor %}
]
```
Это попадает под `make prom-rules` (рендер и hot‑reload).

---

## 8) Особые случаи и безопасность

- **Зонд на самом хабе.** Роль `wireguard_node` должна «охранно» пропустить мутационные шаги на хабе (гвард по принадлежности к группе `hub`). Тогда `ru_probe` и `node_exporter` применятся, а WireGuard‑конфиг хаба не будет перезаписан.
- **Автосбор pubkey’ев на хабе.** `wireguard_hub` собирает ключи из групп `vpn` и `ru_zondes` и добавляет пиров обоих типов, исключая самого хаба (`wg_ip != hub_wg_ip`).
- **Пересборка после изменений.** Любые изменения в `ru_zondes` (добавили/удалили зонд) требуют `node-iperf-public-vpn` → `wg-hub` → `prom-rules` (они уже входят в цели `ru-zondes-setup*`).

---

## 9) Деинсталляция RU‑зонда

Когда зонд больше не нужен, важно корректно выключить его задания, чтобы он не генерировал нагрузку на VPN‑узлы.

### Вариант A — через Make (рекомендуется)

```bash
# 1) Остановить и удалить юниты/скрипты зонда на конкретном хосте
make ru-probe-uninstall-host HOST=<hostname>

# 2) Удалить хост из инвентори и метаданных:
#    - из [ru_zondes] в ansible/hosts.ini
#    - из ru_zondes в ansible/group_vars/all.yml

# 3) Обновить конфиг WireGuard на хабе (уберёт peer зонда)
make wg-hub

# 4) Обновить цели/правила Prometheus и выполнить hot‑reload
make prom-rules
```

Для всей группы сразу:
```bash
make ru-probe-uninstall
# затем вручную поправить hosts.ini и group_vars/all.yml, и выполнить:
make wg-hub && make prom-rules
```

### Вариант B — напрямую Ansible

```bash
# Точечно:
ansible-playbook -i ansible/hosts.ini ansible/playbooks/ru_zondes.yml \
  --limit <hostname> --tags ru_probe -e ru_probe_state=absent
```

После удаления хоста из инвентори/vars:
```bash
make wg-hub && make prom-rules
```

### Что именно делает деинсталляция (ru_probe_state=absent)

- Останавливает и отключает `ru-iperf-probe.timer` и `ru-iperf-probe.service` (маскирует).
- Удаляет unit‑файлы, скрипт `/usr/local/bin/ru_iperf_probe.sh` и `/etc/default/ru-iperf-probe` (если включено).
- Чистит файл метрик `ru_iperf.prom` в каталоге textfile (`/var/lib/node_exporter/textfile_collector` либо путь из `/etc/default/ru-iperf-probe`).

> Пакеты (`iperf3`, `jq`, `curl`) не удаляются — умышленно, чтобы не затрагивать зависимости других ролей.

### Быстрая проверка на хосте

```bash
systemctl is-active  ru-iperf-probe.service || true
systemctl is-enabled ru-iperf-probe.service || true
systemctl is-active  ru-iperf-probe.timer   || true
systemctl is-enabled ru-iperf-probe.timer   || true
systemctl list-timers --all | grep -F ru-iperf-probe || echo "ok: no timers"
ls -l /etc/systemd/system/ru-iperf-probe.* || echo "ok: no unit files"

# (если чистим метрики)
TEXTFILE_DIR=$(awk -F= '/^\s*TEXTFILE_DIR\s*=/{print $2}' /etc/default/ru-iperf-probe 2>/dev/null | tr -d '[:space:]')
[ -z "$TEXTFILE_DIR" ] && TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
test -f "$TEXTFILE_DIR/ru_iperf.prom" || echo "ok: no ru_iperf.prom"
```

### Проверка на хабе

- `wg show` — peer зонда должен исчезнуть после `make wg-hub`.
- В Prometheus `targets/ru-probe.json` — соответствующая цель исчезает после `make prom-rules`.

---

## 10) Troubleshooting

- **Дублируется запуск node_exporter на хабе.** Используйте тег **плея** `ru_zondes_play` (не тег роли) при таргетинге зондов.
- **Нет таргета зонда в Prometheus.** Убедитесь, что у элемента `ru_zondes` заполнено `instance` (`host:port` `node_exporter` по WG), затем `make prom-rules`.
- **Нет метрик RU‑пробы.** Проверьте таймер/сервис и значение `TEXTFILE_DIR` в конфиге `node_exporter`.
- **Нет пинга между хабом и зондом.** Проверьте `wg show`, firewall (на хабе открыт UDP ${wg_listen_port}), MTU ${wg_mtu}.

---

## 11) Мини чек‑лист оператора

1. Добавить хост в `[ru_zondes]` и элемент в `ru_zondes` (`group_vars/all.yml`).  
2. `make ru-zondes-setup-host HOST=<hostname>` **или** `make ru-zondes-setup`.  
3. Проверить WG‑линки, таргеты Prometheus, логи RU‑пробы и появление метрик.
