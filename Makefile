# =============================================================================
# Supabase Hetzner - Makefile
# =============================================================================
# Zentrale Übersicht aller Projekt-Operationen.
# Verwendung: make <target> [ENV=dev|prod]
# =============================================================================

ENV ?= dev
SHELL := /bin/bash

.DEFAULT_GOAL := help

# =============================================================================
# Deployment
# =============================================================================

.PHONY: init plan apply destroy

init: ## Terraform initialisieren und Secrets generieren
	./scripts/deploy.sh --env $(ENV) --init

plan: ## Terraform Plan anzeigen
	./scripts/deploy.sh --env $(ENV) --plan

apply: ## Infrastruktur deployen
	./scripts/deploy.sh --env $(ENV) --apply

destroy: ## Infrastruktur zerstören (mit Bestätigung)
	./scripts/deploy.sh --env $(ENV) --destroy

# =============================================================================
# Betrieb
# =============================================================================

.PHONY: status ssh logs test

status: ## Infrastruktur-Status anzeigen
	./scripts/deploy.sh --env $(ENV) --status

ssh: ## SSH-Verbindung zum Server
	./scripts/deploy.sh --env $(ENV) --ssh

logs: ## Docker Logs anzeigen (SERVICE=name für einzelnen Service)
ifdef SERVICE
	./scripts/deploy.sh --env $(ENV) --logs $(SERVICE)
else
	./scripts/deploy.sh --env $(ENV) --logs
endif

test: ## Deployment-Tests ausführen
	./scripts/deploy.sh --env $(ENV) --test

# =============================================================================
# Backup & Restore
# =============================================================================

.PHONY: backup backup-list restore

backup: ## Manuelles Backup auslösen
	./scripts/deploy.sh --env $(ENV) --backup-now

backup-list: ## Verfügbare Backups anzeigen
	./scripts/deploy.sh --env $(ENV) --list-backups

backup-test: ## Backup/Restore lokal testen
	./scripts/deploy.sh --env $(ENV) --test-backup

restore: ## Backup wiederherstellen (DATE=YYYY-MM-DD oder interaktiv)
ifdef DATE
	./scripts/deploy.sh --env $(ENV) --restore $(DATE)
else
	./scripts/deploy.sh --env $(ENV) --restore
endif

# =============================================================================
# Code-Qualität
# =============================================================================

.PHONY: fmt lint lint-fix security pre-commit

fmt: ## Terraform-Code formatieren
	terraform -chdir=terraform fmt -recursive

lint: ## Terraform-Code mit tflint prüfen
	cd terraform && tflint --config=.tflint.hcl

security: ## Security-Scan mit trivy
	trivy config terraform/ --severity HIGH,CRITICAL

pre-commit: ## Alle Pre-commit Hooks ausführen
	pre-commit run --all-files

pre-commit-install: ## Pre-commit Hooks installieren
	pip install pre-commit
	pre-commit install

# =============================================================================
# Setup
# =============================================================================

.PHONY: setup setup-env

setup: pre-commit-install ## Entwicklungsumgebung einrichten
	@echo ""
	@echo "Entwicklungsumgebung eingerichtet."
	@echo "Nächster Schritt: make setup-env ENV=$(ENV)"

setup-env: ## Neue Umgebung vorbereiten (ENV=dev|prod)
	@mkdir -p environments/$(ENV)
	@if [ ! -f environments/$(ENV)/terraform.tfvars ]; then \
		cp terraform/terraform.tfvars.example environments/$(ENV)/terraform.tfvars; \
		echo "environments/$(ENV)/terraform.tfvars erstellt - bitte ausfüllen"; \
	else \
		echo "environments/$(ENV)/terraform.tfvars existiert bereits"; \
	fi

# =============================================================================
# Hilfe
# =============================================================================

.PHONY: help

help: ## Diese Hilfe anzeigen
	@echo ""
	@echo "Supabase Hetzner - Verfügbare Befehle"
	@echo "======================================"
	@echo ""
	@echo "Verwendung: make <target> [ENV=dev|prod]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Aktuelle Umgebung: $(ENV)"
	@echo ""
