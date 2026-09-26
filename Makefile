# AI-Native SDLC — the framework gates itself with the same two targets it
# asks every repo it installs into to provide.
#
#   make check   syntax + lint + config validity   (REQ-GCORE-029/039/040)
#   make test    the shell test suite              (REQ-GCORE-030)

TEST_PROFILE = lib

# Everything that must parse and lint. Globs are expanded by the shell in the
# recipes below; each recipe skips a pattern that matched nothing.
SHELL_SOURCES = hooks/*.sh scripts/*.sh install.sh publish.sh push.sh tests/*.sh

.PHONY: check test

check:
	@for f in $(SHELL_SOURCES); do \
	  [ -f "$$f" ] || continue; \
	  bash -n "$$f" || exit 1; \
	done
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo "make check: shellcheck is not installed or not on PATH." >&2; \
	  echo "  Install it (brew install shellcheck) and re-run." >&2; \
	  echo "  This check is mandatory: a skipped lint must not read as a pass." >&2; \
	  exit 1; \
	}
	@files=""; \
	  for f in $(SHELL_SOURCES); do [ -f "$$f" ] && files="$$files $$f"; done; \
	  if [ -n "$$files" ]; then shellcheck -x $$files || exit 1; fi
	@jq -e . settings/hooks-snippet.json >/dev/null
	@gate="hooks/req-gate.sh"; \
	  [ -f "$$gate" ] || gate="$$HOME/.claude/hooks/req-gate.sh"; \
	  [ -f "$$gate" ] || { \
	    echo "make check: no req-gate.sh (looked in hooks/ and ~/.claude/hooks)." >&2; \
	    exit 1; \
	  }; \
	  bash "$$gate" || exit $$?
	@python3.12 adapters/codex/scripts/validate.py
	@python3.12 -m unittest discover -s tests/codex -v
	@echo "check: OK"

test:
	@tests/run.sh
	@python3.12 -m unittest discover -s tests/codex -v
