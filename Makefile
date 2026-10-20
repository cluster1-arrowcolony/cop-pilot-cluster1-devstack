# COP-PILOT Cluster 1 devstack. See README.md.
# Settings come from versions.env and an optional devstack.env (copy devstack.env.example).

SCRIPTS := scripts

.PHONY: help tools checksums up down test lint status clean colonies kolony reconciler openslice retarget peering-check ziti-enroll

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'

tools: ## Download pinned k3d, kubectl, helm and colonies into .devstack/bin
	@$(SCRIPTS)/tools.sh

checksums: ## Rewrite checksums.txt from upstream after changing a tool version in versions.env
	@$(SCRIPTS)/tools.sh checksums

up: tools ## Create the cluster and deploy ColonyOS, Kolony, the reconciler (and OpenSlice if set)
	@$(SCRIPTS)/cluster.sh up
	@$(SCRIPTS)/colonies.sh up
	@$(SCRIPTS)/kolony.sh
	@$(SCRIPTS)/reconciler.sh up
	@$(SCRIPTS)/openslice.sh up
	@echo; $(SCRIPTS)/status.sh

colonies: ## Redeploy only ColonyOS
	@$(SCRIPTS)/colonies.sh up

kolony: ## Rebuild and redeploy only Kolony (picks up changes in KOLONY_SRC)
	@$(SCRIPTS)/kolony.sh

reconciler: ## Restart only the docker-reconciler
	@$(SCRIPTS)/reconciler.sh up

openslice: ## Bring up or connect OpenSlice according to OPENSLICE
	@$(SCRIPTS)/openslice.sh up

test: ## End-to-end tests of the running devstack (and of OpenSlice when enabled)
	@$(SCRIPTS)/test.sh
	@$(SCRIPTS)/openslice.sh test

peering-check: ## Check that a peer (HypO through SIF) can log in and read the catalog at OPENSLICE_URL
	@$(SCRIPTS)/peering-check.sh

ziti-enroll: ## Enroll an OpenZiti identity for OPENSLICE=ice: make ziti-enroll JWT=<file.jwt>
	@test -n "$(JWT)" || { echo 'usage: make ziti-enroll JWT=<file.jwt>'; exit 2; }
	@$(SCRIPTS)/ziti-enroll.sh "$(JWT)"

lint: ## Run shellcheck on the scripts (needs shellcheck installed)
	@shellcheck -x $(SCRIPTS)/*.sh

retarget: ## Clone an OpenSlice RFSS for this cluster: make retarget SPEC="<RFSS name>"
	@test -n "$(SPEC)" || { echo 'usage: make retarget SPEC="<RFSS name>"'; exit 2; }
	@$(SCRIPTS)/catalog.sh retarget "$(SPEC)"

status: ## Show what is running and how to reach it
	@$(SCRIPTS)/status.sh

down: ## Delete the cluster and containers; keeps identities and tools
	@$(SCRIPTS)/openslice.sh down
	@$(SCRIPTS)/reconciler.sh down
	@$(SCRIPTS)/cluster.sh down

clean: down ## Also delete identities, tools, downloaded sources and the image caches
	@$(SCRIPTS)/cache.sh down
	rm -rf .devstack
