SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := lint
MAKEFLAGS += --no-print-directory

GO ?= go

.PHONY: install fmt lint typecheck test build build-static acceptance smoke

install: ## Download modules (staticcheck is a go.mod tool)
	$(GO) mod download

fmt: ## Format with gofmt
	gofmt -w .

lint: ## gofmt check, go vet and staticcheck
	@unformatted="$$(gofmt -l .)"; if [[ -n "$$unformatted" ]]; then echo "gofmt: needs formatting:"; echo "$$unformatted"; exit 1; fi
	$(GO) vet ./...
	$(GO) vet -tags acceptance ./...
	$(GO) tool staticcheck ./...

typecheck: ## Compile every package, acceptance included
	$(GO) build ./...
	$(GO) test -tags acceptance -run '^$$' ./... >/dev/null

test: ## Run unit tests
	$(GO) test ./...

build: ## Build the app:local image
	docker build -t app:local .

build-static: ## Render the GET routes to dist/static (static hosts such as GitHub Pages)
	rm -rf dist/static
	$(GO) run ./cmd/export dist/static

acceptance: ## Run the acceptance suite against the compose container
	@trap 'rc=$$?; docker compose down -v --remove-orphans || true; exit $$rc' EXIT; \
	docker compose up -d --build --wait; \
	BASE_URL=http://localhost:8080 $(GO) test -count=1 -tags acceptance ./acceptance/...

smoke: ## Run the ProdSafe checks against URL=<url>
	@if [[ -z "$(URL)" ]]; then echo "error: URL is required (usage: make smoke URL=http://localhost:8080)" >&2; exit 1; fi
	BASE_URL="$(URL)" $(GO) test -count=1 -tags acceptance -run ProdSafe ./acceptance/...
