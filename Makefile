# The one command surface (spec NFR-6). These are the template repo's own
# targets; bootstrap (M2) replaces them with the chosen stack's.
#
#   make lint [FILE=path]   shellcheck, actionlint, markdownlint
#   make fmt  [FILE=path]   shfmt (skipped if not installed)
#   make test               every executable tests/scripts/test_*.sh

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

MARKDOWNLINT := npx --yes markdownlint-cli2@0.24.0
SHFMT_FLAGS := -i 2 -ci

# Shell files: tracked *.sh plus extensionless files under scripts/hooks/ and
# deploy/targets/<target>/ (the adapter verbs).
SH_FILES = $$( { git ls-files -- '*.sh'; git ls-files -- 'scripts/hooks/*' 'deploy/targets/*/*' | grep -v '/[^/]*\.[^/]*$$' || true; } | sort -u )

.PHONY: help lint fmt test typecheck build acceptance smoke

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

test: ## Run every executable tests/scripts/test_*.sh
	@pass=0; fail=0; failed=""; \
	for t in tests/scripts/test_*.sh; do \
	  [[ -x "$$t" ]] || continue; \
	  echo "== $$t"; \
	  if "$$t"; then pass=$$((pass + 1)); else fail=$$((fail + 1)); failed="$$failed $$t"; fi; \
	done; \
	echo "test summary: $$pass passed, $$fail failed"; \
	if [[ $$fail -gt 0 ]]; then echo "failed:$$failed"; exit 1; fi

typecheck: ## Type-check (n/a for the template)
	@echo "typecheck: n/a (template repo)"

build: ## Build the deploy artifact (n/a for the template)
	@echo "build: n/a (template repo)"

acceptance: ## Acceptance suite (n/a for the template)
	@echo "acceptance: n/a (template repo)"

smoke: ## prod-safe smoke tests (n/a for the template)
	@echo "smoke: n/a (template repo)"
