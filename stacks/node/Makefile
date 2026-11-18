SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := lint
MAKEFLAGS += --no-print-directory

.PHONY: install fmt lint typecheck test build build-static acceptance smoke

install: ## Install dependencies from lockfile
	npm ci

fmt: ## Format files with Prettier
	@[ -d node_modules ] || npm ci
	npm run fmt

lint: ## Run ESLint and Prettier check
	@[ -d node_modules ] || npm ci
	npm run lint

typecheck: ## Run TypeScript type checking
	@[ -d node_modules ] || npm ci
	npm run typecheck

test: ## Run unit tests with Vitest
	@[ -d node_modules ] || npm ci
	npm run test

build: ## Compile TypeScript and build Docker image
	@[ -d node_modules ] || npm ci
	npm run build && docker build -t app:local .

build-static: ## Render the GET routes to dist/static (static hosts such as GitHub Pages)
	@[ -d node_modules ] || npm ci
	rm -rf dist/static
	npm run build
	node dist/export.js dist/static

acceptance: ## Run Playwright API acceptance suite against compose container
	@[ -d node_modules ] || npm ci
	@trap 'rc=$$?; docker compose down -v --remove-orphans || true; exit $$rc' EXIT; \
	docker compose up -d --build --wait; \
	npm run acceptance

smoke: ## Run @prod-safe smoke tests against URL=<url>
	@if [[ -z "$(URL)" ]]; then echo "error: URL is required (usage: make smoke URL=http://localhost:8080)" >&2; exit 1; fi
	@[ -d node_modules ] || npm ci
	BASE_URL="$(URL)" npm run smoke
