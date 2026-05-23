# Local Certificates Targets
# Included conditionally in main Makefile

##@ Local Certificates

.PHONY: certs-create-local
certs-create-local: ## Generate local certificates (calls create-local-certs.sh)
	@./scripts/create-local-certs.sh
