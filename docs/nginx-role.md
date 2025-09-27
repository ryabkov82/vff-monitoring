# Роль `nginx`: памятка по эксплуатации

Эта памятка описывает, как использовать роль `ansible/roles/nginx`: какие переменные она ждёт, что именно делает, и какие есть типовые команды/кейсы.

---

## Где находится

- Роль: `ansible/roles/nginx`
  - Основные задачи: `tasks/main.yml`
  - Шаблоны:  
    - `templates/nginx.conf.d.http.j2` — дополнительные директивы в `http {}` (например, rate limit zone)  
    - `templates/site.conf.j2` — generic vhost-шаблон для проксирования backend’ов (Prometheus/Grafana/Alertmanager)
- Плейбук: `ansible/site.yml` — роль включена для группы `hub`.
- Makefile цель: `make nginx`.

---

## Теги

- `nginx` — основной тег роли (установка, htpasswd, vhosts, enable, reload, сервис)
- `certs` — подцель для блока выдачи сертификатов Certbot (если `nginx_cert_method: certbot`)

Примеры запуска:
```bash
# Весь Nginx на хабе
make nginx

# Только certbot (если выбран метод certbot)
ansible-playbook -i ansible/hosts.ini ansible/site.yml --limit hub --tags certs
```

---

## Переменные (рекомендуемые значения в `group_vars/hub/main.yml`)

Домены и backend-порты:
```yaml
prom_domain:    "prom-new.vpn-for-friends.com"
grafana_domain: "grafana-new.vpn-for-friends.com"
alerts_domain:  "alerts-new.vpn-for-friends.com"

prometheus_port:    9090
grafana_port:       3000
alertmanager_port:  9093
```

Каталоги конфигураций:
```yaml
nginx_sites_available_dir: /etc/nginx/sites-available
nginx_sites_enabled_dir:   /etc/nginx/sites-enabled
```

Basic auth (опционально; пароли лучше хранить в vault):
```yaml
nginx_basic_auth_enabled: true
nginx_users:
  - user: "admin"
# Если хотите задать пароли в vault/vars:
# nginx_passwords:
#   admin: "*****"
```

(опц.) Allow-list (CIDR/адреса) — если хотите ограничить доступ на уровне Nginx:
```yaml
# Пустой список = не включаем allow-list в шаблоне
nginx_allow_list: []     # пример: ["203.0.113.4", "198.51.100.0/24"]
```

Сертификаты (два подхода):

**1) Готовые файлы (existing):**
```yaml
nginx_cert_method: "existing"
nginx_certs:
  prom:
    fullchain: "/etc/letsencrypt/live/prom-new.vpn-for-friends.com/fullchain.pem"
    privkey:   "/etc/letsencrypt/live/prom-new.vpn-for-friends.com/privkey.pem"
  grafana:
    fullchain: "/etc/letsencrypt/live/grafana-new.vpn-for-friends.com/fullchain.pem"
    privkey:   "/etc/letsencrypt/live/grafana-new.vpn-for-friends.com/privkey.pem"
  alerts:
    fullchain: "/etc/letsencrypt/live/alerts-new.vpn-for-friends.com/fullchain.pem"
    privkey:   "/etc/letsencrypt/live/alerts-new.vpn-for-friends.com/privkey.pem"
```

**2) Certbot (http-01 на webroot `/var/www/html`):**
```yaml
nginx_cert_method: "certbot"
certbot_email: "admin@vpn-for-friends.com"
certbot_staging: false    # true — для тестового запуска
```

---

## Что делает роль (поток)

1. **Установка пакетов** `nginx`, `apache2-utils` (для htpasswd), `ssl-cert`.  
2. **Готовит каталоги**: `conf.d`, `sites-available`, `sites-enabled`, webroot `/var/www/html`.  
3. **HTTP extras**: рендер `nginx.conf.d.http.j2` в `/etc/nginx/conf.d/00-http-extras.conf` (например, зона rate limit).  
4. **Basic auth** (если `nginx_basic_auth_enabled: true`):
   - создаёт `/etc/nginx/.htpasswd` (если нет);
   - добавляет/обновляет пользователей из `nginx_users` (пароли — из `nginx_passwords` либо inline).
5. **Готовит vhosts** для: Prometheus, Grafana, Alertmanager — на основе единого `site.conf.j2` (проксирование на `127.0.0.1:<порт>`, возможно блокирование admin-путей через regex).  
6. **Включает сайты** симлинками из `sites-available` → `sites-enabled`.  
7. **Сертификаты**:
   - если `nginx_cert_method: certbot` — устанавливает Certbot и запускает выдачу/обновление сертификатов для всех доменов;
   - если `existing` — ожидает файлы сертификатов по указанным путям.
8. **Запускает Nginx** и включает автозапуск; изменения конфигов вызывают `notify: Reload nginx` (нужен хэндлер).

---

## Makefile: основные команды

```bash
# Полный прогон роли Nginx на хабе
make nginx

# Весь стек на хабе (Docker + Nginx + Hub + пр.)
make hub-full

# Только Docker-роль (если нужно переустановить Docker/Compose)
make docker
```

---

## Типичные ситуации и проверка

**Проверить конфиг и перезагрузить вручную:**
```bash
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl status nginx -n 50
journalctl -u nginx -e
```

**401 на публичном домене Grafana, а API-токен не работает:**  
Это basic-auth на Nginx. Для API-запросов добавляйте `-u admin:...` **или** ходите на локальный порт Grafana через SSH-туннель (`127.0.0.1:3000`).

**502/504 на backend’ах:**  
Проверьте, что backends слушают на `127.0.0.1:<порт>` (стек Docker поднят, контейнеры живы), и что в vhost-шаблоне правильные `proxy_pass`.

**Сертификаты не выпустились Certbot’ом:**  
Проверьте, что домены резолвятся на внешний IP хаба, и URL `http://<host>/.well-known/acme-challenge/...` доступен из интернета (временнo отключите HTTPS-редирект в шаблоне, если он есть в кастомной логике).

---

## Безопасность

- Файл `.htpasswd` лежит в `/etc/nginx/.htpasswd` (права `0640`, группа `www-data`).  
- Админ-пути backend’ов блокируются regular expressions в шаблоне `site.conf.j2` (см. переменную `block_admin_paths` в `tasks/main.yml`).  
- При использовании allow-list ограничивайте доступ к vhost'ам по IP/подсетям.  
- Для Certbot включайте `certbot_staging: true` при тестовой выдаче, чтобы не упереться в лимиты ACME.

---

## Расширение и кастомизация

- Добавьте переменные для rate limiting/headers в `nginx.conf.d.http.j2` и параметризуйте их в `group_vars/hub`.  
- Расширьте `vhosts` в `tasks/main.yml`, если нужны дополнительные сервисы (по аналогии с prom/grafana/alerts).  
- Для специфичных локаций используйте include-файлы в `conf.d` и подключайте их из vhost-шаблона.

---

_Документ хранится в `docs/nginx-role.md`._
