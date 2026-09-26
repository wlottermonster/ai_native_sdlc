# Design — gate-fail-open-2

**Docs-only shortcut (REQ-GATE-014, REQ-GATE-017).** The index can only tell
the gate what the commit contains if nothing in the command changes the index
first. Listing the staging forms to refuse would be a blacklist, and the next
one would not be on it. So the decision is a whitelist: `index_only` tokenises
the heredoc-stripped command (quote-aware, redirections dropped) into commands
and allows the shortcut only for `cd` steps plus exactly one git invocation —
the commit — whose global options are `-C`/`-c` and whose commit options are
drawn from a fixed list that cannot change content (`-m`, `-F`, `-q`, `-s`,
`--amend`, …). Anything else, including an unterminated quote or an unknown
option, runs the full check. The one command substitution allowed is the bare
`"$(cat <<'EOF' … EOF)"` message, whose body the heredoc pass already removed.

On the shortcut the gate skips `make` and still runs req-gate.sh, so the
commit that ticks the last box is coverage-checked at commit time.

**Requirement gate exit (REQ-GATE-015, REQ-GATE-016).** `run_req_gate` runs
req-gate.sh with its output captured; any non-zero exit becomes exit 2 with
that output attached, and a missing req-gate.sh is exit 2 naming both paths it
looked in. req-gate.sh keeps exit 1 for "cannot verify": as a Stop hook it
drains stdin and cannot read `stop_hook_active`, so a blocking exit there could
loop. The mapping lives in the caller that has no such loop.

**Siblings (REQ-GATE-019, REQ-GATE-020).** The sweep found the same
presence-then-assume shape twice more: req-gate.sh globbed `specs/*/` and read
an unreadable file or directory as "no IDs", and check-gate.sh read an
unreadable package.json as "no contract". Both now refuse.

**Pre-push guard (REQ-GATE-018).** `publish.sh --install-guard` writes beside
the hook, moves it over and self-tests the result, so it is idempotent; push.sh
now runs it on every push instead of only when the marker line is missing.

**Known, not closed.** A git pre-commit hook (lint-staged and the like) can
stage files during the commit itself, after this gate read the index. The gate
cannot see that from the command text.
