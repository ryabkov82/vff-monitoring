# Роль `ru_probe` (RU iperf3 throughput probe)

Публикует метрики пропускной способности между **хабом (RU)** и **VPN‑узлами** через `iperf3`, пишет их в `node_exporter` textfile‑директорию на хабе и запускается по таймеру `systemd`.

---

## Что ставит и настраивает
- Скрипт: `/usr/local/bin/ru_iperf_probe.sh`
- Юниты:  
  - `ru-iperf-probe.service` — разовый запуск измерений  
  - `ru-iperf-probe.timer` — периодический запуск (по умолчанию раз в 6 часов)
- Директория для метрик: `/var/lib/node_exporter/textfile`
- Файл метрик: `/var/lib/node_exporter/textfile/ru_iperf.prom`

Скрипт идемпотентен, использует лок‑файл и таймауты, безопасно перезаписывает метрики (через временный файл `.*.prom.*`).

---

## Входные данные
Цели берутся из `vpn_nodes` (обычно в `ansible/group_vars/all.yml`):
```yaml
vpn_nodes:
  - name: nl-ams-1
    wg_ip: "10.77.0.2"
    iperf_port: 5201     # если не указать — возьмётся ru_probe_port_default
    role: vpn
```

Фильтрация по ролям (опционально): `ru_probe_target_roles: ["vpn"]` — если список пуст, берём все узлы.

---

## Переменные роли (defaults)
```yaml
# Где хранить метрики
node_exporter_textfile_dir: /var/lib/node_exporter/textfile

# Отбор целей
ru_probe_target_roles: []             # [] = все из vpn_nodes
ru_probe_port_default: 5201

# Прометеус для проверки занятости
ru_probe_prom_url:  "http://127.0.0.1:9090"
ru_probe_prom_user: ""                # если задан логин — будет basic‑auth
ru_probe_prom_pass: ""

# «Пропустить тест, если uplink занят»
ru_probe_skip_busy: true
ru_probe_busy_thresh: 0.50            # 0..1, пример: 0.5 = 50% занятости

# Таймауты/режим теста
ru_probe_duration: 10                 # секунд измерения iperf3
ru_probe_parallel: 1                  # параллельные потоки iperf3
ru_probe_connect_timeout: 2           # сек — TCP connect timeout
ru_probe_curl_timeout: 3              # сек — запрос к Prometheus
ru_probe_hard_timeout: 15             # сек — общий timeout на один запуск iperf3

# systemd таймер
ru_probe_timer_on_calendar: "Mon,Wed,Fri 03:02:55"
```

> Любую из переменных можно переопределить в `group_vars/hub/…`, `host_vars/…` или через `ANSIBLE_FLAGS='-e key=value'`.

---

## Публикуемые метрики
```
ru_probe_last_run_timestamp_seconds{name="<NAME>"} <unix_ts>
ru_probe_throughput_bps{name="<NAME>",direction="uplink|downlink",protocol="tcp"} <bps>
```
Если измерение пропущено из‑за занятости — строка `# skipped due to high utilization: <NAME>` в файле метрик.

---

## Команды Makefile (быстрый старт)
На хабе:
```bash
# Развернуть/обновить роль и таймер
make ru-probe

# Посмотреть статус
make ru-probe-status

# Запустить вручную сейчас
make ru-probe-run

# Логи последнего запуска
make ru-probe-logs

# Показать опубликованные метрики (если есть)
make ru-probe-metrics
```

---

## Как это работает
1. Роль рендерит `ru_iperf_probe.sh` из шаблона (цели — из `vpn_nodes`).
2. Перед каждым тестом функция `is_busy()` делает PromQL‑запрос:
   ```promql
   max_over_time(iface:utilization:ratio{name="<NAME>"}[1m])
   ```
   Если значение `> ru_probe_busy_thresh` и `ru_probe_skip_busy: true`, цель пропускается.
3. Для каждой цели выполняются два замера `iperf3` с таймаутами:
   - uplink: `iperf3 -c <WG_IP> -p <PORT> -t <DURATION>`
   - downlink: `iperf3 -c <WG_IP> -p <PORT> -t <DURATION> -R`
4. Результаты пишутся в `ru_iperf.prom` (атомарно).

---

## Зависимости и требования
- На **хабе**: `curl`, `jq`, `iperf3`, `bash`, `systemd`, доступ к Prometheus API по `ru_probe_prom_url`.
- На **узлах**: должен работать `iperf3` **сервер**, привязанный к WG‑IP и порту `iperf_port`.
  Мы ставим это ролью `node` (подзадача `node_iperf`), юнит `iperf3@PORT.service`.
  **Важно**: вендорный `iperf3.service` маскируется, чтобы не мешал instance‑юниту.

---

## Диагностика
- Ручной прогон с отладкой запроса занятости:
  ```bash
  sudo -E env IS_BUSY_DEBUG=1 /usr/local/bin/ru_iperf_probe.sh
  ```
- Проверка TCP‑доступности узла (на хабе):
  ```bash
  timeout 5 bash -lc 'echo > /dev/tcp/10.77.0.2/5201' && echo OK || echo FAIL
  ```
- Логи:
  ```bash
  journalctl -u ru-iperf-probe.service -n 200 --no-pager
  ```

Если зависает — чаще всего это отсутствие TCP‑доступа к `iperf3` на узле. В ролях `node/node_exporter` есть задачи, создающие `iperf3@PORT` и открывающие порт по WG (iptables или ufw).

---

## Интеграция в графики/алерты
- Добавьте панели с метриками `ru_probe_throughput_bps`.
- Можно сравнивать с `iface:utilization:ratio` и `node:bps:*` из `rec-network`.
- Для алертов: отсутствие свежего `ru_probe_last_run_timestamp_seconds` или нулевые значения длительное время.

---

## Обновление/удаление
Повторный запуск роли безопасно обновляет скрипт/юниты. Отключить таймер:
```bash
systemctl disable --now ru-iperf-probe.timer
```

---

## Частые вопросы
**Q:** Почему цель пропускается «due to high utilization», хотя графики пустые?  
**A:** Проверьте, что записываются `if_speed_bps` (или корректно считается `iface:utilization:ratio`), и что Prometheus отдаёт ненулевые данные в ответ на PromQL.

**Q:** Что делать, если измерение длится слишком долго?  
**A:** Уменьшите `ru_probe_duration` и/или увеличьте `ru_probe_hard_timeout`. Проверьте доступность порта `iperf_port` по WG.

**Q:** Можно ли запускать чаще?  
**A:** Да, измените `ru_probe_timer_on_calendar`, например `"*:0/30"` (каждые 30 минут).

---

## Ссылки
- `ansible/roles/ru_probe/tasks/main.yml` — задачи роли
- `ansible/roles/ru_probe/templates/ru_iperf_probe.sh.j2` — шаблон скрипта
- `ansible/roles/node/tasks/iperf.yml` — серверная часть `iperf3` на узлах
