# Local Certificates Targets
# Included conditionally in main Makefile

##@ Local Certificates

##@help certs-create-local
## Generates self-signed certificates using mkcert for local development.
## - Only available if TRAEFIK_ACME_ENV_TYPE=local.
.PHONY: certs-create-local
certs-create-local: ## Generate local certificates (calls create-local-certs.sh)
	@./scripts/create-local-certs.sh
