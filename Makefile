# === БАЗОВЫЕ НАСТРОЙКИ ===
# Можно переопределить переменными окружения или в командной строке:
#   make hub ANSIBLE_FLAGS=--ask-vault-pass
ANSIBLE        ?= ansible-playbook
INVENTORY      ?= ansible/hosts.ini

PLAY_SITE ?= ansible/site.yml
PLAY_HUB  ?= ansible/playbooks/hub.yml
PLAY_VPN  ?= ansible/playbooks/vpn.yml
PLAY_RUZ  ?= ansible/playbooks/ru_zondes.yml

ifeq ($(SCOPE),hub)
  PLAY := $(PLAY_HUB)
else ifeq ($(SCOPE),vpn)
  PLAY := $(PLAY_VPN)
else ifeq ($(SCOPE),ru)
  PLAY := $(PLAY_RUZ)
else
  PLAY ?= $(PLAY_SITE)
endif

ANSIBLE_FLAGS  ?=

# Где лежит docker compose стек на хабе.
STACK          ?= /opt/vff-monitoring/docker-compose.yml
# Где хранятся textfile-метрики node_exporter на хабе.
TEXTFILE_DIR   ?= /var/lib/node_exporter/textfile
# Сколько строк хвоста логов показывать по умолчанию.
TAIL           ?= 200

# ---------------------------
# СПРАВКА
# ---------------------------
.PHONY: help
help: ## Показать справку и примеры использования
	@echo "Make targets (vff-monitoring)\n"
	@grep -E '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'
	@echo "\nПримеры запуска:"
	@echo "  make nginx ANSIBLE_FLAGS=--ask-vault-pass"
	@echo '  make grafana-dashboards ANSIBLE_FLAGS="-e grafana_dashboards_use_rsync=true"'
	@echo "  make prom-rules ANSIBLE_FLAGS=--ask-vault-pass"
	@echo "  make add-node HOST=nl-ams-2"
	@echo "  make node-bootstrap HOST=nl-ams-2"

# ---------------------------
# БАЗОВЫЕ ОПЕРАЦИИ
# ---------------------------
.PHONY: ping nginx docker node-exporter-hub hub hub-full nodes all

ping: ## Проверка доступности всех хостов (ansible ping)
	@# Пример: make ping
	ansible -i $(INVENTORY) all -m ping

nginx: ## Настроить Nginx на хабе (reverse-proxy, certs, htpasswd)
	@# Пример: make nginx ANSIBLE_FLAGS=--ask-vault-pass
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags nginx $(ANSIBLE_FLAGS)

docker: ## Установить/обновить Docker/Compose на хабе
	@# Пример: make docker
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags docker $(ANSIBLE_FLAGS)

node-exporter-hub: ## Установить/обновить node_exporter только на хабе
	@# Пример: make node-exporter-hub
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags node_exporter $(ANSIBLE_FLAGS)

hub-compose: ## Применить роль 'compose' (рендер docker-compose) на хабе
	@# Пример: make hub-compose
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags compose,health $(ANSIBLE_FLAGS)

hub: ## Применить роль 'hub' (рендер targets/rules и пр.) на хабе
	@# Пример: make hub
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags hub $(ANSIBLE_FLAGS)

hub-full: ## Запустить весь плей для группы hub (все роли для хаба)
	@# Пример: make hub-full
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub $(ANSIBLE_FLAGS)

nodes: ## Запустить весь плей для группы vpn (все роли для узлов)
	@# Пример: make nodes
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn $(ANSIBLE_FLAGS)

all: ## Выполнить site.yml на всех хостах
	@# Пример: make all
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) $(ANSIBLE_FLAGS)

# ---------------------------
# HUB: ВСПОМОГАТЕЛЬНЫЕ КОМАНДЫ ДЛЯ docker-compose
# ---------------------------
.PHONY: status logs flogs logs-% flogs-%

status: ## Показать состояние контейнеров (docker compose ps) на хабе
	@# Пример: make status
	ansible -i $(INVENTORY) hub -m shell -a 'docker compose -f $(STACK) ps' $(ANSIBLE_FLAGS)

logs: ## Показать хвост логов всех сервисов (TAIL=200 по умолчанию)
	@# Пример: make logs TAIL=500
	ansible -i $(INVENTORY) hub -m shell -a 'docker compose -f $(STACK) logs --tail=$(TAIL)' $(ANSIBLE_FLAGS)

flogs: ## Следить за логами всех сервисов (-f)
	@# Пример: make flogs
	ansible -i $(INVENTORY) hub -m shell -a 'docker compose -f $(STACK) logs -f' $(ANSIBLE_FLAGS)

logs-%: ## Показать хвост логов конкретного сервиса (по имени)
	@# Пример: make logs-prometheus  или  make logs-grafana
	ansible -i $(INVENTORY) hub -m shell -a 'docker compose -f $(STACK) logs --tail=$(TAIL) $*' $(ANSIBLE_FLAGS)

flogs-%: ## Следить за логами конкретного сервиса (по имени)
	@# Пример: make flogs-prometheus
	ansible -i $(INVENTORY) hub -m shell -a 'docker compose -f $(STACK) logs -f $*' $(ANSIBLE_FLAGS)

# ---------------------------
# WIREGUARD: УЗЛЫ + ХАБ
# ---------------------------
.PHONY: wg-node wg-hub wg wg-status wg-show-% add-node add-node-check add-node-all

wg-node: ## Применить только роль wireguard_node на всех vpn-узлах (tag: wg_node)
	@# Пример: make wg-node
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags wg_node $(ANSIBLE_FLAGS)

wg-hub: ## Применить только роль wireguard_hub на хабе (tag: wg_hub)
	@# Пример: make wg-hub
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags wg_hub $(ANSIBLE_FLAGS)

wg: ## Применить все задачи WireGuard (хаб + узлы) по тегу wg
	@# Пример: make wg
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags wg $(ANSIBLE_FLAGS)

wg-status: ## Показать 'wg show' на хабе и на узлах
	@# Пример: make wg-status
	ansible -i $(INVENTORY) hub -m shell -a 'wg show' $(ANSIBLE_FLAGS) || true
	ansible -i $(INVENTORY) vpn -m shell -a 'wg show' $(ANSIBLE_FLAGS) || true

wg-show-%: ## Показать 'wg show' на конкретном хосте (по имени)
	@# Пример: make wg-show-nl-ams-1
	ansible -i $(INVENTORY) $* -m shell -a 'wg show' $(ANSIBLE_FLAGS) || true

add-node: ## Онбординг новой ноды: WG + агенты (node+node_exporter+speedtest) на HOST -> wg_hub на хабе -> hub bundle
	@# Пример: make add-node HOST=nl-ams-2
ifndef HOST
	$(error Usage: make add-node HOST=<hostname>)
endif
	@echo ">> [1/4] WireGuard on node: $(HOST)"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags wg_node --limit $(HOST) $(ANSIBLE_FLAGS)

	@echo ">> [2/4] Monitoring agents on node (node + node_exporter + speedtest_ookla): $(HOST)"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags node,node_exporter,speedtest_ookla --limit $(HOST) $(ANSIBLE_FLAGS)

	@echo ">> [3/4] Update peers on hub"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags wg_hub --limit hub $(ANSIBLE_FLAGS)

	@echo ">> [4/4] Apply hub bundle (render targets/rules, etc.)"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags "hub,ru_probe,reality_e2e" --limit hub $(ANSIBLE_FLAGS)

	@echo "✓ Done: node $(HOST) onboarded (WG + agents installed, hub updated)"

add-node-check: ## Проверить узел после онбординга (wg show, ping wg_ip, наличие таргета в Prometheus)
	@# Пример: make add-node-check HOST=nl-ams-2  или  make add-node-check HOST=nl-ams-2 WG_IP=10.77.0.22
ifndef HOST
	$(error Usage: make add-node-check HOST=<hostname> [WG_IP=<ip>] [NODE_PORT=9100])
endif
	@echo ">> Resolve WG_IP for $(HOST)"
	@set -e; \
	WG_IP_TMP="$(WG_IP)"; \
	if [ -z "$$WG_IP_TMP" ]; then \
	  WG_IP_TMP=$$(ansible -i $(INVENTORY) $(HOST) -m debug \
	    -a 'msg={{ (hostvars[inventory_hostname].wg_ip | default(ansible_host)) | string }}' \
	    $(ANSIBLE_FLAGS) 2>/dev/null \
	    | sed -n 's/.*"msg": "\(.*\)".*/\1/p' | tail -n1); \
	fi; \
	if [ -z "$$WG_IP_TMP" ] || [ "$$WG_IP_TMP" = "VARIABLE IS NOT DEFINED!" ]; then \
	  echo "!! Cannot resolve WG_IP for $(HOST)."; \
	  echo "   Pass WG_IP=<ip> or define host_vars/$(HOST).yml with wg_ip."; \
	  exit 2; \
	fi; \
	# срежем возможную маску /xx
	WG_IP_TMP=$$(echo "$$WG_IP_TMP" | sed 's,/.*$$,,'); \
	echo "   WG_IP=$$WG_IP_TMP"; \
	PORT="$${NODE_PORT:-9100}"; \
	echo ">> [1/3] WireGuard status on hub"; \
	ansible -i $(INVENTORY) hub -m shell -a 'wg show' $(ANSIBLE_FLAGS) || true; \
	echo ">> [2/3] Ping from hub to $$WG_IP_TMP"; \
	ansible -i $(INVENTORY) hub -m shell -a 'ping -c1 -W1 '$$WG_IP_TMP $(ANSIBLE_FLAGS); \
	echo ">> [3/3] Prometheus target contains $$WG_IP_TMP"; \
	ansible -i $(INVENTORY) hub -m shell -a 'curl -s http://127.0.0.1:9090/api/v1/targets?state=active | grep -F '$$WG_IP_TMP $(ANSIBLE_FLAGS) \
	  || (echo "!! Target for $$WG_IP_TMP not found in Prometheus active targets"; exit 3); \
	echo "✓ Checks passed for $(HOST) (WG_IP=$$WG_IP_TMP, node_exporter port=$$PORT)"

add-node-all: ## Полный онбординг: add-node + add-node-check
	@# Пример: make add-node-all HOST=nl-ams-2
ifndef HOST
	$(error Usage: make add-node-all HOST=<hostname> [WG_IP=<ip>] [NODE_PORT=9100])
endif
	@$(MAKE) add-node HOST=$(HOST) $(if $(ANSIBLE_FLAGS),ANSIBLE_FLAGS=$(ANSIBLE_FLAGS))
	@$(MAKE) add-node-check HOST=$(HOST) $(if $(WG_IP),WG_IP=$(WG_IP)) $(if $(NODE_PORT),NODE_PORT=$(NODE_PORT)) $(if $(ANSIBLE_FLAGS),ANSIBLE_FLAGS=$(ANSIBLE_FLAGS))

# ---------------------------
# МОНІТОРИНГОВЫЕ АГЕНТЫ (узлы)
# ---------------------------
.PHONY: node-bootstrap node-only node-exporter node-exporter-vpn node-if-speed node-if-speed-vpn

node-bootstrap: ## Полный bootstrap на HOST: node (iperf3+if_speed) + node_exporter + speedtest_ookla
	@# Пример: make node-bootstrap HOST=nl-ams-2
ifndef HOST
	$(error Usage: make node-bootstrap HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit $(HOST) --tags node,node_exporter,speedtest_ookla $(ANSIBLE_FLAGS)

node-only: ## Только роль 'node' (iperf3 + if_speed) на HOST
	@# Пример: make node-only HOST=nl-ams-2
ifndef HOST
	$(error Usage: make node-only HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit $(HOST) --tags node $(ANSIBLE_FLAGS)

node-exporter: ## Установить/обновить node_exporter на HOST
	@# Пример: make node-exporter HOST=nl-ams-2
ifndef HOST
	$(error Usage: make node-exporter HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit $(HOST) --tags node_exporter $(ANSIBLE_FLAGS)

node-exporter-vpn: ## Установить/обновить node_exporter на всей группе vpn
	@# Пример: make node-exporter-vpn
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags node_exporter $(ANSIBLE_FLAGS)

node-if-speed: ## Опубликовать/обновить if_speed_bps (textfile) на HOST
	@# Пример: make node-if-speed HOST=nl-ams-2
ifndef HOST
	$(error Usage: make node-if-speed HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit $(HOST) --tags node_if_speed $(ANSIBLE_FLAGS)

node-if-speed-vpn: ## Опубликовать/обновить if_speed_bps на всей группе vpn
	@# Пример: make node-if-speed-vpn
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags node_if_speed $(ANSIBLE_FLAGS)

# --- public iperf3 (direct) ---
node-iperf-public: ## Установить/обновить public iperf3 на HOST (direct; UFW ограничит до RU-зондов)
	@# Пример: make node-iperf-public HOST=nl-ams-2
ifndef HOST
	$(error Usage: make node-iperf-public HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit $(HOST) --tags iperf3_public $(ANSIBLE_FLAGS)

node-iperf-public-vpn: ## Установить/обновить public iperf3 на всей группе vpn
	@# Пример: make node-iperf-public-vpn
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags iperf3_public $(ANSIBLE_FLAGS)

node-iperf-public-check: ## Проверка: юнит, порт, iptables, логи
	@# Пример: make node-iperf-public-check HOST=nl-ams-1 [PORT=5202]
ifndef HOST
	$(error Usage: make node-iperf-public-check HOST=<hostname> [PORT=5202])
endif
	@PORT=$${PORT:-5202}; \
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'systemctl is-active iperf3-public@'$$PORT $(ANSIBLE_FLAGS); \
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'systemctl is-enabled iperf3-public@'$$PORT $(ANSIBLE_FLAGS) || true; \
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'ss -ltnp | grep ":'$$PORT' " || true' $(ANSIBLE_FLAGS); \
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'iptables -S | egrep "INPUT|5201|'$$PORT'" || true' $(ANSIBLE_FLAGS); \
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'journalctl -u iperf3-public@'$$PORT' -n 50 --no-pager || true' $(ANSIBLE_FLAGS)

# ---------------------------
# IPERF3: проверки на узле
# ---------------------------
.PHONY: iperf-status iperf-logs

# Проверить статус сервиса на узле (порт можно переопределить: PORT=5201)
# Пример: make iperf-status HOST=nl-ams-2
# Пример: make iperf-status HOST=nl-ams-2 PORT=5202
iperf-status:
ifndef HOST
	$(error Usage: make iperf-status HOST=<hostname> [PORT=5201])
endif
	@PORT="$${PORT:-5201}"; \
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'systemctl status --no-pager iperf3@'$$PORT $(ANSIBLE_FLAGS) || true

# Показать логи сервиса (хвост), можно задать TAIL=200 и PORT=5201
# Пример: make iperf-logs HOST=nl-ams-2
# Пример: make iperf-logs HOST=nl-ams-2 PORT=5202 TAIL=400
iperf-logs:
ifndef HOST
	$(error Usage: make iperf-logs HOST=<hostname> [PORT=5201] [TAIL=200])
endif
	@PORT="$${PORT:-5201}"; \
	T="$${TAIL:-200}"; \
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'journalctl -u iperf3@'$$PORT' -n '$$T' --no-pager' $(ANSIBLE_FLAGS) || true

# === REALITY (XRAY/Marzban) health exporter ==================================
# Управление раскаткой и проверками скрипта reality_svc_health.sh.
# Что делает:
#   - reality-install / reality-install-vpn: раскатывает скрипт и systemd unit/timer
#     через роль ansible/roles/node (тег node_reality):
#       * /usr/local/bin/reality_svc_health.sh
#       * /etc/default/reality_svc
#       * /etc/systemd/system/reality-svc.service (+ timer) и включает таймер
#   - reality-run: разово запускает oneshot-сервис
#   - reality-status: показывает статус сервиса и таймера
#   - reality-logs: выводит логи последнего запуска (TAIL=200 по умолчанию)
#   - reality-metrics: показывает опубликованные метрики из textfile каталога
#
# Примеры:
#   make reality-install HOST=nl-ams-2
#   make reality-install-vpn
#   make reality-run HOST=nl-ams-2
#   make reality-status HOST=nl-ams-2
#   make reality-logs HOST=nl-ams-2 TAIL=300
#   make reality-metrics HOST=nl-ams-2
#
# Требования:
#   - Роль ansible/roles/node должна содержать tasks/templates для reality (тег node_reality)
#   - На узлах установлен node_exporter с включённым textfile collector
#   - Переменная node_reality_enabled=true (глобально или в host_vars/group_vars)

.PHONY: reality-install reality-install-vpn reality-run reality-status reality-logs reality-metrics

# Установка/обновление только на ОДНОМ узле
reality-install:
ifndef HOST
	$(error Usage: make reality-install HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit "$(HOST)" --tags node_reality $(ANSIBLE_FLAGS)

# Установка/обновление на ВСЕЙ группе vpn
reality-install-vpn:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags node_reality $(ANSIBLE_FLAGS)

# Разовый запуск проверки (oneshot)
reality-run:
ifndef HOST
	$(error Usage: make reality-run HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) "$(HOST)" -b -m systemd \
	  -a 'name=reality-svc.service state=started' $(ANSIBLE_FLAGS) || true

# Статус сервиса и таймера
reality-status:
ifndef HOST
	$(error Usage: make reality-status HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell \
	  -a 'systemctl --no-pager --full status reality-svc.service || true; echo; systemctl --no-pager --full status reality-svc.timer || true' $(ANSIBLE_FLAGS)

# Логи последнего запуска (TAIL=200 по умолчанию)
reality-logs:
ifndef HOST
	$(error Usage: make reality-logs HOST=<hostname> [TAIL=200] [ANSIBLE_FLAGS="..."])
endif
	@T="$${TAIL:-200}"; \
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell \
	  -a 'journalctl -u reality-svc.service -n '"$$T"' --since "-2h" --no-pager || true' $(ANSIBLE_FLAGS)

# Показать опубликованные метрики (если файл уже создан)
reality-metrics:
ifndef HOST
	$(error Usage: make reality-metrics HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell \
	  -a 'f=/var/lib/node_exporter/textfile/reality_svc.prom; test -f $$f && (echo "# $$f"; cat $$f) || echo "metrics file not found: $$f"' $(ANSIBLE_FLAGS)

# === WireGuard textfile exporter (wg_textfile.sh) =============================
# Раскатка и управление метриками WireGuard в textfile.
#   wg-metrics-install / wg-metrics-install-vpn — установка/обновление (тег node_wg_metrics)
#   wg-metrics-run     — разовый запуск oneshot-сервиса
#   wg-metrics-status  — статус сервиса/таймера
#   wg-metrics-logs    — логи сервиса (TAIL=200)
#   wg-metrics-metrics — вывод файла метрик
#
# Примеры:
#   make wg-metrics-install HOST=nl-ams-2
#   make wg-metrics-install-vpn
#   make wg-metrics-run HOST=nl-ams-2
#   make wg-metrics-status HOST=nl-ams-2
#   make wg-metrics-logs HOST=nl-ams-2 TAIL=300
#   make wg-metrics-metrics HOST=nl-ams-2

.PHONY: wg-metrics-install wg-metrics-install-vpn wg-metrics-run wg-metrics-status wg-metrics-logs wg-metrics-metrics

wg-metrics-install:
ifndef HOST
	$(error Usage: make wg-metrics-install HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit "$(HOST)" --tags node_wg_metrics $(ANSIBLE_FLAGS)

wg-metrics-install-vpn:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags node_wg_metrics $(ANSIBLE_FLAGS)

wg-metrics-run:
ifndef HOST
	$(error Usage: make wg-metrics-run HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) "$(HOST)" -b -m systemd \
	  -a 'name=wg-metrics.service state=started' $(ANSIBLE_FLAGS) || true

wg-metrics-status:
ifndef HOST
	$(error Usage: make wg-metrics-status HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell \
	  -a 'systemctl --no-pager --full status wg-metrics.service || true; echo; systemctl --no-pager --full status wg-metrics.timer || true' $(ANSIBLE_FLAGS)

wg-metrics-logs:
ifndef HOST
	$(error Usage: make wg-metrics-logs HOST=<hostname> [TAIL=200] [ANSIBLE_FLAGS="..."])
endif
	@T="$${TAIL:-200}"; \
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell \
	  -a 'journalctl -u wg-metrics.service -n '"$$T"' --since "-2h" --no-pager || true' $(ANSIBLE_FLAGS)

wg-metrics-metrics:
ifndef HOST
	$(error Usage: make wg-metrics-metrics HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell \
	  -a 'f=/var/lib/node_exporter/textfile/wg.prom; test -f $$f && (echo "# $$f"; cat $$f) || echo "metrics file not found: $$f"' $(ANSIBLE_FLAGS)

# ---------------------------
# SPEEDTEST (Ookla): помощники
# ---------------------------
.PHONY: node-speedtest node-speedtest-all node-speedtest-run node-speedtest-timer-enable node-speedtest-timer-disable node-speedtest-status node-speedtest-logs node-speedtest-metrics

node-speedtest: ## Установить/обновить speedtest на HOST (скрипт, юниты, таймер, бинарь)
	@# Пример: make node-speedtest HOST=nl-ams-2
ifndef HOST
	$(error Usage: make node-speedtest HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit "$(HOST)" --tags speedtest_ookla,speedtest_install $(ANSIBLE_FLAGS)

node-speedtest-all: ## Установить/обновить speedtest на всех vpn-узлах
	@# Пример: make node-speedtest-all
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn --tags speedtest_ookla,speedtest_install $(ANSIBLE_FLAGS)

node-speedtest-run: ## Разовый запуск сервиса speedtest на HOST
	@# Пример: make node-speedtest-run HOST=nl-ams-2
	ansible -i $(INVENTORY) "$(HOST)" -b -m systemd -a 'name=speedtest-textfile-ookla.service state=started' || true

node-speedtest-timer-enable: ## Включить и запустить таймер speedtest на HOST
	@# Пример: make node-speedtest-timer-enable HOST=nl-ams-2
	ansible -i $(INVENTORY) "$(HOST)" -b -m systemd -a 'name=speedtest-textfile-ookla.timer enabled=yes state=started'

node-speedtest-timer-disable: ## Выключить и остановить таймер speedtest на HOST
	@# Пример: make node-speedtest-timer-disable HOST=nl-ams-2
	ansible -i $(INVENTORY) "$(HOST)" -b -m systemd -a 'name=speedtest-textfile-ookla.timer enabled=no state=stopped'

node-speedtest-status: ## Показать статусы service/timer speedtest на HOST
	@# Пример: make node-speedtest-status HOST=nl-ams-2
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell -a 'systemctl --no-pager --full status speedtest-textfile-ookla.service || true; echo; systemctl --no-pager --full status speedtest-textfile-ookla.timer || true'

node-speedtest-logs: ## Показать логи speedtest за последние 2 часа на HOST
	@# Пример: make node-speedtest-logs HOST=nl-ams-2 TAIL=400
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell -a 'journalctl -u speedtest-textfile-ookla.service -n 200 --since "-2h" --no-pager || true'

node-speedtest-metrics: ## Показать экспортируемые textfile-метрики speedtest на HOST
	@# Пример: make node-speedtest-metrics HOST=nl-ams-2
	ansible -i $(INVENTORY) "$(HOST)" -b -m shell -a 'f=$(TEXTFILE_DIR)/speedtest_ookla.prom; test -f $$f && (echo "# $$f"; cat $$f) || echo "metrics file not found: $$f"'

# ---------------------------
# GRAFANA
# ---------------------------
.PHONY: grafana grafana-dashboards grafana-dashboards-check grafana-provisioning grafana-provisioning-check grafana-health grafana-token grafana-pull

grafana: ## Полная настройка Grafana на хабе (provisioning + dashboards)
	@# Пример: make grafana
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana $(ANSIBLE_FLAGS)

grafana-dashboards: ## Скопировать/обновить дашборды (горячо, без рестарта)
	@# Пример: make grafana-dashboards ANSIBLE_FLAGS='-e grafana_dashboards_use_rsync=true'
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_dashboards $(ANSIBLE_FLAGS)

grafana-dashboards-check: ## Dry-run дашбордов с diff
	@# Пример: make grafana-dashboards-check
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_dashboards --check --diff $(ANSIBLE_FLAGS)

grafana-token: ## Создать сервисного пользователя и записать токен в .env.grafana
	@# Пример: make grafana-token ANSIBLE_FLAGS='-e grafana_token_refresh=true'
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_token $(ANSIBLE_FLAGS)

grafana-pull: ## Экспортировать дашборды через роль (можно ограничить UID'ами)
	@# Примеры:
	@#   make grafana-pull ANSIBLE_FLAGS='--tags grafana_export -e grafana_api_url=http://127.0.0.1:3000 -e grafana_admin_token=glsa_...'
	@#   make grafana-pull ANSIBLE_FLAGS='--tags grafana_export -e grafana_export_uids=["availability"]'
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_export $(ANSIBLE_FLAGS)

grafana-provisioning: ## Применить provisioning (datasources/dashboards.yml), вызовет рестарт Grafana
	@# Пример: make grafana-provisioning
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_provisioning $(ANSIBLE_FLAGS)

grafana-provisioning-check: ## Dry-run provisioning с diff
	@# Пример: make grafana-provisioning-check
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags grafana_provisioning --check --diff $(ANSIBLE_FLAGS)

grafana-health: ## Простой healthcheck Grafana (http://127.0.0.1:3000/api/health)
	@# Пример: make grafana-health
	ansible -i $(INVENTORY) hub -m shell -a 'curl -fsS http://127.0.0.1:3000/api/health >/dev/null && echo OK || (echo FAIL && exit 1)' $(ANSIBLE_FLAGS)

# ---------------------------
# PROMETHEUS
# ---------------------------
.PHONY: prom-rules prom-rules-check prom-health prom-reload

prom-rules: ## Применить только правила Prometheus (recording/alerts) + health
	@# Пример: make prom-rules
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags "prometheus,health" $(ANSIBLE_FLAGS)

prom-rules-check: ## Dry-run правил с diff + health
	@# Пример: make prom-rules-check
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags "prometheus,health" --check --diff $(ANSIBLE_FLAGS)

prom-health: ## Выполнить только health-проверки стека мониторинга
	@# Пример: make prom-health
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags health $(ANSIBLE_FLAGS)

prom-reload: ## Горячая перезагрузка Prometheus (нужен --web.enable-lifecycle)
	@# Пример: make prom-reload
	curl -fsS -X POST http://127.0.0.1:9090/-/reload || true

# -------------------------------------------------
# Полная настройка RU-зондов (wg_node + node_exporter + ru_probe)
# -------------------------------------------------
PLAY_RUZ ?= ansible/playbooks/ru_zondes.yml

.PHONY: ru-zondes-setup ru-zondes-setup-host

ru-zondes-setup-host: ## Все роли на одном зонде HOST, затем обновить iptables на VPN-нoded, WG-хаб и Prometheus targets/rules
	@# Пример: make ru-zondes-setup-host HOST=monitoring-hub
ifndef HOST
	$(error Usage: make ru-zondes-setup-host HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	@echo ">> [1/4] RU zonde on $(HOST)"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY_RUZ) --limit $(HOST) $(ANSIBLE_FLAGS) && \
	echo ">> [2/4] Refresh iptables on VPN nodes for public iperf" && \
	$(MAKE) node-iperf-public-vpn && \
	echo ">> [3/4] Update WG peers on hub" && \
	$(MAKE) wg-hub && \
	echo ">> [4/4] Render Prometheus targets/rules" && \
	$(MAKE) prom-rules

ru-zondes-setup: ## Все роли на всей группе ru_zondes, затем обновить iptables на VPN-нoded, WG-хаб и Prometheus targets/rules
	@# Пример: make ru-zondes-setup
	@echo ">> [1/4] RU zondes on group ru_zondes"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY_RUZ) --limit ru_zondes $(ANSIBLE_FLAGS) && \
	echo ">> [2/4] Refresh iptables on VPN nodes for public iperf" && \
	$(MAKE) node-iperf-public-vpn && \
	echo ">> [3/4] Update WG peers on hub" && \
	$(MAKE) wg-hub && \
	echo ">> [4/4] Render Prometheus targets/rules" && \
	$(MAKE) prom-rules

# -------------------------------------------------
# RU IPERF3 ПРОБА (ru_zondes)
# -------------------------------------------------
.PHONY: ru-probe ru-probe-zondes ru-probe-run ru-probe-run-zondes \
        ru-probe-status ru-probe-status-zondes ru-probe-logs ru-probe-logs-zondes \
        ru-probe-metrics ru-probe-metrics-zondes

ru-probe: ## Применить роль ru_probe на HOST (зонде)
	@# Пример: make ru-probe HOST=ru-msk-1
ifndef HOST
	$(error Usage: make ru-probe HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY_RUZ) --limit $(HOST) --tags ru_probe $(ANSIBLE_FLAGS)

ru-probe-zondes: ## Применить роль ru_probe на всей группе ru_zondes
	@# Пример: make ru-probe-zondes
	$(ANSIBLE) -i $(INVENTORY) $(PLAY_RUZ) --limit ru_zondes --tags ru_probe $(ANSIBLE_FLAGS)

# Разовый запуск сервиса пробы
ru-probe-run: ## Запустить RU iperf3 probe сейчас на HOST
	@# Пример: make ru-probe-run HOST=ru-msk-1
ifndef HOST
	$(error Usage: make ru-probe-run HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'systemctl start ru-iperf-probe.service' $(ANSIBLE_FLAGS)

ru-probe-run-zondes: ## Запустить RU iperf3 probe сейчас на всей группе ru_zondes
	@# Пример: make ru-probe-run-zondes
	ansible -i $(INVENTORY) ru_zondes -m shell -a 'systemctl start ru-iperf-probe.service' $(ANSIBLE_FLAGS)

# Статусы
ru-probe-status: ## Показать статус таймера/сервиса RU iperf3 probe на HOST
	@# Пример: make ru-probe-status HOST=ru-msk-1
ifndef HOST
	$(error Usage: make ru-probe-status HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'systemctl status --no-pager ru-iperf-probe.timer' $(ANSIBLE_FLAGS)
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'systemctl status --no-pager ru-iperf-probe.service' $(ANSIBLE_FLAGS) || true

ru-probe-status-zondes: ## Показать статус таймера/сервиса на всей группе ru_zondes
	@# Пример: make ru-probe-status-zondes
	ansible -i $(INVENTORY) ru_zondes -m shell -a 'systemctl status --no-pager ru-iperf-probe.timer' $(ANSIBLE_FLAGS)
	ansible -i $(INVENTORY) ru_zondes -m shell -a 'systemctl status --no-pager ru-iperf-probe.service' $(ANSIBLE_FLAGS) || true

# Логи
ru-probe-logs: ## Показать логи последнего запуска RU iperf3 probe на HOST (TAIL=200)
	@# Пример: make ru-probe-logs HOST=ru-msk-1 [TAIL=500]
ifndef HOST
	$(error Usage: make ru-probe-logs HOST=<hostname> [TAIL=200] [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'journalctl -u ru-iperf-probe.service -n $(TAIL) --no-pager' $(ANSIBLE_FLAGS)

ru-probe-logs-zondes: ## Показать логи RU iperf3 probe на всей группе ru_zondes (TAIL=200)
	@# Пример: make ru-probe-logs-zondes [TAIL=500]
	ansible -i $(INVENTORY) ru_zondes -m shell -a 'journalctl -u ru-iperf-probe.service -n $(TAIL) --no-pager' $(ANSIBLE_FLAGS)

# Опубликованные метрики
ru-probe-metrics: ## Показать опубликованные метрики RU iperf3 на HOST
	@# Пример: make ru-probe-metrics HOST=ru-msk-1
ifndef HOST
	$(error Usage: make ru-probe-metrics HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	ansible -i $(INVENTORY) $(HOST) -m shell -a 'f=$${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}/ru_iperf.prom; test -f $$f && (echo "# $$f"; cat $$f) || echo "no metrics yet"' $(ANSIBLE_FLAGS)

ru-probe-metrics-zondes: ## Показать опубликованные метрики RU iperf3 на всей группе ru_zondes
	@# Пример: make ru-probe-metrics-zondes
	ansible -i $(INVENTORY) ru_zondes -m shell -a 'f=$${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}/ru_iperf.prom; test -f $$f && (echo "# $$f"; cat $$f) || echo "no metrics yet"' $(ANSIBLE_FLAGS)

# -----------------------------------------
# ДЕИНСТАЛЛЯЦИЯ RU-ПРОБЫ НА ЗОНДАХ
# -----------------------------------------
PLAY_RUZ ?= ansible/playbooks/ru_zondes.yml

.PHONY: ru-probe-uninstall-host ru-zonde-finalize ru-zonde-remove-host

ru-probe-uninstall-host: ## Шаг 1: деинсталляция ru_probe на HOST (останавливает тесты)
	@# Пример: make ru-probe-uninstall-host HOST=ru-msk-1
ifndef HOST
	$(error Usage: make ru-probe-uninstall-host HOST=<hostname>)
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY_RUZ) --limit $(HOST) --tags ru_probe -e ru_probe_state=absent $(ANSIBLE_FLAGS)

ru-zonde-finalize: ## Шаг 3: пересборка WG на хабе и правил/таргетов Prometheus
	@# Пример: make ru-zonde-finalize
	$(MAKE) wg-hub && $(MAKE) prom-rules

ru-zonde-remove-host: ## Комфортная обёртка: шаг1 -> ПАУЗА (удалите хост вручную) -> шаг3 (по ru-zonde-finalize)
	@# Пример: make ru-zonde-remove-host HOST=ru-msk-1
ifndef HOST
	$(error Usage: make ru-zonde-remove-host HOST=<hostname>)
endif
	@echo ">> [1/3] Uninstall ru_probe on $(HOST)"
	$(MAKE) ru-probe-uninstall-host HOST=$(HOST) $(if $(ANSIBLE_FLAGS),ANSIBLE_FLAGS="$(ANSIBLE_FLAGS)",)
	@echo ">> [2/3] Now remove $(HOST) from [ru_zondes] in ansible/hosts.ini and from ru_zondes in ansible/group_vars/all.yml"
	@echo ">> [3/3] When done, run:"
	@echo "          make ru-zonde-finalize"


# === sing-box (утилита для REALITY E2E) ======================================
.PHONY: sing-box sing-box-version

## Установить/обновить sing-box на ХАБЕ (роль sing_box)
## Пример: make sing-box [ANSIBLE_FLAGS=--ask-vault-pass]
sing-box:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags sing_box $(ANSIBLE_FLAGS)

## Проверить версию sing-box на ХАБЕ
## Пример: make sing-box-version
sing-box-version:
	ansible -i $(INVENTORY) hub -m shell \
	  -a 'sing-box version || /usr/local/bin/sing-box version || echo "sing-box not found"' $(ANSIBLE_FLAGS)

# === REALITY E2E (sing-box) на хабе =================================================
.PHONY: reality-e2e reality-e2e-profiles reality-e2e-run reality-e2e-status reality-e2e-logs reality-e2e-metrics reality-e2e-timer-start reality-e2e-timer-stop

# Полный прогон роли reality_e2e на хабе:
# - рендер профилей из vpn_nodes (JSON+ENV)
# - установка скрипта и systemd unit'ов
# - enable+start таймеров для профилей с e2e_enabled=true
# Пример: make reality-e2e [ANSIBLE_FLAGS=--ask-vault-pass]
reality-e2e:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags reality_e2e $(ANSIBLE_FLAGS)

# Только рендер профилей (без выката юнитов/таймеров)
# Пример: make reality-e2e-profiles
reality-e2e-profiles:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags reality_e2e_profiles $(ANSIBLE_FLAGS)

# Разовый запуск проверки для профиля (service @profile)
# Пример: make reality-e2e-run PROFILE=nl-ams-2
reality-e2e-run:
ifndef PROFILE
	$(error Usage: make reality-e2e-run PROFILE=<profile_name>)
endif
	ansible -i $(INVENTORY) hub -m systemd -a 'name=reality-e2e@$(PROFILE).service state=started' $(ANSIBLE_FLAGS)

# Статус сервиса+таймера для профиля
# Пример: make reality-e2e-status PROFILE=nl-ams-2
reality-e2e-status:
ifndef PROFILE
	$(error Usage: make reality-e2e-status PROFILE=<profile_name>)
endif
	ansible -i $(INVENTORY) hub -m shell -a 'systemctl --no-pager --full status reality-e2e@$(PROFILE).service || true; echo; systemctl --no-pager --full status reality-e2e@$(PROFILE).timer || true' $(ANSIBLE_FLAGS)

# Логи последнего запуска сервиса
# Пример: make reality-e2e-logs PROFILE=nl-ams-2 [TAIL=200]
reality-e2e-logs:
ifndef PROFILE
	$(error Usage: make reality-e2e-logs PROFILE=<profile_name> [TAIL=200])
endif
	@T="$${TAIL:-200}"; \
	ansible -i $(INVENTORY) hub -m shell -a 'journalctl -u reality-e2e@$(PROFILE).service -n '$$T' --no-pager || true' $(ANSIBLE_FLAGS)

# Посмотреть агрегированные метрики textfile
# Пример: make reality-e2e-metrics
reality-e2e-metrics:
	ansible -i $(INVENTORY) hub -m shell -a 'f=/var/lib/node_exporter/textfile/reality_e2e.prom; test -f $$f && (echo "# $$f"; sed -n "1,120p" $$f) || echo "metrics file not found: $$f"' $(ANSIBLE_FLAGS)

# Управление таймером для конкретного профиля (вкл/выкл)
# Примеры: make reality-e2e-timer-start PROFILE=nl-ams-2
#          make reality-e2e-timer-stop  PROFILE=nl-ams-2
reality-e2e-timer-start:
ifndef PROFILE
	$(error Usage: make reality-e2e-timer-start PROFILE=<profile_name>)
endif
	ansible -i $(INVENTORY) hub -m systemd -a 'name=reality-e2e@$(PROFILE).timer enabled=yes state=started' $(ANSIBLE_FLAGS)

reality-e2e-timer-stop:
ifndef PROFILE
	$(error Usage: make reality-e2e-timer-stop PROFILE=<profile_name>)
endif
	ansible -i $(INVENTORY) hub -m systemd -a 'name=reality-e2e@$(PROFILE).timer enabled=no state=stopped' $(ANSIBLE_FLAGS)


.PHONY: iperf-wg-disable-host iperf-wg-disable-vpn

iperf-wg-disable-host: ## Остановить/отключить iperf3@WG_PORT на HOST (WG-экземпляр)
	@# Пример: make iperf-wg-disable-host HOST=nl-ams-1
ifndef HOST
	$(error Usage: make iperf-wg-disable-host HOST=<hostname> [ANSIBLE_FLAGS="..."])
endif
	$(ANSIBLE) -i $(INVENTORY) $(PLAY_VPN) --limit $(HOST) --tags iperf3_cleanup $(ANSIBLE_FLAGS)

iperf-wg-disable-vpn: ## Остановить/отключить iperf3@WG_PORT на всей группе vpn
	@# Пример: make iperf-wg-disable-vpn
	$(ANSIBLE) -i $(INVENTORY) $(PLAY_VPN) --limit vpn --tags iperf3_cleanup $(ANSIBLE_FLAGS)

# === backups =================================================

# Плейбук для бэкап-клиентов
PLAY_BACKUP := ansible/playbooks/backup.yml

add-backup-client: ## Онбординг backup-клиента: WG + node_exporter -> wg_hub -> Prometheus (HOST обязателен)
	@# Пример: make add-backup-client HOST=nl-ams-2
ifndef HOST
	$(error Usage: make add-backup-client HOST=<hostname>)
endif
	@echo ">> [1/3] WireGuard + node_exporter on backup client: $(HOST)"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY_BACKUP) --limit $(HOST) $(ANSIBLE_FLAGS)

	@echo ">> [2/3] Update peers on hub"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags wg_hub --limit hub $(ANSIBLE_FLAGS)

	@echo ">> [3/3] Apply hub bundle (Prometheus targets/rules + health)"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags "prometheus,health" $(ANSIBLE_FLAGS)

	@echo "✓ Done: backup client $(HOST) onboarded"

add-backup-all: ## Онбординг всех backup-клиентов группой: WG + node_exporter -> wg_hub -> Prometheus
	@echo ">> [1/3] WireGuard + node_exporter on ALL backup clients"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY_BACKUP) $(ANSIBLE_FLAGS)

	@echo ">> [2/3] Update peers on hub"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --tags wg_hub --limit hub $(ANSIBLE_FLAGS)

	@echo ">> [3/3] Apply hub bundle (Prometheus targets/rules + health)"
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub --tags "prometheus,health" $(ANSIBLE_FLAGS)

	@echo "✓ Done: all backup clients onboarded"
