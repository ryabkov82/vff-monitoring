ANSIBLE ?= ansible-playbook
INVENTORY ?= ansible/hosts.ini
PLAY ?= ansible/site.yml
ANSIBLE_FLAGS ?=

.PHONY: help ping nginx hub nodes all

help:
	@echo "targets: ping | nginx | hub | nodes | all"
	@echo "usage: make nginx [ANSIBLE_FLAGS=--ask-vault-pass]"

ping:
	ansible -i $(INVENTORY) all -m ping

nginx:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags nginx $(ANSIBLE_FLAGS)

docker:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags docker $(ANSIBLE_FLAGS)

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
