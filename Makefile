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
	
hub-all:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit hub $(ANSIBLE_FLAGS)

nodes:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) --limit vpn $(ANSIBLE_FLAGS)

all:
	$(ANSIBLE) -i $(INVENTORY) $(PLAY) $(ANSIBLE_FLAGS)
