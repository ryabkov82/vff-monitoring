
# Роль `reality_e2e` (E2E проверка REALITY через sing-box)

Эта роль генерирует per-node конфиги **sing-box** и запускает периодический e2e‑пробник,
который делает HTTP‑запрос через локальный SOCKS‑прокси sing-box по REALITY‑профилю.
Результаты пишутся в **node_exporter textfile** метрику.

## Что делает роль

1. Создаёт каталог профилей: по умолчанию `${monitoring_root}/ru-probe/reality`
   (например, `/opt/vff-monitoring/ru-probe/reality`).  
2. Рендерит per-node конфиги:
   - `<name>.json` — конфиг sing-box (outbound vless+reality)
   - `<name>.env`  — переменные для systemd-шаблона (порт SOCKS и имя профиля)
3. Устанавливает скрипт `reality_e2e_probe.sh` и systemd юниты:
   - `reality-e2e@.service`, `reality-e2e@.timer` (по профилю `%i = <name>`)
4. Включает и стартует таймеры для включённых профилей.
5. **Prune**: отключает таймеры, удаляет JSON/ENV и `reality_e2e_*.tmp` для профилей,
   которых больше нет в `vpn_nodes` **или** у которых `reality.e2e_enabled: false`.

> Результирующие метрики: `/var/lib/node_exporter/textfile/reality_e2e.prom`  
> (временные: `reality_e2e_<name>.tmp`)

## Требования

- Установлен **sing-box** (рекомендуется роль `sing_box`):
  - бинарь доступен как `sing-box` в `$PATH`.
- На хабе (где крутится пробник): `curl`, `ss` (iproute2), systemd, node_exporter textfile‑директория.
- Ансибл‑инвентарь с описанием узлов в `vpn_nodes`.

## Переменные и данные

### Секреты (Ansible Vault, например `ansible/group_vars/hub/vault.yml`)
```yaml
reality_e2e_shared:
  uuid: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  public_key: "BASE64PUBKEYFROMSERVER"
  short_id: "ab12cd34"
  # sni (опционально): общий SNI, если не задан у узла
  # sni: "www.cloudflare.com"
```

### Дефолты роли (см. `roles/reality_e2e/defaults/main.yml`)
```yaml
reality_e2e_textfile_dir: "/var/lib/node_exporter/textfile"
monitoring_root: "/opt/vff-monitoring"
reality_e2e_cfg_dir: "{{ monitoring_root }}/ru-probe/reality"

# пользователь/группа под которыми храним файлы профилей
reality_e2e_user: "root"
reality_e2e_group: "node_exporter"

# поведение/проба
reality_e2e_defaults:
  socks_port: 1081
  flow: ""            # по умолчанию пусто; поле опускается в JSON
  log_level: "warn"
  http_test_url: "https://cp.cloudflare.com/generate_204"
  http_timeout: 8

# путь до скрипта
reality_e2e_script_path: "/usr/local/bin/reality_e2e_probe.sh"
```

### Инвентарь (`ansible/group_vars/all.yml`)
В массиве `vpn_nodes` включайте блок `reality` только там, где надо e2e‑проверка.

```yaml
vpn_nodes:
  - name: "nl-ams-2"
    instance: "10.77.0.3:9100"
    wg_ip: "10.77.0.3"
    role: "vpn"
    uplink_device: "ens3"
    uplink_speed_bps: 10000000000
    reality:
      e2e_enabled: true
      # server можно не задавать — определим автоматически:
      # порядок: reality.server → HostName из ~/.ssh/config по имени узла → ansible_host
      # server: "62.84.103.194"
      # sni (опц.) переопределит shared.sni
      # sni: "cache-ams-01.example.org"
      # socks_port, flow, log_level — опц., иначе берём дефолты роли
      # socks_port: 1081
      # flow: ""
      # log_level: "warn"
```

## Сборка конфигов и логика server/SNI

- `server` для профиля берётся по цепочке:
  1) `vpn_nodes[*].reality.server`  
  2) `HostName` из `~/.ssh/config` для `Host <name>`  
  3) `ansible_host` соответствующего хоста.
- `sni`: `vpn_nodes[*].reality.sni` → `reality_e2e_shared.sni` (если не задан — поле опускается).
- Пустой `flow` (по умолчанию) **не** попадает в JSON.

## Запуск роли и проверка

В `Makefile` есть цели (примеры):

```bash
# применить роль на хаб
make reality-e2e

# посмотреть статус таймеров/сервисов
make reality-e2e-status

# последние логи по конкретному профилю
make reality-e2e-logs NAME=nl-ams-2

# посмотреть метрики
make reality-e2e-metrics
```

### Что создаётся на хабе

- Конфиги: `{{ reality_e2e_cfg_dir }}/<name>.json` и `<name>.env`  
- Юниты: `/etc/systemd/system/reality-e2e@.service` и `reality-e2e@.timer`  
- Метрики: `{{ reality_e2e_textfile_dir }}/reality_e2e.prom` (+ `reality_e2e_<name>.tmp`)

### Метрики

```
reality_e2e_ok{name="<name>"} 0|1
reality_e2e_http_status{name="<name>"} <HTTP code>
reality_e2e_duration_ms{name="<name>"} <duration>
reality_e2e_last_run_ts{name="<name>"} <unix_ts>
```

## Частые проблемы

- **SSL_ERROR_SYSCALL** при curl через SOCKS: проверьте корректность `uuid/public_key/short_id/sni`, а также `flow` (по умолчанию пустой).  
- Таймер не запускается: проверьте `systemctl status 'reality-e2e@<name>.timer'` и журналы `journalctl -u 'reality-e2e@<name>.service' -n 200`.  
- Нет метрик: убедитесь, что текстовые `.tmp` собираются и что итоговый `reality_e2e.prom` обновляется.

## Безопасность

Все чувствительные значения (`uuid`, `public_key`, `short_id`, опционально общий `sni`) храните в **Ansible Vault** в `reality_e2e_shared`.
