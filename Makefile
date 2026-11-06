.DEFAULT_GOAL := help
SHELL := /bin/bash

help:  ## Lista los comandos
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

deps:  ## Instala las colecciones de Ansible
	ansible-galaxy collection install -r requirements.yml

ping:  ## Comprueba que llegas al equipo
	ansible lab -m ping

check:  ## Enseña qué cambiaría, sin tocar nada
	ansible-playbook site.yml --check --diff

apply:  ## Aplica la configuración
	ansible-playbook site.yml

lint:  ## Pasa los linters
	ansible-lint
	yamllint .

verify:  ## Prueba de idempotencia: la segunda pasada no debe cambiar nada
	ansible-playbook site.yml > /tmp/homelab-run1.log
	ansible-playbook site.yml | tee /tmp/homelab-run2.log
	@if grep -qE 'changed=[1-9]' /tmp/homelab-run2.log; then \
		echo "FALLO: la segunda pasada ha cambiado cosas. No es idempotente."; \
		exit 1; \
	else \
		echo "OK: idempotente."; \
	fi

vault-edit:  ## Edita los secretos cifrados
	ansible-vault edit inventory/group_vars/vault.yml

.PHONY: help deps ping check apply lint verify vault-edit
