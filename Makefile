
# Makefile - Project Management
# Wraps existing scripts and provides utility commands for the Docker stack.

# =============================================================================
# CONFIGURATION
# =============================================================================

# Default shell
SHELL := /bin/bash

# Default target
.DEFAULT_GOAL := help

# Define Python interpreter (prioritizes virtual environment)
ifneq (,$(wildcard .venv/bin/python3))
    PYTHON := .venv/bin/python3
else ifneq (,$(wildcard venv/bin/python3))
    PYTHON := venv/bin/python3
else
    PYTHON := python3
endif

# Load environment variables from .env if it exists
ifneq (,$(wildcard .env))
    include .env
    export
endif

# =============================================================================
# DOCKER COMPOSE CONFIGURATION
# =============================================================================

# Build compose file list from shared script (single source of truth)
COMPOSE_FILES := $(shell . scripts/compose-files.sh && echo $$COMPOSE_FILES)

# Extract PROJECT_NAME from .env (default to 'stack' if not found)
PROJECT_NAME := $(shell grep '^PROJECT_NAME=' .env 2>/dev/null | cut -d= -f2 || echo stack)

# Suppress warnings for variables set dynamically in start.sh
export TRAEFIK_CONFIG_HASH ?= ""
export TRAEFIK_CERT_RESOLVER ?= ""

# Default tail for logs (can be overridden with tail=N)
tail ?= all

# Extract TRAEFIK_ACME_ENV_TYPE from .env
TRAEFIK_ACME_ENV_TYPE := $(shell grep '^TRAEFIK_ACME_ENV_TYPE=' .env 2>/dev/null | cut -d= -f2)

# Base Docker Compose command
DOCKER_COMPOSE := docker compose -p $(PROJECT_NAME) $(COMPOSE_FILES)

# =============================================================================
# TARGETS
# =============================================================================

# Helper: Check if a service is running (or exists) before executing a command
# Usage: $(call check_service,service_name,command)
check_service = \
	if [ -z "$$($(DOCKER_COMPOSE) ps -q $(1))" ]; then \
		echo "Service '$(1)' is not running."; \
	else \
		$(DOCKER_COMPOSE) exec $(1) $(2); \
	fi

# Helper: Extract arguments for logs and shell commands
# This allows using "make logs redis" instead of "make logs s=redis"
SUPPORTED_COMMANDS := logs shell restart crowdsec-unban crowdsec-ban crowdsec-ban-country crowdsec-unban-country
SUPPORTS_ARGS := $(filter $(firstword $(MAKECMDGOALS)),$(SUPPORTED_COMMANDS))
ifneq "$(SUPPORTS_ARGS)" ""
  # The remaining arguments are the service names
  SERVICE_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  # Turn them into do-nothing targets so make doesn't complain
  $(eval $(SERVICE_ARGS):;@:)
endif

.PHONY: help
help: ## Show this help message
	@echo "Usage: make [target] [service]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: init
init: ## Initialize environment (.env)
	@./scripts/initialize-env.sh

.PHONY: start
start: ## Start the stack (calls start.sh)
	@./scripts/start.sh
	@$(MAKE) --no-print-directory grafana-setup-telegram

.PHONY: stop
stop: ## Stop the stack (calls stop.sh)
	@./scripts/stop.sh

.PHONY: restart
restart: ## Restart the stack or a specific service (usage: make restart [service])
ifneq ($(strip $(SERVICE_ARGS)),)
	@if [ "$(filter traefik,$(SERVICE_ARGS))" = "traefik" ]; then \
		echo "🧹 Flushing Redis cache before restarting Traefik to clear ghost bans..."; \
		$(DOCKER_COMPOSE) exec -T redis redis-cli -a "$${REDIS_PASSWORD}" FLUSHDB 2>/dev/null || true; \
	fi
	@echo "Restarting service(s): $(SERVICE_ARGS)..."
	@$(DOCKER_COMPOSE) restart $(SERVICE_ARGS)
else ifdef s
	@if [ "$(filter traefik,$(s))" = "traefik" ]; then \
		echo "🧹 Flushing Redis cache before restarting Traefik to clear ghost bans..."; \
		$(DOCKER_COMPOSE) exec -T redis redis-cli -a "$${REDIS_PASSWORD}" FLUSHDB 2>/dev/null || true; \
	fi
	@echo "Restarting service: $(s)..."
	@$(DOCKER_COMPOSE) restart $(s)
else
	@echo "🧹 Flushing Redis cache before full stack restart..."
	@$(DOCKER_COMPOSE) exec -T redis redis-cli -a "$${REDIS_PASSWORD}" FLUSHDB 2>/dev/null || true
	@./scripts/stop.sh
	@./scripts/start.sh
endif

.PHONY: rebuild
rebuild: ## Rebuild services from Dockerfile (default: domain-manager watchdog)
ifneq ($(strip $(SERVICE_ARGS)),)
	@echo "Rebuilding service(s): $(SERVICE_ARGS)..."
	@$(DOCKER_COMPOSE) up -d --build --force-recreate $(SERVICE_ARGS)
else ifdef s
	@echo "Rebuilding service: $(s)..."
	@$(DOCKER_COMPOSE) up -d --build --force-recreate $(s)
else
	@echo "Rebuilding custom image services (domain-manager, watchdog)..."
	@$(DOCKER_COMPOSE) up -d --build --force-recreate domain-manager watchdog
endif

.PHONY: status
status: ## Show stack status (docker compose ps)
	@$(DOCKER_COMPOSE) ps

.PHONY: services
services: ## List available services
	@echo "Available services:"
	@$(DOCKER_COMPOSE) ps --services

.PHONY: validate
validate: ## Validate .env against .env.dist keys
	@$(PYTHON) scripts/validate-env.py

.PHONY: sync
sync: ## Synchronize .env with .env.dist (Add missing, remove extras)
	@$(PYTHON) scripts/validate-env.py --sync

.PHONY: logs
logs: ## Follow logs (usage: make logs [service] [tail=N])
ifneq ($(strip $(SERVICE_ARGS)),)
	@echo "Following logs for service: $(SERVICE_ARGS) (tail=$(tail))..."
	@-$(DOCKER_COMPOSE) logs -f --tail=$(tail) $(SERVICE_ARGS)
else ifdef s
	@echo "Following logs for service: $(s) (tail=$(tail))..."
	@-$(DOCKER_COMPOSE) logs -f --tail=$(tail) $(s)
else
	@echo "Following logs for ALL services (tail=$(tail))... (Use 'make services' to see list)"
	@sleep 2
	@-$(DOCKER_COMPOSE) logs -f --tail=$(tail)
endif

.PHONY: shell
shell: ## Open a shell in a container (usage: make shell [service])
ifneq ($(strip $(SERVICE_ARGS)),)
	@$(DOCKER_COMPOSE) exec -it $(SERVICE_ARGS) /bin/sh
else ifdef s
	@$(DOCKER_COMPOSE) exec -it $(s) /bin/sh
else
	@echo "Error: Please specify a service name (e.g., 'make shell traefik')."
	@echo ""
	@make services
endif

.PHONY: pull
pull: ## Pull latest images
	@$(DOCKER_COMPOSE) pull

.PHONY: clean
clean: ## Clean generated configs and backup certificates (Requires confirmation)
	@echo "⚠️  WARNING: This action will:"
	@echo "   - Permanently delete: config/traefik/dynamic-config/*"
	@echo "   - Backup and remove:  config/traefik/acme.json"
	@echo ""
	@read -p "Are you sure you want to proceed? [y/N] " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -rf config/traefik/dynamic-config/*; \
		if [ -f config/traefik/acme.json ]; then \
			ts=$$(date +%Y%m%d%H%M%S); \
			mv config/traefik/acme.json config/traefik/acme.json.$$ts; \
			echo "📦 Backed up acme.json to acme.json.$$ts"; \
		fi; \
		echo "✅ Cleaned generated files."; \
	else \
		echo "Aborted."; \
	fi

.PHONY: ctop
ctop: ## Monitor containers using ctop
	@docker run --rm -ti --name=ctop --volume /var/run/docker.sock:/var/run/docker.sock:ro quay.io/vektorlab/ctop:latest

.PHONY: redis-info
redis-info: ## Show Redis server statistics
	@$(DOCKER_COMPOSE) exec redis redis-cli -a "$${REDIS_PASSWORD}" INFO

.PHONY: redis-monitor
redis-monitor: ## Monitor Redis commands in real-time (Ctrl+C to stop)
	@-$(DOCKER_COMPOSE) exec redis redis-cli -a "$${REDIS_PASSWORD}" MONITOR

.PHONY: redis-ping
redis-ping: ## Ping Redis server
	@$(DOCKER_COMPOSE) exec redis redis-cli -a "$${REDIS_PASSWORD}" PING

.PHONY: traefik-health
traefik-health: ## Check Traefik health status
	@echo "Checking Traefik health..."
	@$(DOCKER_COMPOSE) exec traefik traefik healthcheck || echo "Traefik healthcheck command not available (using default image?)"
	@echo "Checking process list:"
	@$(DOCKER_COMPOSE) top traefik

.PHONY: watch-certs
.PHONY: certs-watch
certs-watch: ## Monitor ACME logs (Requires TRAEFIK_LOG_LEVEL=DEBUG in .env)
	@echo "Monitoring ACME/Certificate logs... (Ctrl+C to stop)"
	@$(DOCKER_COMPOSE) logs -f traefik | \
		grep --line-buffered -iE 'obtained|validated|solve.*challenge|acme.*error|fail' | \
		grep --line-buffered -vE 'Trying to challenge|Adding certificate|Looking for|No ACME.*required|RequestHost|global-compress'

.PHONY: certs-info
certs-info: ## Analyze acme.json certificates against domains.csv (Summary)
	@$(PYTHON) scripts/inspect-certs.py $(ARGS)

.PHONY: certs-inspect
certs-inspect: ## Analyze acme.json certificates against domains.csv (Detailed)
	@$(PYTHON) scripts/inspect-certs.py --verbose $(ARGS)
	
.PHONY: certs-prune
certs-prune: ## Remove old/unused certificates from acme.json (Dry-run)
	@$(PYTHON) scripts/prune-certs.py $(ARGS)

.PHONY: certs-prune-force
certs-prune-force: ## Remove old/unused certificates from acme.json (Actual)
	@$(PYTHON) scripts/prune-certs.py --force $(ARGS)

# =============================================================================
# OPTIONAL INCLUDES
# =============================================================================

# Local Certificates (only if environment is local)
ifeq ($(TRAEFIK_ACME_ENV_TYPE),local)
    include scripts/make/certs.mk
endif

# CrowdSec Targets (only if enabled)
ifneq ($(CROWDSEC_ENABLE),false)
    include scripts/make/crowdsec.mk
endif

# Grafana Alerting setup targets
include scripts/make/grafana.mk
