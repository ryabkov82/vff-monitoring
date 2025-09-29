# Роль: `speedtest_ookla` (Ookla Speedtest → node_exporter textfile)

Экспортирует метрики скорости (Ookla Speedtest CLI) в `node_exporter` через textfile-коллектор, с плановым запуском через `systemd`-таймер.

> Поместите этот файл в репозиторий по пути `docs/speedtest_ookla.md` и добавьте ссылку на него в корневой `README.md`.

---

## Что делает

- Устанавливает зависимости: `jq`, `curl`.
- Ставит Ookla Speedtest CLI:
  - сначала пробует через официальный репозиторий (APT/YUM, если поддержан);
  - если недоступно — **fallback**: скачивает `tgz` и кладёт бинарь в нужный путь.
- Деплоит скрипт: `/usr/local/bin/speedtest_textfile_ookla.sh`.
- Ставит юниты:
  - `speedtest-textfile-ookla.service`
  - `speedtest-textfile-ookla.timer`
- Пишет метрики: `/var/lib/node_exporter/textfile/speedtest_ookla.prom`.

---

## Подключение роли

```yaml
# ansible/site.yml (пример)
- name: Hub (monitoring server)
  hosts: hub
  roles:
    - { role: speedtest_ookla, tags: [speedtest_ookla] }

- name: VPN nodes
  hosts: vpn
  roles:
    - { role: speedtest_ookla, tags: [speedtest_ookla] }
```
> Не вешайте тег `speedtest_ookla` на роль `node`, чтобы `--tags speedtest_ookla` не тянул весь плей узла.

---

## Основные переменные (defaults)

```yaml
# включение роли и установки
speedtest_enabled: true
speedtest_install: true

# пути
speedtest_textdir: /var/lib/node_exporter/textfile
node_speedtest_bin: /usr/bin/speedtest   # ВАЖНО: именно это имя используется скриптом и юнитами

# таймер
speedtest_timer_enabled: true
speedtest_oncalendar: "*-*-* 06,18:00:00"
speedtest_randomized_delay_sec: 900

# доступ к Prometheus API (для проверки «uplink занят»)
# Можно переиспользовать глобальные prom_* если заданы
speedtest_prom_url: "{{ prom_url  | default('https://prom.vpn-for-friends.com') }}"
speedtest_prom_user: "{{ prom_user | default('') }}"
speedtest_prom_pass: "{{ prom_pass | default('') }}"

# fallback (direct download), если репо недоступно
speedtest_version: "1.2.0"
# Архитектура (_speedtest_arch) выбирается автоматически в тасках: x86_64 / aarch64 / armhf / i386
speedtest_direct_url: "https://install.speedtest.net/app/cli/ookla-speedtest-{{ speedtest_version }}-linux-{{ _speedtest_arch }}.tgz"
```

> Если используется basic-auth Nginx на хабе, можно задать:
> ```yaml
> prom_user: "admin"
> prom_pass: "{{ hostvars[groups['hub'][0]].nginx_passwords.admin }}"
> ```

---

## Теги

- `speedtest_ookla` — основной функционал роли (скрипт/юниты/таймер/проверки).
- `speedtest_install` — **только** установка бинаря (repo или fallback).
  Обычно используем вместе: `--tags speedtest_ookla,speedtest_install`.

---

## Makefile (готовые таргеты)

```makefile
# Установка/обновление на конкретном узле (бинарь + скрипт + юниты + таймер)
node-speedtest:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit "$(HOST)" --tags speedtest_ookla,speedtest_install $(ANSIBLE_FLAGS)

# На все узлы группы vpn
node-speedtest-all:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags speedtest_ookla,speedtest_install $(ANSIBLE_FLAGS)

# Ад-хок операции (без задач в роли):
node-speedtest-run:
	ansible -i $(INVENTORY) "$(HOST)" -b -m systemd -a 'name=speedtest-textfile-ookla.service state=started' || true

node-speedtest-timer-enable:
	ansible -i $(INVENTORY) "$(HOST)" -b -m systemd -a 'name=speedtest-textfile-ookla.timer enabled=yes state=started'

node-speedtest-timer-disable:
	ansible -i $(INVENTORY) "$(HOST)" -b -m systemd -a 'name=speedtest-textfile-ookla.timer enabled=no state=stopped'

node-speedtest-status:
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell -a 'systemctl --no-pager --full status speedtest-textfile-ookla.service || true; echo; systemctl --no-pager --full status speedtest-textfile-ookla.timer || true'

node-speedtest-logs:
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell -a 'journalctl -u speedtest-textfile-ookla.service -n 200 --since "-2h" --no-pager || true'

node-speedtest-metrics:
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell -a 'f=/var/lib/node_exporter/textfile/speedtest_ookla.prom; test -f $$f && (echo "# $$f"; cat $$f) || echo "metrics file not found: $$f"'
```
Примеры:
```
make node-speedtest HOST=nl-ams-1
make node-speedtest-all
make node-speedtest-run HOST=nl-ams-1
make node-speedtest-logs HOST=nl-ams-1
```

---

## Как это работает

1. Роль проверяет наличие бинаря: `{{ node_speedtest_bin }} --version`.
2. Если бинарь уже есть — **установочные** шаги (repo/fallback) пропускаются → идемпотентность.
3. Repo-путь (APT/YUM) не фатален: если дистрибутив не поддержан, роль идёт по **direct download**.
4. Скрипт пишет метрики в `{{ speedtest_textdir }}/speedtest_ookla.prom`.

---

## Метрики (Prometheus)

Из скрипта:
- `vpn_speed_last_run_timestamp_seconds{name,method="ookla"}`
- `vpn_speed_ping_seconds{name,method="ookla",server,server_location,server_id}`
- `vpn_speed_jitter_seconds{...}`
- `vpn_speed_packet_loss_ratio{...}`
- `vpn_speed_download_bps{...}`
- `vpn_speed_upload_bps{...}`
- `vpn_speed_success{...}`
- `vpn_speed_result_url_info{...,url="https://..."}`

> Поле `NODE_NAME` в скрипте должно совпадать с `labels.name` в Prometheus-таргете узла (используется на дашбордах).

---

## Частые проблемы

- **Каждый прогон роли меняет состояние**  
  Убедитесь, что установочные задачи выполняются только при `not speedtest_present` и что везде используется `node_speedtest_bin`.
- **Репозиторий Ookla не поддерживает distro**  
  Задайте `speedtest_version` и `speedtest_direct_url` (см. выше) — включится скачивание `tgz`.
- **Нет метрик / пустой файл**  
  Проверьте логи сервиса (`make node-speedtest-logs`) и значения `SPEEDTEST_BIN`, `PROM_URL/USER/PASS`.
- **UFW/файрволл мешает**  
  Убедитесь, что исходящие DNS/HTTP(S) разрешены, а также что не блокируется доступ к выбранному speedtest-серверу.

---

## Линт и стиль

- Для задач с `block`: порядок ключей — **name → when → tags → block**.
- В `name` шаблоны Jinja допускаются **только в конце строки**:
  ```yaml
  - name: Speedtest | Install binary (direct) → {{ node_speedtest_bin }}
  ```
- Не используем `systemctl` внутри роли (ansible-lint). Для статуса/логов используйте ад-хоки в Makefile.

---

## Безопасность

- Для запросов к Prometheus используйте read-only пользователя (basic-auth через Nginx на хабе) и ограничьте доступ по IP (WG-подсеть).
- Не разворачивайте на узлах админские креды.
