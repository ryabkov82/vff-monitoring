# Подключение нового узла (VPN node) к системе мониторинга и WireGuard

## TL;DR — самый быстрый способ

**Одна команда делает всё:** WireGuard на узле → агенты мониторинга (node + node_exporter + speedtest_ookla) → обновление пиров на хабе → применение бандла на хабе.

```bash
make add-node HOST=<hostname>
```

После этого — проверь:  
```bash
make add-node-check HOST=<hostname>   # wg show + ping wg_ip + таргет в Prometheus
```

> Перед запуском убедись, что узел добавлен в `ansible/hosts.ini` (в группу `[vpn]`), **создан `ansible/host_vars/<hostname>.yml` с обязательными полями** (см. ниже), и **настроен SSH-доступ на Ansible-контроллере** (см. шаг 0).

---

## 0) Предпосылки и доступ по SSH

- Хаб мониторинга развёрнут (Prometheus/Alertmanager/Grafana).
- Роли в репозитории: `wireguard_hub`, `wireguard_node`, `node`, `node_exporter`, `speedtest_ookla`, `hub`.
- В `ansible/hosts.ini` перечисляются **имена** хостов по группам; параметры узла лежат в `ansible/host_vars/<host>.yml`.
- На Ansible-контроллере настроен SSH-доступ к узлам.

### 0.1 Установить публичный ключ на узел (если пока пароль)
```bash
ssh-copy-id -i ~/.ssh/ds_ansible.pub root@203.0.113.10
# или, если есть алиас в ~/.ssh/config:
ssh-copy-id -i ~/.ssh/ds_ansible.pub nl-ams-2
```

### 0.2 ~/.ssh/config на контроллере (рекомендуется)
```
Host nl-ams-2
  HostName 203.0.113.10
  User root
  Port 22
  IdentityFile ~/.ssh/ds_ansible
  IdentitiesOnly yes
  ServerAliveInterval 60
```

Проверка:
```bash
ssh nl-ams-2 true
ssh nl-ams-2 'uname -a'
ansible -i ansible/hosts.ini nl-ams-2 -m ping
```

---

## 1) Инвентори и host_vars

### 1.1 `ansible/hosts.ini`
```ini
[hub]
monitoring-hub

[vpn]
nl-ams-1
nl-ams-2     # ← новый узел
```

### 1.2 Обязательные переменные узла — `ansible/host_vars/nl-ams-2.yml`

Минимальный рабочий пример:
```yaml
# Как хотим отображать узел в метриках/лейблах (fallback — inventory_hostname)
node_name: "nl-ams-2"

# WG-адрес узла (используется для WireGuard и для Prometheus targets)
wg_ip: "10.77.0.22"

# Роль узла в мониторинге (метка Prometheus)
prom_role: "vpn"

# (опц.) сетевые параметры для панели пропускной способности
uplink_device: "ens3"
uplink_speed_bps: 10000000000   # 10 Gbit/s

# (опц.) настройки REALITY E2E для этого узла
# reality:
#   e2e_enabled: true
#   sni: "segment-ams-02.digitalstreamers.xyz"
```

> **Важно:** `wg_ip` должен быть задан. Именно его используют шаблоны `targets/*.json.j2` и роли WireGuard.

---

## 2) Быстрый онбординг

```bash
make add-node HOST=nl-ams-2
```

Что делает команда:
1. Роль `wireguard_node` на узле (генерация ключей при необходимости, конфиг интерфейса `{{ wg_iface }}`).
2. Установка агентов: `node` (в т.ч. if_speed), `node_exporter`, `speedtest_ookla`.
3. Обновление пиров на хабе (`wireguard_hub`).
4. Применение бандла на хабе (рендер targets/rules Prometheus, health).

Проверка:
```bash
make add-node-check HOST=nl-ams-2
```

---

## 3) По шагам (ручной сценарий)
```bash
make wg-node HOST=nl-ams-2        # только WireGuard на узле
make wg-hub                        # обновить peers на хабе
make node-bootstrap HOST=nl-ams-2  # node + node_exporter + speedtest_ookla
make wg-check                      # ping с хаба на wg_ip
```

---

## 4) Prometheus (targets и reload)

Таргеты рендерятся из `groups[]` и `hostvars[]`. Основные файлы:
- `/etc/prometheus/targets/nodes.json` — все VPN-ноды (node_exporter),
- `/etc/prometheus/targets/bb-icmp.json` — ICMP цели (WG IP),
- `/etc/prometheus/targets/bb-tcp443.json` — TCP:443 цели,
- `/etc/prometheus/targets/ru-probe.json` — метрики RU-пробы,
- `/etc/prometheus/targets/nodes-backup.json` — бэкап-клиенты (если используются).

Перегенерировать и перегрузить Prometheus:
```bash
ansible-playbook -i ansible/hosts.ini ansible/site.yml --tags prometheus --limit hub
curl -s http://127.0.0.1:9090/-/reload
```

---

## 5) Grafana

Обновить/залить дашборды (если используется автоматизация):
```bash
make grafana-dashboards
```
Проверь, что новый узел виден по переменным `$name`/`$instance`.

---

## 6) Чек-лист

1. `hosts.ini`: добавить узел в группу `[vpn]`.
2. `host_vars/<host>.yml`: как минимум `wg_ip`, `prom_role: vpn`, (опц.) `node_name`, `uplink_*`.
3. `make add-node HOST=<host>` → затем `make add-node-check HOST=<host>`.
4. Если таргета в Prometheus нет — перегенерируй таргеты и сделай reload.
5. Открой Grafana и проверь панели узла.

---

## 7) Трюблшутинг

- **Нет пинга по WireGuard:** проверь `wg show`, что peer добавлен на хабе, UDP порт `{{ wg_listen_port }}`, MTU `{{ wg_mtu }}`.
- **Нет метрик node_exporter:** проверь слушающий адрес (обычно `{{ wg_ip }}:9100`) и фаервол.
- **Таргет не появился:** убедись, что `wg_ip` задан в `host_vars`, и перерендери `targets/*.json`.
- **RU-probe/iperf:** проверь ssh-алиас в `~/.ssh/config`; если публичный IP не резолвится, шаблон подставит фолбэк.

---

## 8) Справка по make-целям

```text
add-node HOST=<h>        — «всё сразу»: WG + агенты (node+node_exporter+speedtest) → peers на хабе → hub bundle
add-node-check HOST=<h>  — проверки после онбординга (wg show, ping wg_ip, Prom targets)

wg-node HOST=<h>         — только WireGuard на узле
wg-hub                    — обновить peers на хабе
wg-check                  — проверка пинга wg_ip с хаба

node-bootstrap HOST=<h>   — node + node_exporter + speedtest_ookla
node-only HOST=<h>        — только роль node
node-exporter HOST=<h>    — только node_exporter
node-speedtest HOST=<h>   — только speedtest (Ookla)
```
