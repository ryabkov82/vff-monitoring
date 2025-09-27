# Роль `docker`: памятка по эксплуатации

Эта памятка описывает, как использовать роль `ansible/roles/docker`: что она ставит, какие переменные ждёт и как ею пользоваться из Makefile.

---

## Где находится

- Роль: `ansible/roles/docker`
  - Задачи: `tasks/main.yml`
- Плейбук: `ansible/site.yml` — роль включается для группы `hub` с условием `when: docker_install | bool`.
- Makefile цель: `make docker`.

---

## Что делает роль (поток задач)

1. **Готовит систему к оф. репозиторию Docker (APT)**  
   Устанавливает пакеты: `ca-certificates`, `curl`, `gnupg`; создаёт `/etc/apt/keyrings`.

2. **Добавляет ключ и репозиторий Docker**  
   Качает GPG-ключ в `/etc/apt/keyrings/docker.asc`.  
   Добавляет `deb [arch=… signed-by=…] https://download.docker.com/linux/<distro> <release> stable`  
   (архитектура вычисляется автоматически из `ansible_facts.architecture`).

3. **Обновляет индекс APT** (только если репозиторий был добавлен/изменён).

4. **Ставит Docker Engine и Compose v2**  
   Пакеты: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`.

5. **Включает и запускает сервис Docker** (`systemctl enable --now docker`).

6. **Добавляет пользователей в группу `docker`**  
   Перебирает список `docker_users` и делает `append: true`. После этого пользователям нужен **re-login** (см. хэндлер).

---

## Теги

- `docker` — основной тег, включает все вышеуказанные шаги.

Примеры запуска:
```bash
# Установка/обновление Docker на хабе
make docker

# В составе полного прогона хаба
make hub-full
```

---

## Переменные (рекомендуется задать в `ansible/group_vars/hub/main.yml` или `group_vars/all.yml`)

```yaml
# Включать роль docker из site.yml (по умолчанию true/false в вашем окружении)
docker_install: true

# Добавить пользователей в группу docker (чтобы запускать без sudo)
docker_users: []        # пример: ["ubuntu", "sergey"]
```

> На Debian/Ubuntu роль сама определяет дистрибутив и релиз (`ansible_facts.distribution`, `ansible_facts.distribution_release`) и ставит официальный репозиторий Docker.

---

## Поддерживаемые архитектуры (APT repo arch mapping)

Роль автоматически маппит `ansible_facts.architecture` → `docker_apt_arch`:
- `x86_64`, `amd64` → `amd64`
- `aarch64`, `arm64` → `arm64`
- `armv7l`, `armhf` → `armhf`
- `ppc64le`, `ppc64el` → `ppc64el`

Если архитектура нестандартная — будет использовано исходное значение `ansible_facts.architecture | lower`.

---

## Частые вопросы (FAQ)

**1) Пользователь не может запускать `docker` без sudo**  
Добавьте его в `docker_users` и выполните роль. После этого нужен **re-login** пользователя (или `newgrp docker`).

**2) Compose v1 vs v2**  
Роль ставит **Compose v2** как плагин (`docker compose`). Старое `docker-compose` (v1) не устанавливается.

**3) Где бинарники/конфиги?**  
- Движок: пакеты Docker CE от официального репозитория.  
- Compose v2: плагин, интегрирован в `docker` CLI.  
- Конфиг Docker daemon (если нужно): `/etc/docker/daemon.json` — можете добавить отдельной задачей/шаблоном.

**4) Не Debian/Ubuntu**  
Роль выполняет шаги только при `ansible_facts.pkg_mgr == 'apt'`. Для других дистрибутивов добавьте ветки под `dnf/yum/zypper` и т.п. (пулл-реквест приветствуется).

**5) Прокси / офлайн окружение**  
Можно заранее добавить ключ и репозиторий из локального зеркала, либо положить пакеты на хост и установить их из локального каталога (расширьте роль при необходимости).

---

## Диагностика

```bash
# Проверить версию
docker --version
docker compose version

# Проверить сервис
systemctl status docker -n 50
journalctl -u docker -e

# Простая проверка run
docker run --rm hello-world
```

---

## Безопасность

- Члены группы `docker` имеют повышенные привилегии (по сути, root-эквивалент через сокет). Добавляйте пользователей осознанно.  
- При необходимости ограничьте доступ к сокету через systemd drop-in и/или используйте rootless Docker.

---

_Документ хранится в `docs/docker-role.md`._
