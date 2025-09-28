ANSIBLE ?= ansible-playbook
INVENTORY ?= ansible/hosts.ini
PLAY ?= ansible/site.yml
ANSIBLE_FLAGS ?=

.PHONY: help ping nginx docker node-exporter-hub hub nodes all

help:
	@echo "targets: ping | nginx | docker | node-exporter-hub | hub | nodes | prom-rules | prom-rules-check | prom-health | grafana | grafana-dashboards | grafana-provisioning | grafana-health | all"
	@echo "usage: make nginx [ANSIBLE_FLAGS=--ask-vault-pass]"
	@echo "usage: make grafana-dashboards [ANSIBLE_FLAGS=\"-e grafana_dashboards_use_rsync=true\"]"
	@echo "usage: make prom-rules [ANSIBLE_FLAGS=--ask-vault-pass]"

ping:
	ansible -i $(INVENTORY) all -m ping

nginx:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags nginx $(ANSIBLE_FLAGS)

docker:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags docker $(ANSIBLE_FLAGS)

# Установить/обновить node_exporter только на хабе
node-exporter-hub:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags node_exporter $(ANSIBLE_FLAGS)

hub:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags hub $(ANSIBLE_FLAGS)

hub-full:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub $(ANSIBLE_FLAGS)

nodes:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn $(ANSIBLE_FLAGS)

all:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) $(ANSIBLE_FLAGS)

# где лежит compose на хабе
STACK := /opt/vff-monitoring/docker-compose.yml
TAIL ?= 200

.PHONY: status logs flogs logs-% flogs-%

# показать состояние контейнеров на хабе
status:
	ansible -i $(INVENTORY) hub -m shell \
	  -a 'docker compose -f $(STACK) ps' $(ANSIBLE_FLAGS)

# логи всех сервисов (хвост)
logs:
	ansible -i $(INVENTORY) hub -m shell \
	  -a 'docker compose -f $(STACK) logs --tail=$(TAIL)' $(ANSIBLE_FLAGS)

# live-логи всех сервисов (follow)
flogs:
	ansible -i $(INVENTORY) hub -m shell \
	  -a 'docker compose -f $(STACK) logs -f' $(ANSIBLE_FLAGS)

# логи конкретного сервиса, например: make logs-prometheus  или  make logs-grafana
logs-%:
	ansible -i $(INVENTORY) hub -m shell \
	  -a 'docker compose -f $(STACK) logs --tail=$(TAIL) $*' $(ANSIBLE_FLAGS)

# live-логи конкретного сервиса: make flogs-prometheus
flogs-%:
	ansible -i $(INVENTORY) hub -m shell \
	  -a 'docker compose -f $(STACK) logs -f $*' $(ANSIBLE_FLAGS)

.PHONY: wg-node wg-hub wg

# только узлы (роль wireguard_node)
wg-node:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags wg_node $(ANSIBLE_FLAGS)

# только хаб (роль wireguard_hub)
wg-hub:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags wg_hub $(ANSIBLE_FLAGS)

# всё WireGuard сразу (хаб + узлы)
wg:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags wg $(ANSIBLE_FLAGS)

wg-status:
	ansible -i $(INVENTORY) hub -m shell -a 'wg show'
	ansible -i $(INVENTORY) vpn -m shell -a 'wg show'

.PHONY: add-node

# Прокачать новый узел: WG на узле → обновить peers на хабе → перегенерить hub-конфиги и reload Prometheus
# Пример: make add-node HOST=nl-ams-2
add-node:
ifndef HOST
	$(error Usage: make add-node HOST=<hostname>)
endif
	@echo ">> [1/3] WireGuard on node: $(HOST)"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags wg_node --limit $(HOST) $(ANSIBLE_FLAGS)
	@echo ">> [2/3] Update peers on hub"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags wg_hub --limit hub $(ANSIBLE_FLAGS)
	@echo ">> [3/3] Render targets/rules & reload Prometheus"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags hub --limit hub $(ANSIBLE_FLAGS)
	@echo "✓ Done: node $(HOST) onboarded"

.PHONY: add-node-check add-node-all

# Проверить новый узел после онбординга:
# - wg show на хабе
# - ping WG-IP узла с хаба
# - наличие таргета в Prometheus
#
# Параметры:
#   HOST=<hostname>   — обязателен (имя из hosts.ini)
#   WG_IP=<ip>        — опционален; если не задан, попробуем прочитать var=wg_ip на самом хосте
#   NODE_PORT=9100    — порт node_exporter (по умолчанию 9100)
add-node-check:
ifndef HOST
	$(error Usage: make add-node-check HOST=<hostname> [WG_IP=<ip>] [NODE_PORT=9100])
endif
	@echo ">> Resolve WG_IP for $(HOST)"
	@WG_IP_TMP="$(WG_IP)"; \
	if [ -z "$$WG_IP_TMP" ]; then \
	  WG_IP_TMP=$$(ansible -i $(INVENTORY) $(HOST) -m debug -a "var=wg_ip" $(ANSIBLE_FLAGS) 2>/dev/null \
	    | sed -n 's/.*"wg_ip": "\(.*\)".*/\1/p' | tail -n1); \
	fi; \
	if [ -z "$$WG_IP_TMP" ]; then \
	  echo "!! Cannot resolve WG_IP for $(HOST). Pass WG_IP=<ip> or define wg_ip in inventory/group_vars."; exit 2; \
	fi; \
	echo "   WG_IP=$$WG_IP_TMP"; \
	PORT="$${NODE_PORT:-9100}"; \
	echo ">> [1/3] WireGuard status on hub"; \
	ansible -i $(INVENTORY) hub -m shell -a 'wg show' $(ANSIBLE_FLAGS) || true; \
	echo ">> [2/3] Ping from hub to $$WG_IP_TMP"; \
	ansible -i $(INVENTORY) hub -m shell -a 'ping -c1 -W1 '"$$WG_IP_TMP" $(ANSIBLE_FLAGS); \
	echo ">> [3/3] Prometheus target contains $$WG_IP_TMP"; \
	ansible -i $(INVENTORY) hub -m shell -a 'curl -s http://127.0.0.1:9090/api/v1/targets?state=active | grep -F '"$$WG_IP_TMP" $(ANSIBLE_FLAGS) || (echo "!! Target for $$WG_IP_TMP not found in Prometheus active targets"; exit 3); \
	echo "✓ Checks passed for $(HOST) (WG_IP=$$WG_IP_TMP, node_exporter port=$$PORT)"

# Полный онбординг: WG на узле -> peers на хабе -> обновить hub -> проверки
add-node-all:
ifndef HOST
	$(error Usage: make add-node-all HOST=<hostname> [WG_IP=<ip>] [NODE_PORT=9100])
endif
	@$(MAKE) add-node HOST=$(HOST) $(if $(ANSIBLE_FLAGS),ANSIBLE_FLAGS=$(ANSIBLE_FLAGS))
	@$(MAKE) add-node-check HOST=$(HOST) $(if $(WG_IP),WG_IP=$(WG_IP)) $(if $(NODE_PORT),NODE_PORT=$(NODE_PORT)) $(if $(ANSIBLE_FLAGS),ANSIBLE_FLAGS=$(ANSIBLE_FLAGS))

.PHONY: node-exporter node-exporter-vpn

# Установить/обновить node_exporter на одном узле
# Пример: make node-exporter HOST=nl-ams-1
node-exporter:
ifndef HOST
	$(error Usage: make node-exporter HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit $(HOST) --tags node_exporter $(ANSIBLE_FLAGS)

# Прогнать node_exporter на всей группе vpn
node-exporter-vpn:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags node_exporter $(ANSIBLE_FLAGS)

# --- Grafana shortcuts --------------------------------------------------------
.PHONY: grafana grafana-dashboards grafana-dashboards-check grafana-provisioning grafana-provisioning-check grafana-health

# Все графановские задачи (setup + provisioning + dashboards)
grafana:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana $(ANSIBLE_FLAGS)

# Только копирование/обновление дашбордов (hot-reload, без рестарта Grafana)
grafana-dashboards:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_dashboards $(ANSIBLE_FLAGS)

# Dry-run дашбордов с diff
grafana-dashboards-check:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_dashboards --check --diff $(ANSIBLE_FLAGS)

.PHONY: grafana-token

# Создание сервисного пользователя Grafana и загрузка токена в .env.grafana
# make grafana-token-ansible ANSIBLE_FLAGS='-e grafana_token_refresh=true'
grafana-token:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_token $(ANSIBLE_FLAGS)

.PHONY: grafana-pull

# Экспортировать дашборды через роль Ansible (все или по UID)
# Примеры:
#   make grafana-pull-ansible ANSIBLE_FLAGS='--tags grafana_export -e grafana_api_url=http://127.0.0.1:3000 -e grafana_admin_token=glsa_...'
#   make grafana-pull-ansible ANSIBLE_FLAGS='--tags grafana_export -e grafana_export_uids=["availability"]'
grafana-pull:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_export $(ANSIBLE_FLAGS)

# Только provisioning (datasources/dashboards.yml) — вызовет notify: Restart grafana
grafana-provisioning:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_provisioning $(ANSIBLE_FLAGS)

# Dry-run provisioning с diff
grafana-provisioning-check:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_provisioning --check --diff $(ANSIBLE_FLAGS)

# Быстрый healthcheck Grafana на хабе
grafana-health:
	ansible -i $(INVENTORY) hub -m shell \
	  -a 'curl -fsS http://127.0.0.1:$(grafana_port)/api/health >/dev/null && echo OK || (echo FAIL && exit 1)' $(ANSIBLE_FLAGS)

.PHONY: prom-rules prom-rules-check prom-health

# Применить только правила Prometheus (recording/alerts) + health-checks
# Теги берутся из roles/hub/tasks/prometheus.yml (prometheus) и health.yml (health)
prom-rules:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags "prometheus,health" $(ANSIBLE_FLAGS)

# Dry-run правил с diff + health (health выполнится «вхолостую» и покажет, что дернётся)
prom-rules-check:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags "prometheus,health" --check --diff $(ANSIBLE_FLAGS)

# Запустить только health-проверки (на случай, если рулы уже применены)
prom-health:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags health $(ANSIBLE_FLAGS)

# === RU iperf3 probe on hub ===
.PHONY: ru-probe ru-probe-run ru-probe-status ru-probe-logs ru-probe-metrics

# Где лежат метрики textfile на хабе
TEXTFILE_DIR ?= /var/lib/node_exporter/textfile
TAIL ?= 200

# Применить роль ru_probe на хабе (скрипт, юниты, таймер)
ru-probe:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags ru_probe $(ANSIBLE_FLAGS)

# Запустить разово измерение прямо сейчас
ru-probe-run:
	ansible -i $(INVENTORY) hub -m shell -a 'systemctl start ru-iperf-probe.service' $(ANSIBLE_FLAGS)

# Проверить состояние таймера/сервиса
ru-probe-status:
	ansible -i $(INVENTORY) hub -m shell -a 'systemctl status --no-pager ru-iperf-probe.timer' $(ANSIBLE_FLAGS)
	ansible -i $(INVENTORY) hub -m shell -a 'systemctl status --no-pager ru-iperf-probe.service' $(ANSIBLE_FLAGS) || true

# Логи последнего запуска
ru-probe-logs:
	ansible -i $(INVENTORY) hub -m shell -a 'journalctl -u ru-iperf-probe.service -n $(TAIL) --no-pager' $(ANSIBLE_FLAGS)

# Посмотреть опубликованные метрики (если файл уже создан)
ru-probe-metrics:
	ansible -i $(INVENTORY) hub -m shell -a 'test -f $(TEXTFILE_DIR)/ru_iperf.prom && cat $(TEXTFILE_DIR)/ru_iperf.prom || echo "no metrics yet"' $(ANSIBLE_FLAGS)

# === iperf3 on nodes ===
.PHONY: iperf-node iperf-vpn iperf-status iperf-logs

# Установить/обновить iperf3-сервер на ОДНОМ узле (нужен HOST=...)
# Пример: make iperf-node HOST=nl-ams-1
iperf-node:
ifndef HOST
	$(error Usage: make iperf-node HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit $(HOST) --tags node_iperf $(ANSIBLE_FLAGS)

# Установить/обновить iperf3-сервер на ВСЕЙ группе vpn
iperf-vpn:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags node_iperf $(ANSIBLE_FLAGS)

# Проверить статус сервиса на узле (порт можно переопределить: PORT=5201)
iperf-status:
ifndef HOST
	$(error Usage: make iperf-status HOST=<hostname> [PORT=5201])
endif
	@PORT="$${PORT:-5201}"; \
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'systemctl status --no-pager iperf3@'$$PORT $(ANSIBLE_FLAGS) || true

# Логи сервиса (хвост), можно задать TAIL=200 и PORT=5201
iperf-logs:
ifndef HOST
	$(error Usage: make iperf-logs HOST=<hostname> [PORT=5201] [TAIL=200])
endif
	@PORT="$${PORT:-5201}"; \
	T="$${TAIL:-200}"; \
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'journalctl -u iperf3@'$$PORT' -n '$$T' --no-pager' $(ANSIBLE_FLAGS) || true

.PHONY: node-if-speed node-if-speed-vpn

# Публикация if_speed_bps (textfile) на ОДНОМ узле
# Пример: make node-if-speed HOST=nl-ams-1
node-if-speed:
ifndef HOST
	$(error Usage: make node-if-speed HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit $(HOST) --tags node_if_speed $(ANSIBLE_FLAGS)

# Публикация if_speed_bps (textfile) на всей группе vpn
node-if-speed-vpn:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags node_if_speed $(ANSIBLE_FLAGS)
