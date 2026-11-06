.DEFAULT_GOAL := help
SHELL := /bin/bash
TF := cd terraform &&
AN := cd ansible &&

help:  ## Lista los comandos
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

deps:  ## Instala colecciones de Ansible y proveedores de OpenTofu
	$(AN) ansible-galaxy collection install -r requirements.yml
	$(TF) tofu init

discover:  ## Mira qué hay en el hipervisor, sin tocar nada
	$(AN) ansible-playbook pve.yml --tags discover --check

pve:  ## Prepara el hipervisor (plantilla, token, Tailscale)
	$(AN) ansible-playbook pve.yml

plan:  ## Enseña qué VMs se crearían
	$(TF) tofu plan

vms:  ## Crea las VMs y regenera el inventario de Ansible
	$(TF) tofu apply
	$(TF) tofu output -raw ansible_inventory > ../ansible/inventory/vms.yml
	@echo "Inventario actualizado en ansible/inventory/vms.yml"

inventory:  ## Solo regenera el inventario desde el estado de OpenTofu
	$(TF) tofu output -raw ansible_inventory > ../ansible/inventory/vms.yml

ping:  ## Comprueba que llegas a todas las VMs
	$(AN) ansible all -i inventory/vms.yml -m ping

check:  ## Enseña qué cambiaría en las VMs, sin tocar nada
	$(AN) ansible-playbook site.yml --check --diff

config:  ## Configura las VMs y levanta el clúster
	$(AN) ansible-playbook site.yml

nodes:  ## Lista los nodos del clúster desde la MacBook
	KUBECONFIG=$(PWD)/kubeconfig kubectl get nodes -o wide

lint:  ## Pasa los linters de las dos capas
	$(AN) ansible-lint
	$(AN) yamllint .
	$(TF) tofu fmt -check -diff
	$(TF) tofu validate

verify:  ## Prueba de idempotencia: la segunda pasada no debe cambiar nada
	$(AN) ansible-playbook site.yml > /tmp/homelab-run1.log
	$(AN) ansible-playbook site.yml | tee /tmp/homelab-run2.log
	@if grep -qE 'changed=[1-9]' /tmp/homelab-run2.log; then \
		echo "FALLO: la segunda pasada ha cambiado cosas. No es idempotente."; \
		exit 1; \
	else \
		echo "OK: idempotente."; \
	fi

destroy:  ## Borra SOLO las VMs gestionadas por OpenTofu (las 2xx)
	$(TF) tofu destroy

vault-edit:  ## Edita los secretos cifrados
	$(AN) ansible-vault edit inventory/group_vars/vault.yml

.PHONY: help deps discover pve plan vms inventory ping check config nodes lint verify destroy vault-edit
