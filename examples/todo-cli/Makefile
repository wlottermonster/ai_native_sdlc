# AI-Native SDLC repo contract — the practice project, from templates/Makefile.python.
# The framework only ever calls `make check` and `make test` — keep those names.
# TEST_PROFILE tells agents how deep testing goes here: lib | api | webapp | static
TEST_PROFILE = lib

# Standard library only, so a trainee needs nothing but python3.12: the
# template's ruff / mypy / pytest lines become py_compile and unittest.
#
# TIMEOUT BUDGET: the commit gate runs `check` as a PreToolUse hook with a 600s
# timeout, and a hook that times out does NOT block — the gate stops the checks
# 30s before that timeout and blocks the commit instead. Keep `check` inside
# 600s; if it cannot fit, split the slow work into `test`.
PY = python3.12

check:  ## fast gate: every file compiles, then the fast tests
	$(PY) -m py_compile todo.py test_todo.py
	$(PY) -m unittest -q

test:   ## full suite
	$(PY) -m unittest -v

.PHONY: check test
