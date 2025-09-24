# vff-monitoring (Ansible-first)

## Быстрый старт
1) Заполни `ansible/hosts.ini`, `group_vars/all.yml`, `group_vars/hub.yml` (пароли в vault).
2) На хабе должен быть Docker + Compose v2.
3) Запуск:
```bash
cd ansible
make hub      # поднимет Prometheus/Alertmanager/Grafana/Blackbox
make nodes    # разложит скрипты на узлах
