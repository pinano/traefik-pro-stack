
# Makefile - Project Management
# Wraps existing scripts and provides utility commands for the Docker stack.

# =============================================================================
# CONFIGURATION
# =============================================================================

# Default shell
SHELL := /bin/bash

# Default target
.DEFAULT_GOAL := help

# ==============================================================================
# HELP COMMAND INTERCEPTOR
# ==============================================================================
# Intercepts 'make <target> help' or 'make help <target>' and routes to 'make help-<target>'
ifneq ($(filter help,$(MAKECMDGOALS)),)
  HELP_TARGET := $(firstword $(filter-out help,$(MAKECMDGOALS)))
  ifneq ($(HELP_TARGET),)
    # Turn all targets except help into dummy targets to suppress "No rule to make target"
    $(eval $(filter-out help,$(MAKECMDGOALS)):;@:)
    # Make 'help' execute the specific help target
    $(eval help:;@$(MAKE) -s help-$(HELP_TARGET))
    # Skip parsing the rest of the Makefile to avoid overriding warnings
    SKIP_MAKEFILE := 1
  endif
endif

ifndef SKIP_MAKEFILE

# Suppress LibreSSL warnings on macOS (urllib3 v2 compatibility)
export PYTHONWARNINGS := ignore:urllib3 v2 only supports

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

export TRAEFIK_CERT_RESOLVER ?= ""

# Resolve path variables if they are empty or set to placeholder/default values
ifeq ($(DASHBOARD_APP_PATH_HOST),REPLACE_ME)
    DASHBOARD_APP_PATH_HOST := $(shell pwd)
    export DASHBOARD_APP_PATH_HOST
endif
ifeq ($(DASHBOARD_APP_PATH_HOST),)
    DASHBOARD_APP_PATH_HOST := $(shell pwd)
    export DASHBOARD_APP_PATH_HOST
endif

# Default tail for logs (can be overridden with tail=N)
tail ?= all

# Extract TRAEFIK_ACME_ENV_TYPE from .env
TRAEFIK_ACME_ENV_TYPE := $(shell grep '^TRAEFIK_ACME_ENV_TYPE=' .env 2>/dev/null | cut -d= -f2)

# Base Docker Compose command
ifeq ($(CROWDSEC_ENABLE),false)
    DOCKER_COMPOSE := docker compose -p $(PROJECT_NAME) $(COMPOSE_FILES)
else
    DOCKER_COMPOSE := docker compose -p $(PROJECT_NAME) --profile crowdsec $(COMPOSE_FILES)
endif

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
SUPPORTED_COMMANDS := logs shell restart rebuild crowdsec-unban crowdsec-ban crowdsec-ban-country crowdsec-unban-country
SUPPORTS_ARGS := $(filter $(firstword $(MAKECMDGOALS)),$(SUPPORTED_COMMANDS))
ifneq "$(SUPPORTS_ARGS)" ""
  # The remaining arguments are the service names
  SERVICE_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  # Turn them into do-nothing targets so make doesn't complain
  $(eval $(SERVICE_ARGS):;@:)
endif

##@ General

##@help help
## Displays this help message with a grouped list of all available commands.
## To see detailed information about any specific command, run 'make <command> help'.
.PHONY: help
help: ## Show this help message
	@echo "Usage: make [target] [service]"
	@echo "For detailed help on any command, run: make <target> help (e.g., make start help)"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2 } /^##@ / { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

help-%:
	@awk -v target=$* ' \
	/^##@help / { if ($$2 == target) { flag=1; next } else { flag=0 } } \
	/^## / { if (flag) print substr($$0, 4) } \
	/^[^#]/ { flag=0 } \
	' $(MAKEFILE_LIST)

##@ Versioning & Updates

##@help release
## Generates a new CalVer release (YYYY.MM.DD).
## - Aborts if there are uncommitted changes or no new commits.
## - Generates CHANGELOG.md automatically from git commit history.
## - Updates the VERSION file.
## - Tags the repository and commits the changes.
.PHONY: release
release: ## Generate a new CalVer release, update CHANGELOG.md, and create a git tag
	@./scripts/release.sh

##@help update
## Safely updates a production environment to the latest release.
## - Fetches the latest tags from the remote repository.
## - Checks out the highest available version tag.
## - Will NEVER pull untagged intermediate commits.
## - Interactively prompts you to rebuild and start the stack to apply changes.
## Usage: make update [version=vYYYY.MM.DD]

.PHONY: update
update: ## Fetch and safely upgrade the codebase (usage: make update [version=vX])
	@./scripts/update.sh $(version)

##@help rollback
## Interactively lists recent versions and allows you to rollback.
## - Fetches the last 10 tags.
## - Presents a numbered list to choose from.
## - Performs a safe git checkout to the selected tag.
## - Interactively prompts to apply changes.

.PHONY: rollback
rollback: ## Interactively list recent versions and rollback to a specific one
	@./scripts/rollback.sh

##@ Backup & Restore

##@help backup
## Creates a secure, timestamped backup of your operational state.
## - Backs up .env, domains.csv, and all small config/ files (including WAF rules and certificates).
## - Skips giant data volumes (logs, metrics) to keep the backup lightweight and fast.
## - Output is saved to the backups/ directory.

.PHONY: backup
backup: ## Create a secure backup of configuration state (excludes heavy logs)
	@./scripts/backup-traefik-stack.sh

##@help restore
## Restores a previously created backup tarball.
## - Requires interactive confirmation.
## - Overwrites current configurations with the backup state.
## - Automatically secures file permissions (e.g., chmod 600 for .env and acme.json) after extraction.
## Usage: make restore file=backups/traefik-stack_YYYYMMDD_HHMMSS.tar.gz

.PHONY: restore
restore: ## Restore configuration state from a backup tarball (usage: make restore file=...)
	@./scripts/restore.sh $(file)

##@ Environment & Config

##@help init
## Initializes the environment interactively.
## - Safely copies .env.dist to .env without overwriting existing values.
## - Auto-generates cryptographic secrets for Redis, CrowdSec API, and the Dashboard.
## - Prompts the user to configure the primary domain and email address.
.PHONY: init
init: ## Initialize environment (.env)
	@./scripts/initialize-env.sh

##@help validate
## Validates your current .env file against .env.dist.
## - Checks if any required keys are missing.
## - Validates data types and formats (e.g., ensures boolean fields are true/false).
.PHONY: validate
validate: ## Validate .env against .env.dist keys
	@$(PYTHON) scripts/validate-env.py

##@help sync
## Synchronizes your .env file with .env.dist.
## - Adds any newly introduced configuration variables from .env.dist.
## - Removes obsolete variables from .env that no longer exist in .env.dist.
## - Preserves all your custom values.
.PHONY: sync
sync: ## Synchronize .env with .env.dist (Add missing, remove extras)
	@$(PYTHON) scripts/validate-env.py --sync

##@ Core Lifecycle

##@help start
## Boots up the entire infrastructure stack securely.
## It follows a strict 6-phase security-first sequence:
## 1. Validates environment variables.
## 2. Syncs credentials and auto-generates missing secrets.
## 3. Prepares dynamic Traefik and Anubis configurations.
## 4. Creates necessary isolated Docker networks.
## 5. Boots Redis and CrowdSec first (waiting up to 60s for healthchecks).
## 6. Starts the rest of the stack (Traefik, Grafana, Dashboard, etc).
.PHONY: start
start: ## Start the stack (calls start.sh)
	@./scripts/start.sh

##@help stop
## Gracefully stops and removes all containers in the stack.
## - Calls scripts/stop.sh which safely tears down networks and containers.
## - Data volumes are preserved.
.PHONY: stop
stop: ## Stop the stack (calls stop.sh)
	@./scripts/stop.sh

##@help restart
## Restarts the entire stack or a specific service.
## - Full restart: make restart (runs stop.sh then start.sh)
## - Single service: make restart traefik (runs docker compose restart traefik)
.PHONY: restart
restart: ## Restart the stack or a specific service (usage: make restart [service])
ifneq ($(strip $(SERVICE_ARGS)),)
	@echo "Restarting service(s): $(SERVICE_ARGS)..."
	@$(DOCKER_COMPOSE) restart $(SERVICE_ARGS)
else ifdef s
	@echo "Restarting service: $(s)..."
	@$(DOCKER_COMPOSE) restart $(s)
else
	@./scripts/stop.sh
	@./scripts/start.sh
endif

##@help rebuild
## Rebuilds custom images from their Dockerfiles.
## - By default, rebuilds the 'dashboard' and 'watchdog' images.
## - Can rebuild specific services: make rebuild traefik
.PHONY: rebuild
rebuild: ## Rebuild services from Dockerfile (default: dashboard watchdog)
ifneq ($(strip $(SERVICE_ARGS)),)
	@echo "Rebuilding service(s): $(SERVICE_ARGS)..."
	@$(DOCKER_COMPOSE) up -d --build --force-recreate $(SERVICE_ARGS)
else ifdef s
	@echo "Rebuilding service: $(s)..."
	@$(DOCKER_COMPOSE) up -d --build --force-recreate $(s)
else
	@echo "Rebuilding custom image services (dashboard, watchdog)..."
	@$(DOCKER_COMPOSE) up -d --build --force-recreate dashboard watchdog
endif

##@help status
## Shows the status of all running containers in the stack.
## - Wrapper around 'docker compose ps'.
.PHONY: status
status: ## Show stack status (docker compose ps)
	@$(DOCKER_COMPOSE) ps

##@help services
## Lists all available services defined in the active docker-compose files.
.PHONY: services
services: ## List available services
	@echo "Available services:"
	@$(DOCKER_COMPOSE) ps --services

##@ Observability & Debugging

##@help health
## Executes a global health check of the infrastructure.
## - Verifies strict file permissions for .env and acme.json.
## - Tests Traefik internal routing health.
## - Verifies CrowdSec LAPI responsiveness and WAF loading.
## - Pings the Redis cache server.
## - Validates Grafana's internal API health.

.PHONY: health
health: ## Run a global health check across all core services
	@./scripts/health.sh

##@help logs
## Follows the logs of one or all services.
## - All services: make logs
## - Single service: make logs traefik
## - Limit tail: make logs traefik tail=100
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

##@help shell
## Opens an interactive /bin/sh shell inside a container.
## - Usage: make shell crowdsec
## - Useful for debugging or manual inspection inside the isolated network.
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

##@help ctop
## Launches an interactive top-like interface for monitoring Docker containers.
## - Shows CPU, Memory, Network, and IO metrics in real-time.
.PHONY: ctop
ctop: ## Monitor containers using ctop
	@docker run --rm -ti --name=ctop --volume /var/run/docker.sock:/var/run/docker.sock:ro quay.io/vektorlab/ctop:latest

##@ Maintenance

##@help maintenance-on
## Enables Global Maintenance Mode.
## - Intercepts all traffic to all domains via a Traefik priority 999999 rule.
## - Shows a premium HTML maintenance page.
## - Excludes the primary administration DOMAIN (defined in .env) so you can still access the dashboard.
## - Traefik will dynamically apply these rules instantly.

.PHONY: maintenance-on
maintenance-on: ## Enable global maintenance mode (blocks public traffic, allows admin)
	@./scripts/maintenance.sh on

##@help maintenance-off
## Disables Global Maintenance Mode.
## - Removes the maintenance flag and stops the maintenance container.
## - Traefik will instantly restore normal traffic flow.

.PHONY: maintenance-off
maintenance-off: ## Disable global maintenance mode
	@./scripts/maintenance.sh off

##@help pull
## Pulls the latest versions of all external images (Traefik, Redis, Grafana, etc.) defined in the compose files.
.PHONY: pull
pull: ## Pull latest images
	@$(DOCKER_COMPOSE) pull

##@help clean
## DANGEROUS: Cleans up generated configurations.
## - Deletes all auto-generated YAML routing files in config/traefik/dynamic-config/.
## - Backs up and removes the config/traefik/acme.json certificates file.
## - Requires interactive confirmation.
.PHONY: clean
clean: ## Clean generated configs and backup certificates (Requires confirmation)
	@echo "⚠️  WARNING: This action will:"
	@echo "   - Permanently delete: config/traefik/dynamic-config/*"
	@echo "   - Backup and remove:  config/traefik/acme.json"
	@echo ""
	@read -p "Are you sure you want to proceed? [y/N] " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -rf config/traefik/dynamic-config/*; \
		rm -f config/traefik/traefik-generated.yaml; \
		if [ -f config/traefik/acme.json ]; then \
			ts=$$(date +%Y%m%d%H%M%S); \
			mv config/traefik/acme.json config/traefik/acme.json.$$ts; \
			echo "📦 Backed up acme.json to acme.json.$$ts"; \
		fi; \
		echo "✅ Cleaned generated files."; \
	else \
		echo "Aborted."; \
	fi

##@ Valkey Utilities

##@help valkey-info
## Displays statistical information and metrics from the Valkey server.
.PHONY: valkey-info
valkey-info: ## Show Valkey server statistics
	@$(DOCKER_COMPOSE) exec redis valkey-cli -a "$${REDIS_PASSWORD}" --no-auth-warning INFO

##@help valkey-monitor
## Streams every command processed by the Valkey server in real-time.
## - Extremely useful for debugging cache hits/misses.
.PHONY: valkey-monitor
valkey-monitor: ## Monitor Valkey commands in real-time (Ctrl+C to stop)
	@-$(DOCKER_COMPOSE) exec redis valkey-cli -a "$${REDIS_PASSWORD}" --no-auth-warning MONITOR

##@help valkey-ping
## Sends a PING command to the Valkey server to verify connectivity and responsiveness.
.PHONY: valkey-ping
valkey-ping: ## Ping Valkey server
	@$(DOCKER_COMPOSE) exec redis valkey-cli -a "$${REDIS_PASSWORD}" --no-auth-warning PING

##@ Traefik Utilities

##@help traefik-health
## Checks the health status of the Traefik edge router container.
.PHONY: traefik-health
traefik-health: ## Check Traefik health status
	@echo "Checking Traefik health..."
	@$(DOCKER_COMPOSE) exec traefik traefik healthcheck || echo "Traefik healthcheck command not available (using default image?)"
	@echo "Checking process list:"
	@$(DOCKER_COMPOSE) top traefik

##@ Certificate Management

##@help certs-watch
## Tails the Traefik logs, filtering specifically for ACME certificate negotiation events.
## - Works with default INFO log level (captures lego logs).
.PHONY: certs-watch
certs-watch: ## Monitor ACME logs (Works at default INFO level)
	@echo "Monitoring ACME/Certificate logs... (Ctrl+C to stop)"
	@-$(DOCKER_COMPOSE) logs -f traefik | \
		grep --line-buffered -iE 'obtain|validat|challenge|acme|lego|fail|err' | \
		grep --line-buffered -vE 'Adding certificate|Looking for|No ACME.*required|RequestHost|global-compress'

##@help certs-info
## Analyzes the acme.json file against domains.csv.
## - Prints a clean summary of which domains have valid certificates and which are missing.
.PHONY: certs-info
certs-info: ## Analyze acme.json certificates against domains.csv (Summary)
	@$(PYTHON) scripts/inspect-certs.py $(ARGS)

##@help certs-inspect
## Analyzes the acme.json file and prints detailed information for every certificate (Creation date, Expiration, SANs).
.PHONY: certs-inspect
certs-inspect: ## Analyze acme.json certificates against domains.csv (Detailed)
	@$(PYTHON) scripts/inspect-certs.py --verbose $(ARGS)

##@help certs-prune
## Analyzes acme.json for old, expired, or orphaned certificates that are no longer in domains.csv.
## - DRY RUN mode: only prints what would be deleted.
.PHONY: certs-prune
certs-prune: ## Remove old/unused certificates from acme.json (Dry-run)
	@$(PYTHON) scripts/prune-certs.py $(ARGS)

##@help certs-prune-force
## Analyzes acme.json for orphaned certificates and physically deletes them to prevent Traefik from loading dead certs.
.PHONY: certs-prune-force
certs-prune-force: ## Remove old/unused certificates from acme.json (Actual)
	@$(PYTHON) scripts/prune-certs.py --force $(ARGS)

##@ Image Utilities

##@help check-updates
## Scans compose files and audits registries for newer Docker image tags.
## Filters tags matching the current tag's flavor (e.g. alpine, slim).
.PHONY: check-updates
check-updates: ## Check for Docker image updates
	@$(PYTHON) scripts/check-image-updates.py


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
else
# Dummy targets to print error when CrowdSec is disabled
crowdsec-%:
	@echo "⚠️ Error: Las tareas de CrowdSec están deshabilitadas porque CROWDSEC_ENABLE=false en tu .env"
	@exit 1
endif

# Grafana Alerting setup targets
include scripts/make/grafana.mk

endif # SKIP_MAKEFILE

