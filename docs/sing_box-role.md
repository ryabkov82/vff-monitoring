
# Роль `sing_box` — установка бинаря sing-box

Роль устанавливает (или обновляет) CLI‑бинарь **sing-box** на хост (обычно — на хабе мониторинга), с идемпотентной проверкой версии. Используется, например, ролью `reality_e2e` для E2E‑проб через REALITY.

## Что делает роль

- Проверяет наличие бинаря (`sing-box version`) и парсит установленную версию.
- Сравнивает с желаемой версией (`sing_box_version`).
- Если бинаря нет или версия отличается — скачивает архив с GitHub‑релиза, распаковывает и устанавливает бинарь.
- При совпадении версий ничего не делает (идемпотентно).

## Требования

- Linux x86_64 (amd64).
- Утилиты на целевой машине: `curl`, `tar`.
- Доступ к GitHub Releases (или свой HTTP‑зеркало архива).

## Переменные роли

| Переменная                | Назначение                               | По умолчанию                |
|---------------------------|------------------------------------------|-----------------------------|
| `sing_box_version`        | Желаемая версия `X.Y.Z` (можно `vX.Y.Z`) | `"1.12.8"`                  |
| `sing_box_arch`           | Архитектура тарболла                     | `"linux-amd64"`             |
| `sing_box_bin_path`       | Путь установки бинаря                    | `"/usr/local/bin/sing-box"` |
| `sing_box_tarball_url`    | URL архива; если не задан — соберётся из версии/архитектуры | auto     |
| `sing_box_tarball_sha256` | Контрольная сумма архива (рекомендуется для прод) | `""`               |

> Если указать `sing_box_tarball_sha256`, роль проверит SHA256 архива.

## Теги

- `sing_box` — основной тег роли.

## Запуск

Через `Makefile` (на группу `hub`):

```bash
make sing-box
```

Напрямую Ansible:

```bash
ansible-playbook -i ansible/hosts.ini ansible/site.yml   --limit hub --tags sing_box
```

Апдейт до другой версии:

```bash
ansible-playbook -i ansible/hosts.ini ansible/site.yml   --limit hub --tags sing_box   -e sing_box_version=1.12.9
```

С проверкой SHA256:

```bash
ansible-playbook -i ansible/hosts.ini ansible/site.yml   --limit hub --tags sing_box   -e sing_box_version=1.12.9   -e sing_box_tarball_sha256='<sha256-сумма>'
```

## Как это работает (коротко)

1. Роль выполняет `sing-box version` и забирает сырой вывод.
2. Безопасно извлекает версию вида `X.Y.Z` (через `grep -oE`).
3. Нормализует желаемую версию (срезает префикс `v`).
4. Если `installed != desired` — скачивает, распаковывает и кладёт бинарь в `sing_box_bin_path`.
5. Повторный запуск при совпадении версий ничего не меняет.

## Трюблшутинг

- **Роль всегда «что‑то делает»** — посмотри отладку:
  `installed_norm:` и `desired_norm:`. Если `installed_norm` пусто, скорее всего `sing-box` не найден по пути (`sing_box_bin_path`) или нет прав.

- **Нет доступа к GitHub** — укажи свой `sing_box_tarball_url` + `sing_box_tarball_sha256` на локальный HTTP.

- **Версия не меняется** — проверь, что переменная `sing_box_version` реально применяется (временный `debug: var=sing_box_version`), и что бинарь не перезаписывается внешними процессами.

## Связанные роли

- `reality_e2e` — использует установленный `sing-box` для E2E‑проб через REALITY.
