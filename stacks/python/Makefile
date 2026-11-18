SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := lint
MAKEFLAGS += --no-print-directory

PYTHON ?= python3
VENV := .venv
BIN := $(VENV)/bin
# The venv is rebuilt whenever requirements-dev.txt changes.
STAMP := $(VENV)/.installed

.PHONY: install fmt lint typecheck test build build-static acceptance smoke

$(STAMP): requirements-dev.txt
	$(PYTHON) -m venv $(VENV)
	$(BIN)/pip install --quiet --disable-pip-version-check --require-hashes -r requirements-dev.txt
	touch $(STAMP)

install: $(STAMP) ## Create .venv with the hash-pinned dev tools

fmt: $(STAMP) ## Format with ruff
	$(BIN)/ruff format .
	$(BIN)/ruff check --fix .

lint: $(STAMP) ## Lint and check formatting with ruff
	$(BIN)/ruff check .
	$(BIN)/ruff format --check .

typecheck: $(STAMP) ## Type-check with mypy --strict
	$(BIN)/mypy

test: $(STAMP) ## Run unit tests with pytest
	$(BIN)/pytest -q tests

build: ## Build the app:local image
	docker build -t app:local .

build-static: ## Render the GET routes to dist/static (static hosts such as GitHub Pages)
	rm -rf dist/static
	PYTHONPATH=src $(PYTHON) -m app.export dist/static

acceptance: $(STAMP) ## Run the acceptance suite against the compose container
	@trap 'rc=$$?; docker compose down -v --remove-orphans || true; exit $$rc' EXIT; \
	docker compose up -d --build --wait; \
	BASE_URL=http://localhost:8080 $(BIN)/pytest -q acceptance

smoke: $(STAMP) ## Run the prod_safe checks against URL=<url>
	@if [[ -z "$(URL)" ]]; then echo "error: URL is required (usage: make smoke URL=http://localhost:8080)" >&2; exit 1; fi
	BASE_URL="$(URL)" $(BIN)/pytest -q -m prod_safe acceptance
