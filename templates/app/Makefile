APP := __APP_NAME__
CHART_VERSION ?= 0.4.0
GO ?= go
OAPI := go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.9.0

.PHONY: test lint build codegen codegen-check conformance image

test: ## Unit tests; no database needed
	$(GO) test ./...

lint: ## Format and vet
	@out=$$(gofmt -l $$(find . -name '*.go' -type f)); if [ -n "$$out" ]; then echo "gofmt found unformatted files:"; echo "$$out"; exit 1; fi
	$(GO) vet ./...

build: ## Build both binaries into bin/
	CGO_ENABLED=0 $(GO) build -trimpath -o bin/app-api ./cmd/web
	CGO_ENABLED=0 $(GO) build -trimpath -o bin/app-migrate ./cmd/migrate

codegen: ## Regenerate the Go contract from spec/openapi.yaml
	$(OAPI) -config spec/oapi-codegen.yaml spec/openapi.yaml

codegen-check: ## Fail if the committed generated code is stale
	@tmp=$$(mktemp); cp internal/api/openapi.gen.go $$tmp; \
	 $(MAKE) --no-print-directory -s codegen; \
	 if ! diff -q $$tmp internal/api/openapi.gen.go >/dev/null; then \
	   echo "generated code is stale:"; diff -u $$tmp internal/api/openapi.gen.go | head -40; rm -f $$tmp; exit 1; \
	 fi; rm -f $$tmp

conformance: ## Render against the pinned foundry chart
	CHART_VERSION=$(CHART_VERSION) APP=$(APP) ./scripts/conformance.sh

image: ## Build the app image
	docker build -t $(APP)-api .
