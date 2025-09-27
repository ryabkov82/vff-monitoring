# Добавление нового VPN-узла в мониторинг (WireGuard + Prometheus)

Этот runbook описывает **минимально достаточные шаги** для включения нового узла (vpn-сервера) в частную сеть мониторинга и Prometheus.

> **Предпосылки**
> - Хаб уже развёрнут (wg_iface=`wgmon0`, порт `51820/udp` по умолчанию).
> - С контроллера Ansible есть SSH-доступ на хаб и на новый узел.
> - Node exporter на узле разворачивается ролью `node` (см. шаг 6).

---

## 1) Добавить хост в инвентори

`ansible/hosts.ini`:
```ini
[vpn]
<hostname> ansible_host=<public_ip_or_dns>
```

> `<hostname>` должен **строго совпадать** с `name` в `vpn_nodes` (см. шаг 2).

---

## 2) Описать WG- и Prometheus-адреса узла

`ansible/group_vars/all.yml` → список `vpn_nodes`:
```yaml
vpn_nodes:
  - name: <hostname>            # ровно как в hosts.ini
    wg_ip: "10.77.0.X"          # уникальный /32 в подсети WG (например 10.77.0.13)
    instance: "10.77.0.X:9100"  # адрес таргета node_exporter для Prometheus
    role: "vpn"
```

> Подсеть по умолчанию: `10.77.0.0/24`. Хаб: `10.77.0.1`.

---

## 3) Поднять WireGuard на узле

Сгенерируются ключи, создастся `/etc/wireguard/wgmon0.conf`, интерфейс поднимется.
```bash
make wg-node --quiet ANSIBLE_FLAGS="--limit <hostname>"
```

---

## 4) Добавить пир на хабе

Хаб автоматически подтянет pubkey узла (через delegated slurp) и перерендерит свой конфиг.
```bash
make wg-hub --quiet
```

---

## 5) Обновить цели Prometheus и применить reload

Роль `hub` перерендерит `targets/nodes.json` и отправит `/-/reload` в Prometheus.
```bash
make hub --quiet ANSIBLE_FLAGS="--tags hub"
```

---

## 6) (Если нужно) Установить node_exporter на узле

Если роль `node` не ставилась ранее:
```bash
make nodes --quiet ANSIBLE_FLAGS="--limit <hostname>"
```

---

## 7) Проверка

### WireGuard
На хабе:
```bash
ansible -i ansible/hosts.ini hub -m shell -a 'wg show'
ansible -i ansible/hosts.ini hub -m shell -a "ping -c1 -W1 $(awk -F'\"' '/\"name\": \"<hostname>\"/{f=1} f&&/wg_ip/{print $4; exit}' ansible/group_vars/all.yml)"
```

Ожидаем: у пира `<hostname>` есть свежий `latest handshake`, счётчики `transfer` > 0.

### Prometheus targets
```bash
ansible -i ansible/hosts.ini hub -m shell   -a 'curl -s http://127.0.0.1:9090/api/v1/targets?state=active | jq -r ".data.activeTargets[].labels.instance" | sort'
```
Ожидаем: в списке есть `10.77.0.X:9100` (новый узел).

---

## Частые проблемы и решения

- **Нет рукопожатия (handshake)**  
  - Проверь `hub_public_endpoint` (IP/DNS), проброс `udp/51820` до хаба.
  - На хабе порт слушается: `ss -lun | grep 51820`.
  - Ключи не перепутаны? `wg showconf wgmon0`.
  - `AllowedIPs`: на хабе — `/32` WG-IP узла; на узле — `/32` WG-IP хаба.
  - MTU: по умолчанию 1280. Если меняли — верните/подберите.

- **Prometheus видит DOWN**  
  - `cat /opt/vff-monitoring/prometheus/targets/nodes.json` — должен быть WG-адрес.
  - `curl -s http://127.0.0.1:9090/-/ready` → `200`.
  - node_exporter слушает на узле и доступен через WG: `curl 10.77.0.X:9100/metrics` с хаба.

---

## Быстрые команды (подсказка)

```bash
# Все WG-состояния разом
make wg-status

# Логи Only prometheus/grafana/alertmanager/blackbox
make logs-prometheus
make logs-grafana
make logs-alertmanager
make logs-blackbox

# Перегенерировать только конфиги роли hub и reload Prometheus
make hub --quiet ANSIBLE_FLAGS="--tags hub"
```

---

## Справочно: параметры по умолчанию

- Интерфейс: `wgmon0`
- Порт хаба (UDP): `51821`
- Подсеть WG: `10.77.0.0/24`
- MTU: `1280`
- Prometheus targets кладутся в: `/opt/vff-monitoring/prometheus/targets/nodes.json`
