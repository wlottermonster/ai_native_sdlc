# Requirements — postcompact-policy

<!-- Shipped as a small change under the proportionate-process rule; this
     record exists so the seven IDs its test carries are defined by a spec
     and the orphan check stays meaningful. The hook re-injects the routing
     section of the policy after compaction instead of the whole file. -->

REQ-POLICY-001  WHEN the PostCompact hook runs and the policy file carries the
                routing heading, THE HOOK SHALL inject only the text from that
                heading to the end of the file, the heading first.
                verify: integration

REQ-POLICY-002  WHEN the policy file carries no routing heading, THE HOOK SHALL
                inject the whole file rather than nothing.
                verify: integration

REQ-POLICY-003  WHEN the policy file is missing or unreadable, THE HOOK SHALL
                emit valid JSON whose context says so by name, and exit 0.
                verify: integration

REQ-POLICY-004  WHEN a large payload is piped to the hook, IT SHALL drain
                stdin first and still exit 0 with the injection.
                verify: integration

REQ-POLICY-005  WHEN jq is not on PATH, THE HOOK SHALL emit hand-built valid
                JSON naming the gap and exit 0.
                verify: integration

REQ-POLICY-006  WHEN the hooks snippet is read, ITS PostCompact entry SHALL name
                the hook script and no longer an inline jq command.
                verify: integration

REQ-POLICY-007  WHEN the shipped policy file is read, IT SHALL carry the
                routing heading, and the hook run on it SHALL keep the routing
                table and drop the first half.
                verify: integration
