# The one command surface (spec NFR-6). Repo-level checks run here; once
# bootstrap has written `stack: <name>` to deploy.yml, every target also runs
# the same target in stacks/<name>/ (spec §4.1: the Makefile delegates).
#
#   make lint [FILE=path]   shellcheck, actionlint, markdownlint (+ stack lint)
#   make fmt  [FILE=path]   shfmt, skipped if not installed (+ stack fmt)
#   make test               every executable tests/scripts/test_*.sh (+ stack tests)
#   make typecheck | build | build-static | acceptance | smoke URL=<url>   the stack's targets
#   make bootstrap STACK=<stack> TARGET=<target>            set up a new project
#   make bootstrap-target                                   provision deploy.yml's target (switch)
#   make doctor                                             read-only setup check

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

MARKDOWNLINT := npx --yes markdownlint-cli2@0.24.0
SHFMT_FLAGS := -i 2 -ci

# Shell files: tracked *.sh plus extensionless files under scripts/hooks/ and
# deploy/targets/<target>/ (the adapter verbs).
SH_FILES = $$( { git ls-files -- '*.sh'; git ls-files -- 'scripts/hooks/*' 'deploy/targets/*/*' | grep -v '/[^/]*\.[^/]*$$' || true; } | sort -u )

.PHONY: help lint fmt test typecheck build build-static acceptance smoke bootstrap bootstrap-target doctor

# stacks/<name> from deploy.yml's `stack:` key; empty in the template itself.
STACK_DIR := $(shell sed -n 's/^stack:[[:space:]]*\([a-z0-9-]*\).*/stacks\/\1/p' deploy.yml 2>/dev/null)

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(firstword $(MAKEFILE_LIST)) | \
	  awk 'BEGIN { FS = ":.*## " } { printf "  %-12s %s\n", $$1, $$2 }'

lint: ## Lint everything, or only FILE=<path>
ifdef FILE
	@f="$(FILE)"; f="$${f#"$$PWD/"}"; \
	if [[ ! -f "$$f" ]]; then echo "lint: skip $$f (no such file)"; exit 0; fi; \
	case "$$f" in \
	  *.sh) shellcheck "$$f" ;; \
	  scripts/hooks/*.* | deploy/targets/*/*.*) echo "lint: skip $$f (no linter for this type)" ;; \
	  scripts/hooks/* | deploy/targets/*/*) shellcheck "$$f" ;; \
	  .github/workflows/*.yml | .github/workflows/*.yaml) actionlint "$$f" ;; \
	  *.md) $(MARKDOWNLINT) ":$$f" ;; \
	  *) echo "lint: skip $$f (no linter for this type)" ;; \
	esac
else
	@echo "== shellcheck"; files="$(SH_FILES)"; \
	if [[ -n "$$files" ]]; then tr '\n' '\0' <<<"$$files" | xargs -0 shellcheck; fi
	@echo "== actionlint"; actionlint
	@echo "== markdownlint"; files="$$(git ls-files -- '*.md')"; \
	if [[ -n "$$files" ]]; then sed 's/^/:/' <<<"$$files" | tr '\n' '\0' | xargs -0 $(MARKDOWNLINT); fi
	@if [[ -n "$(STACK_DIR)" ]]; then echo "== stack lint ($(STACK_DIR))"; $(MAKE) -C "$(STACK_DIR)" lint; fi
endif

fmt: ## Format shell files with shfmt, or only FILE=<path>
	@if ! command -v shfmt >/dev/null 2>&1; then \
	  echo "fmt: shfmt not installed, skipping (brew install shfmt)"; exit 0; fi; \
	if [[ -n "$(FILE)" ]]; then \
	  f="$(FILE)"; f="$${f#"$$PWD/"}"; \
	  if [[ ! -f "$$f" ]]; then echo "fmt: skip $$f (no such file)"; exit 0; fi; \
	  case "$$f" in \
	    *.sh) shfmt $(SHFMT_FLAGS) -w "$$f" ;; \
	    scripts/hooks/*.* | deploy/targets/*/*.*) echo "fmt: skip $$f (no formatter for this type)" ;; \
	    scripts/hooks/* | deploy/targets/*/*) shfmt $(SHFMT_FLAGS) -w "$$f" ;; \
	    *) echo "fmt: skip $$f (no formatter for this type)" ;; \
	  esac; \
	else \
	  files="$(SH_FILES)"; \
	  if [[ -n "$$files" ]]; then tr '\n' '\0' <<<"$$files" | xargs -0 shfmt $(SHFMT_FLAGS) -w; fi; \
	fi
	@if [[ -z "$(FILE)" && -n "$(STACK_DIR)" ]]; then $(MAKE) -C "$(STACK_DIR)" fmt; fi

test: ## Run every executable tests/scripts/test_*.sh, and tests/broker with node
	@pass=0; fail=0; failed=""; \
	for t in tests/scripts/test_*.sh; do \
	  [[ -x "$$t" ]] || continue; \
	  echo "== $$t"; \
	  if "$$t"; then pass=$$((pass + 1)); else fail=$$((fail + 1)); failed="$$failed $$t"; fi; \
	done; \
	if [[ -d tests/broker ]]; then \
	  if command -v node >/dev/null 2>&1; then \
	    echo "== tests/broker (node --test)"; \
	    if [[ -f broker/package-lock.json && ! broker/node_modules/.package-lock.json -nt broker/package-lock.json ]]; then npm ci --ignore-scripts --no-audit --no-fund --prefix broker >/dev/null; fi; \
	    if node --test tests/broker/*.test.mjs; then pass=$$((pass + 1)); else fail=$$((fail + 1)); failed="$$failed tests/broker"; fi; \
	  elif [[ -n "$${CI:-}" ]]; then \
	    echo "== tests/broker: node is not installed (required in CI)"; fail=$$((fail + 1)); failed="$$failed tests/broker"; \
	  else echo "== tests/broker: skipped (node not installed)"; fi; \
	fi; \
	echo "test summary: $$pass passed, $$fail failed"; \
	if [[ $$fail -gt 0 ]]; then echo "failed:$$failed"; exit 1; fi
	@if [[ -n "$(STACK_DIR)" ]]; then echo "== stack tests ($(STACK_DIR))"; $(MAKE) -C "$(STACK_DIR)" test; fi

typecheck: ## Type-check the stack (n/a before bootstrap)
	@$(call stack,typecheck)

build: ## Build the deploy artifact (n/a before bootstrap)
	@$(call stack,build)

build-static: ## Render the GET routes to the stack's dist/static (static targets; n/a before bootstrap)
	@$(call stack,build-static)

acceptance: ## Acceptance suite (n/a before bootstrap)
	@$(call stack,acceptance)

smoke: ## prod-safe smoke tests against URL=<url> (n/a before bootstrap)
	@$(call stack,smoke URL="$(URL)")

bootstrap: ## Set up a new project: STACK=<stack> TARGET=<target>
	@scripts/bootstrap.sh --stack "$(STACK)" --target "$(TARGET)"

bootstrap-target: ## Provision the target named in deploy.yml (switch targets; no workflow changes)
	@scripts/bootstrap-target.sh

doctor: ## Read-only check that repo settings and the target match the spec
	@scripts/doctor.sh

# $(call stack,<target and args>): run it in the stack, or say n/a.
stack = if [[ -n "$(STACK_DIR)" ]]; then $(MAKE) -C "$(STACK_DIR)" $(1); \
  else echo "$(firstword $(1)): n/a (no stack yet; run make bootstrap)"; fi
