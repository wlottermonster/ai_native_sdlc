#!/bin/bash
# AI-Native SDLC — traceability matrix generator.
# For each specs/<feature>/, writes specs/<feature>/matrix.html:
# one row per REQ-ID with Planned / Tested / Deferred status. Red = uncovered.
# Run manually or at the end of a feature; it never blocks anything.
set -u
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo" >&2; exit 1; }
cd "$top" || { echo "cannot cd to repo root $top" >&2; exit 1; }
[ -d specs ] || { echo "no specs/ directory" >&2; exit 1; }

testfiles=$(git ls-files -co --exclude-standard 2>/dev/null \
  | grep -vE '^specs/' \
  | grep -E '(^|/)(tests?|__tests__)/|(^|/)test_[^/]*$|_test\.[^/.]+$|\.(test|spec)\.[^/.]+$' \
  | grep -vE '\.(md|txt|rst|html)$' || true)

for req in specs/*/requirements.md; do
  [ -f "$req" ] || continue
  feat=$(basename "$(dirname "$req")")
  tasks="specs/$feat/tasks.md"
  outfile="specs/$feat/matrix.html"
  ids=$(grep -oE 'REQ-[A-Z0-9-]+-[0-9]{3}' "$req" | sort -u)
  [ -n "$ids" ] || continue
  deferred=$(awk 'match($0, /REQ-[A-Z0-9-]+-[0-9]{3}/){cur=substr($0,RSTART,RLENGTH)} /verify:[ ]*deferred/{if(cur!="") print cur}' "$req" | sort -u)

  {
    echo "<!doctype html><meta charset='utf-8'><title>Trace matrix: $feat</title>"
    echo "<style>body{font-family:-apple-system,sans-serif;margin:32px;background:#F7F8FA;color:#1B2430}"
    echo "table{border-collapse:collapse}td,th{border:1px solid #DDE3EA;padding:8px 14px;font-size:14px}"
    echo "th{background:#ECEFF2;text-align:left}.ok{background:#E9F1E3}.bad{background:#F8E1DE}.warn{background:#F7ECDD}</style>"
    echo "<h2>Traceability — $feat</h2><p>Generated $(date '+%Y-%m-%d %H:%M'). Red = requirement with no coverage.</p>"
    echo "<table><tr><th>Requirement</th><th>Planned (in tasks)</th><th>Tested (tagged test)</th></tr>"
    for id in $ids; do
      if echo "$deferred" | grep -qx "$id"; then
        echo "<tr class='warn'><td>$id</td><td colspan='2'>DEFERRED (owner decision)</td></tr>"
        continue
      fi
      planned="bad"; tested="bad"
      [ -f "$tasks" ] && grep -q "$id" "$tasks" && planned="ok"
      if [ -n "$testfiles" ]; then
        [ -n "$(echo "$testfiles" | tr '\n' '\0' | xargs -0 grep -l -- "$id" 2>/dev/null)" ] && tested="ok"
      fi
      echo "<tr><td>$id</td><td class='$planned'>$([ $planned = ok ] && echo YES || echo NO)</td><td class='$tested'>$([ $tested = ok ] && echo YES || echo NO)</td></tr>"
    done
    echo "</table>"
  } > "$outfile"
  echo "wrote $outfile"
done
