#!/bin/bash
# AI-Native SDLC — commit gate (PreToolUse on Bash).
# Blocks a git commit while the repo's checks fail. Exit 2 = block; the failure
# output lands back in the model's context so it can fix and retry.
#
# RULE — every `exit 0` in a gate is an ALLOW and must be justified as one. A
# gate that cannot verify must block, never fall through: absence of a block is
# not evidence the checks passed.
# RULE — `[ -d dir ]` says a directory exists; it does NOT say `cd dir` will
# succeed (permissions, a stale mount). Test the OPERATION, not the predicate,
# and treat a failed `cd` as unverifiable — never continue in whatever
# directory the gate happened to inherit.
# RULE — a PreToolUse hook that outlives its timeout does NOT block the tool.
# So this gate keeps its own clock (REQ-GATE-004): it reads the timeout it was
# installed with, stops the checks before that deadline, and refuses the commit
# when they did not finish. A loud refusal, never a silent allow.
set -u

# Seconds the gate stops the checks BEFORE the hook's own timeout would fire.
# The margin is what turns a silent harness timeout into a refusal this script
# gets to write; it has to cover killing the checks and printing the message.
GATE_MARGIN=30

# The shape of a commit in shell text (REQ-GATE-002, REQ-GATE-003, REQ-GATE-011).
# `git` must stand as a command word: preceded by nothing, whitespace, a quote
# or a shell operator — never by a path or word character, so
# `.git/hooks/pre-commit` and `mygit` do not count while `/usr/bin/git commit`
# still does. `commit` must be a whole word after whitespace, so `--no-commit`
# and `pre-commit` do not count either, and it may be followed by whitespace, a
# separator, a closing paren, a QUOTE (`bash -c "git commit"`) or the end.
# Anything between the two words may not cross a pipe or a command separator,
# so `git log | grep commit` is not a commit. A quoted "git commit" still
# matches on purpose: it can reach `eval`, and this gate fails closed.
COMMIT_RE='(^|[^A-Za-z0-9_.-])git[[:space:]]([^|;&]*[[:space:]])?commit([[:space:];&|)"'"'"'`]|$)'

# gate_cannot_verify <what-it-could-not-do> <path> — the gate could not reach
# the repo the commit targets, so it refuses the commit and says so. It never
# falls back to checking some other directory: a green check in repo X is no
# evidence at all about a commit in repo Y.
gate_cannot_verify() {
  {
    echo "COMMIT BLOCKED by AI-Native SDLC gate: the gate could not verify this commit."
    echo "It could not $1:"
    echo "  $2"
    echo "A directory can exist and still refuse cd (permissions, a stale mount)."
    echo "The gate never allows a commit whose checks it could not run, and never"
    echo "runs them somewhere else instead. Fix the path above, then commit again."
  } >&2
  exit 2
}

input=$(cat 2>/dev/null || true)

# Without jq the payload cannot be parsed, and an unparsed payload used to read
# as "not a commit" — every commit went through ungated (REQ-GATE-011). Now the
# RAW payload is scanned instead: a commit-shaped payload is refused with the
# reason, anything else is allowed. The raw JSON carries the command text with
# `\n` for newlines, so a one-line commit still matches the shape.
if ! command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | grep -qE "$COMMIT_RE"; then
    gate_cannot_verify "parse the hook payload — jq is not on PATH, and this looks like a commit" "PATH=$PATH"
  fi
  exit 0   # no jq and nothing commit-shaped in the payload → nothing to gate
fi

# Self-filter on the hook payload: only gate commands that actually run
# `git commit`. (A settings-level `if: "Bash(git commit*)"` prefix filter
# misses compound commands like `cd repo && git commit` — so we filter here.)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
# A backslash-newline is one line to the shell; make it one line here too, or
# `git \` + newline + `commit` slips past a line-oriented grep (REQ-GATE-011).
cmd=${cmd//\\$'\n'/ }

# A HEREDOC BODY IS DATA, NOT SHELL — strip bodies before deciding (REQ-GATE-001).
# The filter below greps the command text, so a command that merely WRITES
# ABOUT commits used to match it: an issue-filing command whose body documented
# this very gate was treated as a commit, ran the repo's whole suite, and —
# because that suite was red for an unrelated reason — refused a command that
# touched no code.
#
# ONLY heredoc bodies are removed, and only when the heredoc is not being FED
# TO A SHELL: `bash <<EOF`, `sh -s <<EOF`, `ssh host <<EOF`, `eval` and the
# script interpreters execute their body, so those bodies stay in the scan
# (REQ-GATE-011). Quoted strings are NOT removed: the same words inside quotes
# can still reach `eval`, and this gate fails CLOSED. Anchoring the match to a
# command position was considered and REJECTED: it would stop matching
# `cd r && (…)`, a newline-separated one, and command substitution — trading a
# harmless false positive for real fail-open holes, which is the wrong direction
# for a gate whose whole rule is that absence of a block proves nothing.
#
# An UNTERMINATED heredoc would swallow the rest of the command and could hide a
# real one, so awk exits nonzero there and the raw text is scanned instead.
scan=$(printf '%s' "$cmd" | awk '
  BEGIN { skip = 0; delim = "" }
  skip == 1 {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line == delim) { skip = 0 }
    next
  }
  {
    print
    if (match($0, /<<-?[ \t]*("[^"]+"|'"'"'[^'"'"']+'"'"'|[A-Za-z_][A-Za-z0-9_]*)/)) {
      head = substr($0, 1, RSTART - 1)
      # the consumer of the body is a shell or an interpreter: the body is code
      if (head ~ /(^|[^A-Za-z0-9_.\/-])(bash|sh|zsh|dash|ksh|ssh|eval|source|python[0-9.]*|perl|ruby|node)([ \t]|$)/) next
      d = substr($0, RSTART, RLENGTH)
      sub(/^<<-?[ \t]*/, "", d)
      gsub(/["'"'"']/, "", d)
      delim = d; skip = 1
    }
  }
  END { if (skip == 1) exit 3 }
') || scan="$cmd"

printf '%s' "$scan" | grep -qE "$COMMIT_RE" || exit 0

# The hook runs from the SESSION's cwd, which may not be the repo the command
# targets (compound commands routinely `cd <repo> && git commit`). Follow the
# command's cd when it names one — the LAST cd that comes BEFORE the commit
# (REQ-GATE-012): `cd a && cd b && git commit` commits in b, and a cd AFTER the
# commit says nothing about where it ran. Taking the first cd on the first line
# used to check repo a and allow the commit on a's result. Quoted paths, leading
# `cd` options (`-P`, `--`) and a `cd` on an earlier line are all handled by the
# same pass; `cd -` names no path and is dropped below. Whichever directory is
# chosen, ENTERING it is the test — if the cd fails the gate has no idea which
# repo it would be checking, so it blocks instead of guessing.
cdtarget=$(printf '%s' "$scan" | perl -e '
  local $/; my $s = <STDIN>;
  my $re = qr/(?:^|[^A-Za-z0-9_.\-])git[ \t](?:[^|;&\n]*[ \t])?commit(?:[ \t;&|)"\x27`]|$)/m;
  exit 0 unless $s =~ $re;
  my $pre = substr($s, 0, $-[0] + 1);
  my $last = "";
  while ($pre =~ /(?:^|[;&|(\s])cd[ \t]+((?:-[A-Za-z]+[ \t]+|--[ \t]+)*)("([^"]*)"|\x27([^\x27]*)\x27|([^;&|\s]+))/mg) {
    $last = defined $3 ? $3 : defined $4 ? $4 : $5;
  }
  print $last;
' 2>/dev/null || true)
# `cd -` is the one argument that names no path (it means $OLDPWD, which this
# process does not share with the command's shell); treat it as "no cd target"
# and fall back to the payload cwd, as before.
# A path that does not EXIST was never a followable path: an unexpanded shell
# variable, text inside a heredoc, a path meaningful only in the command's own
# shell. Falling through to the payload cwd is what this did before and is
# right — blocking there would refuse every script that changes directory
# through a variable. The fail-open this guard closes is the OTHER case: the
# directory EXISTS and cd still fails, which is where the gate would otherwise
# silently run its checks somewhere else.
case "$cdtarget" in -*) cdtarget="" ;; esac
# A leading `~`, `$HOME` or `${HOME}` names the user's home in the command's
# shell; expand it the same way here (REQ-GATE-010). Left alone, `cd ~/repo &&
# git commit` is an unfollowable path, the gate falls through to the payload
# cwd, and it checks whichever repository the SESSION was standing in — a green
# check there is no evidence about the repo the commit lands in.
case "$cdtarget" in
  \~|\$HOME|\$\{HOME\}) cdtarget="$HOME" ;;
  \~/*) cdtarget="$HOME/${cdtarget#\~/}" ;;
  \$HOME/*) cdtarget="$HOME/${cdtarget#\$HOME/}" ;;
  \$\{HOME\}/*) cdtarget="$HOME/${cdtarget#\$\{HOME\}/}" ;;
esac
if [ -n "$cdtarget" ] && [ -d "$cdtarget" ]; then
  cd "$cdtarget" \
    || gate_cannot_verify "enter the directory the command cd's into" "$cdtarget"
else
  hookcwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
  # No .cwd in the payload → the gate is already running in the session's cwd,
  # which is the same directory; that is the only case with nowhere to go.
  [ -n "$hookcwd" ] && [ -d "$hookcwd" ] \
    && { cd "$hookcwd" \
         || gate_cannot_verify "enter the session directory from the hook payload" "$hookcwd"; }
fi
# also honor `git -C <repo> commit`
gitc=$(printf '%s' "$scan" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+("([^"]+)"|'\''([^'\'']+)'\''|([^;&|[:space:]]+))[^|;&]*commit.*/\2\3\4/p')
# Same rule for the -C argument: an unresolvable one is not a followable path,
# and sessions legitimately pass a variable there. Only an existing directory
# that refuses entry means the gate cannot verify.
[ -n "$gitc" ] && [ -d "$gitc" ] \
  && { cd "$gitc" \
       || gate_cannot_verify "enter the directory named by 'git -C'" "$gitc"; }

top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0   # not a repo → allow
cd "$top" || gate_cannot_verify "enter the repository root git reported" "$top"

# --- the requirement gate (REQ-GATE-015, REQ-GATE-016) ----------------------
# run_req_gate — runs req-gate.sh and ends this script: exit 0 only when the
# coverage gate itself exited 0. The framework checkout carries
# hooks/req-gate.sh and that copy is the source of truth there; every other
# repo runs the installed copy. req-gate.sh exits 1 for "could not verify"
# because it also runs as a Stop hook, where a blocking exit on a condition the
# model cannot fix would have no loop break. Here, in PreToolUse, there is no
# loop: exit 1 does NOT block a tool call, so passing it through was an allow.
# Every non-zero exit is therefore a block, with req-gate's own words attached.
run_req_gate() {
  local rgate="$top/hooks/req-gate.sh" rg_out rg_rc=0
  [ -f "$rgate" ] || rgate="$HOME/.claude/hooks/req-gate.sh"
  if [ ! -f "$rgate" ]; then
    {
      echo "COMMIT BLOCKED by AI-Native SDLC gate: the requirement gate (req-gate.sh) was not found."
      echo "Looked in:"
      echo "  $top/hooks/req-gate.sh"
      echo "  $HOME/.claude/hooks/req-gate.sh"
      echo "Requirement coverage could not be checked, and a gate that cannot verify never"
      echo "allows. Run install.sh from the framework checkout, then commit again."
    } >&2
    exit 2
  fi
  rg_out=$(bash "$rgate" < /dev/null 2>&1) || rg_rc=$?
  if [ "$rg_rc" -ne 0 ]; then
    {
      echo "COMMIT BLOCKED by AI-Native SDLC gate: the requirement gate refused (exit $rg_rc)."
      echo "Fix what it reports below, then commit again."
      echo "--- req-gate.sh ($rgate) ---"
      printf '%s\n' "$rg_out"
    } >&2
    exit 2
  fi
  [ -z "$rg_out" ] || printf '%s\n' "$rg_out"
  exit 0
}

# --- docs-only commits (REQ-GATE-013, REQ-GATE-014, REQ-GATE-017) -----------
# A docs-only commit skips `make check`: every staged file is prose by
# EXTENSION (a `docs/generate.py` is code wherever it lives). It still runs the
# requirement gate — ticking the last box in tasks.md is a prose-only commit,
# and it is the very commit that claims completion.
#
# The index is read NOW, when the hook runs — not when the commit runs. So the
# shortcut is taken only when the command provably commits the index exactly
# as it stands: `git add code.py && git commit`, `git commit -a`, a pathspec,
# `--include`/`--only`/`-p`, a GIT_* environment override, or any command
# substitution that could stage would all make the answer read here a lie.
# index_only exits 0 only for a command made of `cd` steps and ONE git
# invocation, that commit, carrying nothing but options known not to change
# its content. Anything it does not recognise — an unknown option, a second
# command, an unterminated quote — means "run the full check".
index_only() {
  printf '%s' "$scan" | perl -e '
    local $/; my $s = <STDIN>; $s = "" unless defined $s;
    my (@cmds, @cur); my ($w, $inword, $skip) = ("", 0, 0);
    sub endword { if ($inword) { if ($skip) { $skip = 0 } else { push @cur, $w } } $w = ""; $inword = 0 }
    sub endcmd { endword(); push @cmds, [@cur] if @cur; @cur = () }
    my ($i, $n) = (0, length $s);
    while ($i < $n) {
      my $c = substr($s, $i, 1);
      if ($c eq "\x27") {
        my $j = index($s, "\x27", $i + 1); exit 1 if $j < 0;
        $w .= substr($s, $i + 1, $j - $i - 1); $inword = 1; $i = $j + 1; next;
      }
      if ($c eq "\"") {
        my ($j, $buf) = ($i + 1, "");
        while ($j < $n) {
          my $d = substr($s, $j, 1);
          if ($d eq "\\") { $buf .= substr($s, $j, 2); $j += 2; next }
          last if $d eq "\"";
          $buf .= $d; $j++;
        }
        exit 1 if $j >= $n;
        # A command substitution inside a quoted word runs code. The one
        # shape allowed is a bare `$(cat <<EOF ...)` whose body is already
        # stripped: a commit message, nothing else.
        if ($buf =~ /\$\(|`/) {
          exit 1 unless $buf =~ /\A\$\(\s*cat\s+<<-?\s*(["\x27]?)[A-Za-z_][A-Za-z0-9_]*\1\s*\)\z/;
        }
        $w .= $buf; $inword = 1; $i = $j + 1; next;
      }
      if ($c eq "\\") { $w .= substr($s, $i + 1, 1); $inword = 1; $i += 2; next }
      if ($c eq "`") { exit 1 }
      if ($c =~ /[ \t]/) { endword(); $i++; next }
      if ($c =~ /[\n;&|(){}]/) { endcmd(); $i++; next }
      if ((!$inword && substr($s, $i) =~ /\A(\d*(?:<<<|<<-|<<|<>|>>|>\||<&|>&|<|>))/)
          || substr($s, $i) =~ /\A((?:<<<|<<-|<<|<>|>>|>\||<&|>&|<|>))/) {
        endword(); $i += length $1; $skip = 1; next;   # drop the redirection target
      }
      $w .= $c; $inword = 1; $i++;
    }
    endcmd();
    my %val = map { $_ => 1 } qw(-m -F -C -c -t --message --file --reuse-message
      --reedit-message --template --author --date --fixup --squash --cleanup --trailer);
    my %flag = map { $_ => 1 } qw(-q --quiet -s --signoff --no-signoff -v --verbose
      -n --no-verify --verify -e --edit --no-edit --amend --allow-empty
      --allow-empty-message --no-gpg-sign --gpg-sign --reset-author --status
      --no-status --dry-run --no-post-rewrite --untracked-files -u);
    my %eqok = map { $_ => 1 } (keys %val, "--gpg-sign", "--untracked-files");
    my $commits = 0;
    for my $cmd (@cmds) {
      my @a = @$cmd;
      exit 1 if $a[0] =~ /\A[A-Za-z_][A-Za-z0-9_]*=/;   # GIT_INDEX_FILE=… and kin
      next if $a[0] eq "cd";
      exit 1 unless $a[0] =~ m{(\A|/)git\z};
      exit 1 if $commits++;                             # a second git invocation
      my $k = 1;
      while ($k < @a && $a[$k] ne "commit") {
        exit 1 unless $a[$k] eq "-C" || $a[$k] eq "-c"; # --git-dir, --work-tree, …
        $k += 2;
      }
      exit 1 unless $k < @a;
      $k++;
      while ($k < @a) {
        my $t = $a[$k++];
        if ($val{$t}) { exit 1 if $k >= @a; $k++; next }
        next if $flag{$t};
        if ($t =~ /\A(--[a-z-]+)=/) { next if $eqok{$1}; exit 1 }
        if ($t =~ /\A-([A-Za-z].*)\z/s) {
          my $cl = $1;
          while (length $cl) {
            my $ch = substr($cl, 0, 1, "");
            next if $ch =~ /[qsvne]/;
            if ($ch eq "S") { last }
            if ($ch =~ /[mFCct]/) { if ($cl eq "") { exit 1 if $k >= @a; $k++ } last }
            exit 1;                                     # -a, -i, -o, -p, …
          }
          next;
        }
        exit 1;                                         # a pathspec, `--`, or unknown
      }
    }
    exit($commits == 1 ? 0 : 1);
  ' 2>/dev/null
}

if index_only; then
  staged=$(git diff --cached --name-only 2>/dev/null)
  if [ -n "$staged" ] && ! echo "$staged" | grep -qvE '\.(md|txt|rst|html?)$'; then
    run_req_gate
  fi
fi

# Present is not readable (REQ-GATE-013). Decided HERE, in the gate's own
# process, so the refusal reaches the reader: a refusal raised inside the
# check subshell would land in the captured output and never be printed.
if [ -f Makefile ] && [ ! -r Makefile ]; then
  gate_cannot_verify "read the Makefile to find a check target" "$PWD/Makefile"
fi
# The same for package.json when no Makefile check target comes first
# (REQ-GATE-020): unreadable, it failed the jq probe below and read as "no
# contract in this repo" — an allow earned by not being able to look.
if ! { [ -f Makefile ] && grep -qE '^check:' Makefile; } \
   && [ -f package.json ] && [ ! -r package.json ]; then
  gate_cannot_verify "read package.json to find a check script" "$PWD/package.json"
fi

run_check() {
  if [ -f Makefile ] && grep -qE '^check:' Makefile; then
    make check
  elif [ -f package.json ] && command -v jq >/dev/null 2>&1 \
       && jq -e '.scripts.check' package.json > /dev/null 2>&1; then
    npm run --silent check
  elif [ -x .venv/bin/pytest ]; then
    .venv/bin/pytest -x -q
  else
    return 0   # no contract in this repo yet → don't block
  fi
}

# --- the gate's own clock (REQ-GATE-004) ------------------------------------
# gate_clock — prints "<budget> <hook-timeout>". The hook timeout is the one
# this gate's own entry carries in the user's settings (the harness default of
# 600 when the entry has none, or when the settings cannot be read); the budget
# is that minus the margin. One number in one file decides both, so the two
# cannot drift apart.
gate_clock() {
  local settings="$HOME/.claude/settings.json" t="" b
  if [ -r "$settings" ]; then
    t=$(jq -r '[ .hooks.PreToolUse[]? | .hooks[]?
                 | select(((.command // "") | tostring) | test("check-gate"))
                 | (.timeout // 600) ] | min // empty' "$settings" 2>/dev/null || true)
  fi
  case "$t" in ''|*[!0-9]*) t=600 ;; esac
  b=$((t - GATE_MARGIN))
  [ "$b" -lt 1 ] && b=1
  printf '%s %s\n' "$b" "$t"
}

# run_bounded <outfile> <rcfile> <budget> — run the checks in their own process
# group so a kill reaches make AND everything make started, capturing output in
# <outfile> and the exit code in <rcfile>. Sets GATE_EXPIRED=1 and kills the
# whole group when the budget is spent. Polls once a second: the cost is at
# most one second per commit, and it needs no `timeout` binary (absent on
# some systems) and no job-control `wait` (whose "Terminated" notice would
# land in the hook's output). The poll ends when the exit code has been
# written OR the process is gone — so a child that lingers as a zombie can
# never make a finished check look like a hang.
GATE_EXPIRED=0
run_bounded() {
  local outfile="$1" rcfile="$2" budget="$3" pid waited=0
  set -m
  ( run_check; echo $? > "$rcfile" ) > "$outfile" 2>&1 &
  pid=$!
  set +m
  disown "$pid" 2>/dev/null
  while [ ! -s "$rcfile" ] && kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$budget" ]; then
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null
      GATE_EXPIRED=1
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

clock=$(gate_clock)
budget=${clock%% *}
hook_timeout=${clock##* }
outfile=$(mktemp "${TMPDIR:-/tmp}/sdlc-gate-out.XXXXXX") \
  || gate_cannot_verify "create a scratch file for the check output" "${TMPDIR:-/tmp}"
rcfile="$outfile.rc"
run_bounded "$outfile" "$rcfile" "$budget"
out=$(cat "$outfile" 2>/dev/null)
rc=""   # stays empty when the kill left no exit-code file — that is by design, not an error
[ -f "$rcfile" ] && rc=$(tr -d '[:space:]' < "$rcfile" 2>/dev/null || true)
rm -f "$outfile" "$rcfile"

if [ "$GATE_EXPIRED" -eq 1 ]; then
  {
    echo "COMMIT BLOCKED by AI-Native SDLC gate: the checks did not finish inside the gate's budget of ${budget}s."
    echo "The hook's timeout is ${hook_timeout}s, and a hook that times out does NOT block — so the gate"
    echo "stopped the checks ${GATE_MARGIN}s early and is refusing the commit rather than letting it through ungated."
    echo "Run the checks yourself (make check) and read the exit code, then commit again. Keep check the"
    echo "fast lane: slow work belongs in make test."
    echo "--- last 40 lines of output before the stop ---"
    echo "$out" | tail -40
  } >&2
  exit 2
fi
# No exit code recorded means the checks ended without writing one — a kill
# from outside, a full disk, a refusal raised inside the check itself. Whatever
# the checks printed is the reader's only clue, so it is shown first.
case "$rc" in ''|*[!0-9]*)
  if [ -n "$out" ]; then
    { echo "--- what the checks printed before ending without an exit code ---"; echo "$out" | tail -40; } >&2
  fi
  gate_cannot_verify "obtain an exit code from the checks" "$top" ;;
esac
if [ "$rc" -ne 0 ]; then
  {
    echo "COMMIT BLOCKED by AI-Native SDLC gate: checks failed (exit $rc)."
    echo "Fix the failures below, re-run the checks, then commit again."
    echo "--- last 40 lines ---"
    echo "$out" | tail -40
  } >&2
  exit 2
fi

# checks green → also enforce requirement coverage before the commit.
run_req_gate
