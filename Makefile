SHELL := /bin/bash
.DEFAULT_GOAL := help

AWS_REGION ?= ap-southeast-2
KUBECONFIG ?= $(HOME)/.kube/foundry
KUBE_CONTEXT ?= foundry-staging

STACKS := bootstrap account alerts network registry data cluster edge argocd
BACKEND_STACKS := account alerts network registry data cluster edge argocd
CHARTS := charts/app-api charts/app-web

STACK ?=
TF_ARGS ?=
APP ?=
ENV ?= staging

# Host targets read .env when it exists. Containers do not use this file; the
# chart injects PORT and the Secret injects DATABASE_URL. set -a is what makes
# TF_VAR_* and CLOUDFLARE_API_TOKEN visible to Terraform.
LOAD_ENV := set -a; if [ -f .env ]; then . ./.env; fi; set +a

.PHONY: help fmt fmt-check validate init plan apply charts-lint charts-test check-argocd release platform-go-lint platform-go-test template-test scripts-lint new-app onboard-app rds-tunnel eks-tunnel eks-kubeconfig

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_.-]+:.*## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*## "}; {printf "  %-20s %s\n", $$1, $$2}'

fmt: ## Format all Terraform
	terraform fmt -recursive terraform/

fmt-check: ## Fail if Terraform is not formatted
	terraform fmt -check -recursive terraform/

# No backend: validate must work before the bootstrap has created the bucket.
validate: ## Initialise without a backend and validate every stack
	@for s in $(STACKS); do \
	  printf '%-10s ' "$$s"; \
	  terraform -chdir=terraform/$$s init -backend=false -input=false -no-color >/dev/null || exit 1; \
	  terraform -chdir=terraform/$$s validate -no-color | grep -q 'Success' || exit 1; \
	  echo ok; \
	done

# Bootstrap keeps local state; every other stack reads the bucket it created.
init: ## Initialise every stack against the S3 backend (bootstrap stays local)
	$(LOAD_ENV); terraform -chdir=terraform/bootstrap init
	@$(LOAD_ENV); for s in $(BACKEND_STACKS); do terraform -chdir=terraform/$$s init -backend-config=../backend.hcl || exit 1; done

plan: ## Plan one stack: make plan STACK=network [TF_ARGS=...]
	@test -n "$(STACK)" || { echo "usage: make plan STACK=<stack> [TF_ARGS=...]"; exit 1; }
	$(LOAD_ENV); terraform -chdir=terraform/$(STACK) plan $(TF_ARGS)

apply: ## Apply one stack: make apply STACK=network [TF_ARGS=...]
	@test -n "$(STACK)" || { echo "usage: make apply STACK=<stack> [TF_ARGS=...]"; exit 1; }
	$(LOAD_ENV); terraform -chdir=terraform/$(STACK) apply $(TF_ARGS)

charts-lint: ## Lint every chart with the contract values
	@for c in $(CHARTS); do helm lint $$c --kube-version 1.37.0 -f $$c/tests/ci-values.yaml || exit 1; done

charts-test: ## Render every chart and assert the contract
	./scripts/chart-test.sh

check-argocd: ## Validate the registry, AppProjects and ApplicationSet
	./scripts/check-argocd.sh

# The tag is load-bearing. Every app Application reads the charts, the profiles
# and the environments at one revision, so a profile or environment change is a
# release too, not a push to main.
release: ## [human] Tag the chart release v<Chart.yaml version> on main and push it
	@test "$$(git rev-parse --abbrev-ref HEAD)" = "main" || { echo "tag the merge commit on main, not a branch"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "working tree is dirty"; exit 1; }
	@v=$$(sed -n 's/^version: *//p' charts/app-api/Chart.yaml); \
	 [ "$$v" = "$$(sed -n 's/^version: *//p' charts/app-web/Chart.yaml)" ] || { echo "the two charts declare different versions"; exit 1; }; \
	 git rev-parse -q --verify "refs/tags/v$$v" >/dev/null && { echo "v$$v already exists"; exit 1; }; \
	 git tag -a "v$$v" -m "Chart release v$$v" && git push origin "v$$v"

platform-go-lint: ## Format-check and vet the foundry/go module
	@out=$$(gofmt -l $$(find go -name '*.go' -type f)); if [ -n "$$out" ]; then echo "gofmt found unformatted files:"; echo "$$out"; exit 1; fi
	cd go && go vet ./...

platform-go-test: ## Unit tests for the foundry/go module, with the race detector
	cd go && go test -race -short ./...

template-test: ## Test the template in place: unit, generated code, chart conformance
	cd templates/app && go test ./...
	cd templates/app && make codegen-check
	cd templates/app && FOUNDRY_ROOT=$$(cd ../.. && pwd) make conformance APP=demo

scripts-lint: ## Syntax-check every script
	@for f in scripts/*.sh; do bash -n "$$f" || exit 1; done

new-app: ## Instantiate the template: make new-app NAME=demo
	@test -n "$(NAME)" || { echo "usage: make new-app NAME=<name>"; exit 1; }
	./scripts/new-app.sh $(NAME)

onboard-app: ## [host] Onboard APP into ENV: make onboard-app APP=app1 ENV=staging
	@test -n "$(APP)" || { echo "usage: make onboard-app APP=<app> ENV=dev|staging"; exit 1; }
	$(LOAD_ENV); ./scripts/onboard-app.sh $(APP) $(ENV)

rds-tunnel: ## [host] Forward ENV RDS Postgres to 127.0.0.1:15432
	@$(LOAD_ENV); target=$$(terraform -chdir=terraform/cluster output -raw bastion_instance_id); \
	 host=$$(terraform -chdir=terraform/data output -json db_endpoints | jq -r --arg e "$(ENV)" '.[$$e]'); \
	 [ -n "$$host" ] && [ "$$host" != "null" ] || { echo "no RDS endpoint for ENV=$(ENV)"; exit 1; }; \
	 echo "forwarding $$host:5432 to 127.0.0.1:15432 through $$target; leave this running"; \
	 aws ssm start-session --region $(AWS_REGION) --target "$$target" --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host="$$host",portNumber="5432",localPortNumber="15432"

# The EKS API is private. This is the only way to reach it from a laptop; leave
# it running in its own terminal.
eks-tunnel: ## [host] Forward the private EKS API to localhost:6443 through SSM
	@command -v session-manager-plugin >/dev/null || { echo "session-manager-plugin is not installed"; exit 1; }
	@$(LOAD_ENV); target=$$(terraform -chdir=terraform/cluster output -raw bastion_instance_id); \
	 host=$$(terraform -chdir=terraform/cluster output -raw cluster_endpoint | sed 's|https://||'); \
	 echo "forwarding $$host:443 to 127.0.0.1:6443 through $$target; leave this running, ^C to stop"; \
	 aws ssm start-session --region $(AWS_REGION) --target "$$target" --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host="$$host",portNumber="443",localPortNumber="6443"

eks-kubeconfig: ## [host] Point kubectl at the tunnel as context foundry-staging
	@$(LOAD_ENV); aws eks update-kubeconfig --region $(AWS_REGION) --kubeconfig $(KUBECONFIG) \
	  --name "$$(terraform -chdir=terraform/cluster output -raw cluster_name)" --alias $(KUBE_CONTEXT) >/dev/null || exit 1
	@$(LOAD_ENV); cluster=$$(kubectl config view --kubeconfig $(KUBECONFIG) -o jsonpath="{.contexts[?(@.name=='$(KUBE_CONTEXT)')].context.cluster}"); \
	 host=$$(terraform -chdir=terraform/cluster output -raw cluster_endpoint | sed 's|https://||'); \
	 kubectl config set-cluster "$$cluster" --kubeconfig $(KUBECONFIG) --server=https://127.0.0.1:6443 --tls-server-name="$$host" >/dev/null || exit 1; \
	 kubectl config use-context $(KUBE_CONTEXT) --kubeconfig $(KUBECONFIG) >/dev/null || exit 1; \
	 echo "context $(KUBE_CONTEXT) in $(KUBECONFIG) dials 127.0.0.1:6443 as $$host"
