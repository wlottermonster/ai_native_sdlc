#!/bin/bash
# AI-Native SDLC — test runner. Executes every tests/test_*.sh in its own bash
# process, prints PASS/FAIL per file and the count of files executed, and exits
# non-zero if any file failed — or if it found no test files at all, since an
# empty suite must never read as a pass (REQ-GCORE-033).
set -u

here=$(cd "$(dirname "$0")" && pwd)

count=0
failed=0

for t in "$here"/test_*.sh; do
  [ -f "$t" ] || continue
  count=$((count + 1))
  name=$(basename "$t")
  printf '== %s\n' "$name"
  if bash "$t"; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name" >&2
    failed=$((failed + 1))
  fi
done

printf 'test files executed: %d\n' "$count"

if [ "$count" -eq 0 ]; then
  printf 'no test files found: %s/test_*.sh matched nothing — an empty suite is not a pass\n' \
    "$here" >&2
  exit 1
fi

if [ "$failed" -gt 0 ]; then
  printf '%d test file(s) failed\n' "$failed" >&2
  exit 1
fi

exit 0
