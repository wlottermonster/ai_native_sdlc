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

# The guards' shared library (REQ-TOUCH-047). Without `-e` a failed source
# would leave the guard functions undefined and fall through to the allows,
# so a library that cannot be sourced is a refusal. The directory is taken by
# parameter expansion, not dirname(1): this runs before any tool is proven to
# be on PATH, and a missing dirname would turn into a refusal of every command.
case "$0" in */*) guard_lib="${0%/*}/guard-lib.sh" ;; *) guard_lib="./guard-lib.sh" ;; esac
# shellcheck source-path=SCRIPTDIR source=guard-lib.sh
. "$guard_lib" || {
  echo "COMMIT BLOCKED by AI-Native SDLC gate: cannot source the guard library $guard_lib — refusing rather than allowing. Re-run install.sh." >&2
  exit 2
}

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

is_commit=0
printf '%s' "$scan" | grep -qE "$COMMIT_RE" && is_commit=1

# --- the command's shapes (REQ-TOUCH-017, 048, 049) --------------------------
# Besides the commit shape, the gate decides on two more, read from the same
# stripped text:
#   merge family — `git` as a command word, then (past `-C <dir>`, `-c k=v`
#     and other options) `merge`, `pull`, `rebase` or `reset`, with at least
#     one argument in that simple command naming a ref under sdlc/
#     (`sdlc/<x>`, `<remote>/sdlc/<x>`, `refs/heads/sdlc/<x>`, quoted or not);
#   branch change — `git checkout` / `git switch` BEFORE the commit or merge:
#     the branch the command lands on is the last such literal target, else the
#     current branch. A target this parser cannot read (a variable, `-`,
#     `@{-1}`, a sha, `--detach`, an option it does not know) is reported as
#     `bad`, and the guard refuses under its mode.
# One pass prints tab-separated lines, every field non-empty ("-" for none):
#   C   <pos>                    the commit (first match of the commit shape)
#   LC  <kind> <value>           where a commit lands: cur|new|lit|bad (one
#                                line per commit in the command)
#   LM  <i> <kind> <value>       where merge-family command <i> lands
#   R   <i> <ref>                an sdlc/ ref named by merge-family command <i>
#   LO  <i> <sub> <option>       pull/rebase <i> carries an option word outside
#                                the closed list the gate knows
#   P   <i> <word> / PD <i>      with LO: each positional of <i> (PD: dynamic)
#   XD  commit|merge             the commits/merges do not share one cd/-C
#   CD  <path>                   the last cd before the command decided on
#   MG  <dir>                    `git -C <dir>` of that merge (no commit)
# The command decided on is the commit when there is one (so the cd it follows
# is the one it always followed, REQ-GATE-012), else the first merge.
# Redirections and their targets are not words; `pull <remote> <ref>` names
# `<remote>/<ref>`; `rebase <upstream> <branch>` lands on <branch>; the values
# of message/strategy/exec options are not refs.
shapes_rc=0
shapes=$(printf '%s' "$scan" | perl -e '
  local $/; my $s = <STDIN>; $s = "" unless defined $s;
  my $q = qr/"[^"]*"|\x27[^\x27]*\x27/;
  # Global options before the subcommand: `-C <d>`, `-c k=v`, the two-word
  # long ones (`--git-dir <d>` and kin), and any `--opt` / `--opt=value`.
  my $opts = qr/(?:[ \t]+(?:-[Cc][ \t]+(?:$q|[^\s;&|()]+)|--(?:git-dir|work-tree|namespace|exec-path|super-prefix)[ \t]+(?:$q|[^\s;&|()]+)|--?[A-Za-z][^\s;&|()]*))*/;
  my $cre = qr/(?:^|[^A-Za-z0-9_.\-])git[ \t](?:[^|;&\n]*[ \t])?commit(?:[ \t;&|)"\x27`]|$)/m;
  my $gre = qr/(?:^|[^A-Za-z0-9_.\-])git($opts)[ \t]+(merge|pull|rebase|reset|checkout|switch)(?=[\s;&|)"\x27`]|\z)/m;
  # A redirection operator: at the start of a word an fd number may lead it
  # (`2>`, `2>&`); inside a word it ends the word (`foo>bar`).
  my $rstart = qr/\A\d*(?:<<<|<<-|<<|<>|>>|>\||>&|<&|&>>|&>|<|>)/;
  my $rmid = qr/\A(?:<<<|<<-|<<|<>|>>|>\||>&|<&|<|>)/;
  # words <from> — the shell words from offset <from> to the end of that simple
  # command: [text, dynamic], quotes removed, dynamic when it holds $ or `.
  # A redirection and the word it redirects to are not words of the command.
  sub words {
    my ($i) = @_; my $n = length $s; my @w; my ($cur, $in, $dyn, $skip) = ("", 0, 0, 0);
    my $end = sub { if ($in) { if ($skip) { $skip = 0 } else { push @w, [$cur, $dyn] } } ($cur, $in, $dyn) = ("", 0, 0) };
    while ($i < $n) {
      my $c = substr($s, $i, 1);
      if ($c eq "\x27") {
        my $j = index($s, "\x27", $i + 1); $j = $n if $j < 0;
        $cur .= substr($s, $i + 1, $j - $i - 1); $in = 1; $i = $j + 1; next;
      }
      if ($c eq "\"") {
        my $j = $i + 1;
        while ($j < $n) {
          my $d = substr($s, $j, 1);
          if ($d eq "\\") { $cur .= substr($s, $j + 1, 1); $j += 2; next }
          last if $d eq "\"";
          $dyn = 1 if $d eq "\$" || $d eq "`";
          $cur .= $d; $j++;
        }
        $in = 1; $i = $j + 1; next;
      }
      if ($c eq "\\") { $cur .= substr($s, $i + 1, 1); $in = 1; $i += 2; next }
      if (substr($s, $i) =~ ($in ? $rmid : $rstart)) { $end->(); $i += $+[0]; $skip = 1; next }   # redirection: dropped with its target
      last if $c =~ /[\n;&|()]/;
      if ($c =~ /[ \t]/) { $end->(); $i++; next }
      $dyn = 1 if $c eq "\$" || $c eq "`";
      $cur .= $c; $in = 1; $i++;
    }
    $end->();
    return @w;
  }
  # unreadable <ref> — a target this parser does not read as a branch name.
  sub unreadable { my $t = shift; return $t =~ /\@\{|[~^:]/ || $t =~ /\A[0-9a-f]{7,40}\z/ || $t =~ /\A(?:HEAD|FETCH_HEAD|ORIG_HEAD)\z/ }
  # land <sub> <words> — (skip) for a path checkout or a no-op, else
  # (new|lit|bad, value).
  sub land {
    my ($sub, @w) = @_;
    my %flag = map { $_ => 1 } qw(-q --quiet -f --force --no-track -m --merge
      --progress --no-progress --discard-changes --guess --no-guess --recurse-submodules
      --no-recurse-submodules --ignore-other-worktrees --overwrite-ignore --no-overwrite-ignore);
    my %new = $sub eq "checkout" ? map { $_ => 1 } qw(-b -B --orphan)
                                 : map { $_ => 1 } qw(-c -C --create --force-create --orphan);
    my ($nb, @pos, $endopt, $dd, $track);
    for (my $k = 0; $k < @w; $k++) {
      my ($t, $dyn) = @{$w[$k]};
      return ("bad", $t) if $dyn;
      if ($endopt || $t !~ /\A-/ || $t eq "-") {
        return ("bad", $t) if $t eq "-";
        push @pos, $t; next;
      }
      # `--`: for checkout what follows is a pathspec; the positionals before
      # it are weighed at the end.
      if ($t eq "--") { $dd = scalar @pos; $endopt = 1; next }
      if ($t eq "-t" || $t eq "--track" || $t =~ /\A--track=/) { $track = 1; next }
      next if $flag{$t} || $t =~ /\A--(?:recurse-submodules|conflict)=/;
      return ("skip") if $sub eq "checkout" && ($t =~ /\A(?:--ours|--theirs|-p|--patch)\z/ || $t =~ /\A--pathspec-from-file/);
      return ("bad", $t) if $t eq "--detach" || ($sub eq "switch" && $t eq "-d");
      if ($new{$t}) {
        $k++; return ("bad", $t) if $k >= @w;
        my ($v, $vd) = @{$w[$k]};
        return ("bad", $v) if $vd || $v =~ /\A-/;
        $nb = $v; next;
      }
      return ("bad", $t);                            # an option it does not know
    }
    return ("new", $nb) if defined $nb;
    # checkout `-- <paths>` and `<tree> -- <paths>` are path checkouts;
    # `<branch> --` with nothing after it switches to <branch>.
    return ("skip") if $sub eq "checkout" && defined $dd && ($dd == 0 || @pos > $dd);
    return ("skip") if @pos == 0 || ($sub eq "checkout" && @pos > 1);
    return ("bad", join(" ", @pos)) if @pos > 1;
    my $t = $pos[0];
    return ("bad", $t) if unreadable($t);
    if ($track) {
      # --track lands on the target with its remote stripped, as git derives
      # it: `refs/` and `remotes/` skipped, then everything up to the first /.
      my $b = $t; $b =~ s{\Arefs/}{}; $b =~ s{\Aremotes/}{};
      return ("bad", $t) unless $b =~ s{\A[^/]*/}{} && length $b;
      return ("new", $b);
    }
    return ("lit", $t);
  }
  # The options of each merge-family command whose value is the next word and
  # is not a ref it brings in (a message, a file, a strategy, a command).
  my %val = (
    merge  => { map { $_ => 1 } qw(-m -F --file -X -s --strategy --strategy-option --into-name) },
    pull   => { map { $_ => 1 } qw(-X -s --strategy --strategy-option --cleanup --depth
      --deepen --shallow-since --shallow-exclude --refmap --negotiation-tip --upload-pack
      -o --server-option -j --jobs) },
    rebase => { map { $_ => 1 } qw(-X -s --strategy --strategy-option -C --exec -x) },
    reset  => {},
  );
  # The closed lists of option words a pull or rebase may carry (fix batch D):
  # flags, long options also accepted as `--opt=value`, and short options with
  # an attached value. Any other option word may take a separate value and
  # shift the positionals, so the gate does not guess which word is the
  # remote (pull) or the branch it lands on (rebase).
  my %kflag = (
    pull => { map { $_ => 1 } qw(-- -q --quiet -v --verbose --recurse-submodules
      --no-recurse-submodules --commit --no-commit -e --edit --no-edit --ff --no-ff
      --ff-only --gpg-sign --no-gpg-sign --log --no-log --signoff --no-signoff --stat
      -n --no-stat --squash --no-squash --verify --no-verify --verify-signatures
      --no-verify-signatures --summary --no-summary --autostash --no-autostash
      --allow-unrelated-histories -r --rebase --no-rebase --all --append -a -f --force
      -p --prune --no-tags -t --tags -k --keep --unshallow --update-shallow
      --set-upstream -4 --ipv4 -6 --ipv6 --show-forced-updates --no-show-forced-updates
      --dry-run --progress --no-progress) },
    rebase => { map { $_ => 1 } qw(-- -i --interactive --continue --abort --skip --quit
      --edit-todo --show-current-patch -q --quiet -v --verbose --stat -n --no-stat
      --verify --no-verify -f --force-rebase --no-ff --fork-point --no-fork-point
      --ignore-whitespace --committer-date-is-author-date --ignore-date
      --reset-author-date --signoff -m --merge --apply -r --rebase-merges
      --no-rebase-merges --root --autosquash --no-autosquash --autostash --no-autostash
      -k --keep-empty --no-keep-empty --keep-base --reapply-cherry-picks
      --no-reapply-cherry-picks --allow-empty-message --update-refs --no-update-refs
      --reschedule-failed-exec --no-reschedule-failed-exec --gpg-sign --no-gpg-sign
      --onto) },
  );
  my %keq = (
    pull => { map { $_ => 1 } qw(--recurse-submodules --cleanup --gpg-sign --log
      --strategy --strategy-option --rebase --depth --deepen --shallow-since
      --shallow-exclude --refmap --negotiation-tip --upload-pack --server-option --jobs) },
    rebase => { map { $_ => 1 } qw(--whitespace --empty --rebase-merges --gpg-sign
      --strategy --strategy-option --exec --onto) },
  );
  my %katt = (pull => qr/\A-[XsSjo]./, rebase => qr/\A-[XsSCx]./);
  sub known_opt {
    my ($sub, $t) = @_;
    return 1 if $kflag{$sub}{$t} || $val{$sub}{$t} || $t =~ $katt{$sub};
    return $t =~ /\A(--[A-Za-z][A-Za-z-]*)=/ && $keq{$sub}{$1};
  }
  my $refre = qr{\A(?:refs/heads/|refs/remotes/[^/\s]+/|[A-Za-z0-9._-]+/)?sdlc/\S};
  my @cpos;
  while ($s =~ m/$cre/g) { push @cpos, [$-[0], substr($s, $-[0], $+[0] - $-[0])] }
  my $cpos = @cpos ? $cpos[0][0] : -1;
  my (@br, @mg);
  while ($s =~ m/$gre/g) {
    my ($pos, $o, $sub, $end) = ($-[0], $1, $2, $+[0]);
    my @w = words($end);
    if ($sub eq "checkout" || $sub eq "switch") {
      my @l = land($sub, @w);
      push @br, [$pos, @l] unless $l[0] eq "skip";
      next;
    }
    my (@refs, @pos, $unk);
    for (my $k = 0; $k < @w; $k++) {
      my ($v, $vd) = @{$w[$k]};
      $unk = $v if !defined $unk && $kflag{$sub} && $v =~ /\A-/ && !known_opt($sub, $v);
      if ($val{$sub}{$v}) { $k++; next }
      if ($sub eq "rebase" && $v eq "--onto") {      # a ref it brings in, not a positional
        $k++; push @refs, $w[$k][0] if $k < @w && $w[$k][0] =~ $refre;
        next;
      }
      push @pos, [$v, $vd] if $v !~ /\A-/;
      $v =~ s/\A--?[A-Za-z][A-Za-z-]*=//;
      push @refs, $v if $v =~ $refre;
    }
    # `git pull <remote> <ref>` merges the fetched <remote>/<ref>, not the
    # local branch of that name: name the remote-tracking branch.
    if ($sub eq "pull" && @pos >= 2 && $pos[0][0] ne ".") {
      my %rp = map { $_->[0] => 1 } @pos[1 .. $#pos];
      my $r = $pos[0][0];
      @refs = map { my $x = $_; $x =~ s{\Arefs/heads/}{}; $rp{$_} ? "$r/$x" : $_ } @refs;
    }
    # `git rebase <upstream> <branch>` checks out <branch> first: it lands there.
    my @over;
    # With an option word it does not know, the positionals cannot be trusted:
    # no override, and the gate weighs every positional instead (LO, P, PD).
    if ($sub eq "rebase" && @pos == 2 && !defined $unk) {
      my ($t, $d) = @{$pos[1]};
      @over = ($d || unreadable($t)) ? ("bad", $t) : ("lit", $t);
    }
    push @mg, { pos => $pos, o => $o, over => [@over], refs => [@refs], sub => $sub,
                unk => $unk, words => [@pos] } if @refs;
  }
  sub clean { my $v = shift; $v = "-" unless defined $v && length $v; $v =~ s/[\t\n]/ /g; return $v }
  sub landing {
    my ($pos) = @_; my @l = ("cur", "-");
    for my $b (@br) { @l = ($b->[1], $b->[2]) if $b->[0] < $pos }
    return (clean($l[0]), clean($l[1]));
  }
  # lastcd <pos> — the path of the last cd before offset <pos>, or "".
  sub lastcd {
    my $pre = substr($s, 0, $_[0] + 1); my $last = "";
    while ($pre =~ /(?:^|[;&|(\s])cd[ \t]+((?:-[A-Za-z]+[ \t]+|--[ \t]+)*)("([^"]*)"|\x27([^\x27]*)\x27|([^;&|\s]+))/mg) {
      $last = defined $3 ? $3 : defined $4 ? $4 : $5;
    }
    return $last;
  }
  # cdir <text> — the last `-C <dir>` in <text>, or "".
  sub cdir {
    my ($o, $dir) = ($_[0], "");
    while ($o =~ /-C[ \t]+(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\s;&|()]+))/g) {
      $dir = defined $1 ? $1 : defined $2 ? $2 : $3;
    }
    return $dir;
  }
  print "C\t$cpos\n" if $cpos >= 0;
  print join("\t", "LC", landing($_->[0])), "\n" for @cpos;
  for my $i (0 .. $#mg) {
    my @o = @{$mg[$i]{over}};
    print join("\t", "LM", $i, @o ? (clean($o[0]), clean($o[1])) : landing($mg[$i]{pos})), "\n";
    print "R\t$i\t", clean($_), "\n" for @{$mg[$i]{refs}};
    next unless defined $mg[$i]{unk};
    print join("\t", "LO", $i, $mg[$i]{sub}, clean($mg[$i]{unk})), "\n";
    for my $p (@{$mg[$i]{words}}) {
      if ($p->[1]) { print "PD\t$i\n" } else { print "P\t$i\t", clean($p->[0]), "\n" }
    }
  }
  my $anchor = $cpos >= 0 ? $cpos : (@mg ? $mg[0]{pos} : -1);
  exit 0 if $anchor < 0;
  # The gate decides one repository per command: every commit and every merge
  # decided on must share one cd/-C context, or the command is refused.
  my (%ctx, %kind);
  for my $c (@cpos) { $ctx{lastcd($c->[0]) . "\x01" . cdir($c->[1])} = 1; $kind{commit} = 1 }
  for my $m (@mg) { $ctx{lastcd($m->{pos}) . "\x01" . cdir($m->{o})} = 1; $kind{merge} = 1 }
  if (keys %ctx > 1) { print "XD\t$_\n" for sort keys %kind }
  my $last = lastcd($anchor);
  print "CD\t", clean($last), "\n" if length $last;
  if ($cpos < 0) {
    my $dir = cdir($mg[0]{o});
    print "MG\t", clean($dir), "\n" if length $dir;
  }
' 2>/dev/null) || shapes_rc=$?
if [ "$shapes_rc" -ne 0 ]; then
  # The shape parser could not run. A commit is still recognised by the grep
  # above; a command that might merge an sdlc/ branch cannot be told apart, so
  # it is refused rather than let through unread.
  if printf '%s' "$scan" | grep -qE '(^|[^A-Za-z0-9_.-])git[[:space:]].*(merge|pull|rebase|reset)' \
     && printf '%s' "$scan" | grep -qF 'sdlc/'; then
    gate_cannot_verify "parse the command's shape (perl failed), and it may merge an sdlc/ branch" "$scan"
  fi
  shapes=""
fi
# shape_field <tag> <n> — the n-th field of the first line tagged <tag>.
shape_field() {
  printf '%s\n' "$shapes" | awk -F '\t' -v t="$1" -v n="$2" '$1 == t { print $n; exit }'
}
is_merge=0
printf '%s\n' "$shapes" | grep -q '^R	' && is_merge=1

# Neither commit-shaped nor merge-family (a branch change alone is neither):
# not this gate's business, and it leaves no trace (REQ-TOUCH-049).
[ "$is_commit" -eq 1 ] || [ "$is_merge" -eq 1 ] || exit 0

# The gate decides in ONE repository per command. A command whose commits and
# merges sit behind different cd/-C contexts would be evaluated in the first
# one only, so it is refused under each affected guard's mode rather than
# decided on a repository some of its git commands never touch.
xd_text="the gate decides one repository per command, and this command changes directory between its git commands (a different cd or git -C before them).
Run the git commands of each repository as a separate command."
if printf '%s\n' "$shapes" | grep -qx 'XD	merge'; then
  guard_refuse evidence-merge "evidence-merge: $xd_text" || exit 2
fi
if printf '%s\n' "$shapes" | grep -qx 'XD	commit'; then
  guard_refuse gate1-stamp "gate1-stamp: $xd_text" || exit 2
fi

# The hook runs from the SESSION's cwd, which may not be the repo the command
# targets (compound commands routinely `cd <repo> && git commit`). Follow the
# command's cd when it names one — the LAST cd that comes BEFORE the commit, or
# before the merge when there is no commit (REQ-GATE-012): `cd a && cd b && git
# commit` commits in b, and a cd AFTER the commit says nothing about where it
# ran. Taking the first cd on the first line used to check repo a and allow the
# commit on a's result. Quoted paths, leading `cd` options (`-P`, `--`) and a
# `cd` on an earlier line are all handled by the shape pass above; `cd -` names
# no path and is dropped below. Whichever directory is chosen, ENTERING it is
# the test — if the cd fails the gate has no idea which repo it would be
# checking, so it blocks instead of guessing.
cdtarget=$(shape_field CD 2)
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
# also honor `git -C <repo> commit`, and `git -C <repo> merge …` when the
# command decided on is a merge
if [ "$is_commit" -eq 1 ]; then
  gitc=$(printf '%s' "$scan" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+("([^"]+)"|'\''([^'\'']+)'\''|([^;&|[:space:]]+))[^|;&]*commit.*/\2\3\4/p')
else
  gitc=$(shape_field MG 2)
fi
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
  # One JSON document carrying any guard warning and the requirement gate's
  # report as additionalContext — never a permission decision (REQ-TOUCH-014).
  guard_context_json "$rg_out" || true
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

# --- the gate1-stamp guard (REQ-TOUCH-015, REQ-TOUCH-016) --------------------
# A commit landing on `sdlc/<x>` needs a valid, non-stale Gate 1 stamp for the
# feature <x> belongs to. It runs BEFORE the docs-only shortcut below: ticking
# the last box is a prose-only commit, and a guard placed after the shortcut
# would never see it. `sdlc/hunt-*` and `sdlc/rca-*` have no spec by design and
# are exempt by name; any other `sdlc/<x>` that resolves to no feature is a
# refusal under the guard's mode, since a branch whose spec was never committed
# is exactly the case the stamp exists for. Every refusal goes through
# guard_refuse: exit 2 in deny mode; in warn mode the warning is accumulated in
# GUARD_WARNED and reaches stdout through run_req_gate, the only allow below.

# feature_of_branch <x> — print the feature that the branch suffix <x> belongs
# to: the longest `specs/<feature>/` name (`_`-prefixed excluded) that equals
# <x> or is a prefix of <x> followed by `-`. Returns 1 when none does.
feature_of_branch() {
  local x="$1" best="" dir name
  for dir in "$top"/specs/*/; do
    [ -d "$dir" ] || continue
    name=${dir%/}
    name=${name##*/}
    case "$name" in _*|'') continue ;; esac
    if [ "$x" = "$name" ] || [ "${x#"$name"-}" != "$x" ]; then
      [ "${#name}" -gt "${#best}" ] && best="$name"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# stamp_guard_branch — evaluate gate1-stamp for the branch in $landing_branch. Returns
# 0 when the commit may go on (stamp ok, guard not applicable, or warn mode);
# exits 2 when the guard refuses in deny mode.
stamp_guard_branch() {
  local x feature sstate state_out state_rc=0
  case "$landing_branch" in
    sdlc/hunt-*|sdlc/rca-*) return 0 ;;
    sdlc/?*) ;;
    *) return 0 ;;
  esac
  x=${landing_branch#sdlc/}
  if ! feature=$(feature_of_branch "$x"); then
    guard_refuse gate1-stamp "gate1-stamp: the commit lands on $landing_branch, and no specs/<feature>/ resolves to it (a feature named '$x', or a prefix of it followed by '-').
Commit the spec first: spec.md commits the spec and the Gate 1 stamp before /build." || exit 2
    return 0
  fi
  sstate="$top/scripts/sdlc-state.sh"
  [ -f "$sstate" ] || sstate="$HOME/.claude/scripts/sdlc-state.sh"
  if [ ! -f "$sstate" ]; then
    guard_refuse gate1-stamp "gate1-stamp: cannot verify the Gate 1 stamp for '$feature' on $landing_branch — sdlc-state.sh was not found.
Looked in:
  $top/scripts/sdlc-state.sh
  $HOME/.claude/scripts/sdlc-state.sh
Run install.sh from the framework checkout, then commit again." || exit 2
    return 0
  fi
  state_out=$(bash "$sstate" stamp-state "$feature" < /dev/null 2>/dev/null) || state_rc=$?
  case "$state_out" in
    "ok "*) [ "$state_rc" -eq 0 ] && return 0 ;;
  esac
  [ -n "$state_out" ] || state_out="no answer (exit $state_rc)"
  guard_refuse gate1-stamp "gate1-stamp: the commit lands on $landing_branch (feature '$feature') without a valid Gate 1 stamp — state: $state_out.
After Gate 1 is approved, run: sdlc-state.sh stamp $feature (and commit specs/$feature/state.json)." || exit 2
  return 0
}

# stamp_guard — stamp_guard_branch once for every distinct branch in
# $landing_branches (one per line, collected from every commit in the command).
stamp_guard() {
  local landing_branch
  while IFS= read -r landing_branch; do
    [ -n "$landing_branch" ] || continue
    stamp_guard_branch
  done <<< "$landing_branches"
}

# --- the landing branch (REQ-TOUCH-048) --------------------------------------
# current_branch — the branch HEAD names; detached HEAD is no branch, and no
# branch is neither under sdlc/ nor the default branch.
current_branch() { git symbolic-ref --short -q HEAD 2>/dev/null || true; }

# resolve_landing <kind> <value> — the branch a command lands on, from the
# shape pass: `new` is a branch the command creates (-b, -c, --orphan); `lit`
# is a plain checkout/switch target, which lands there only when it names a
# local branch or one a remote carries (git's own guess); anything else is a
# path checkout or a checkout that fails, and the branch stays the current one.
resolve_landing() {
  case "$1" in
    new) printf '%s\n' "$2" ;;
    lit)
      if git show-ref --verify -q "refs/heads/$2" 2>/dev/null \
         || [ -n "$(git for-each-ref --format=x "refs/remotes/*/$2" 2>/dev/null)" ]; then
        printf '%s\n' "$2"
      else
        current_branch
      fi ;;
    *) current_branch ;;
  esac
}

# default_branch — origin/HEAD's branch, else `main` when it exists, else
# `master`.
default_branch() {
  local d
  d=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null) || d=""
  if [ -n "$d" ]; then
    printf '%s\n' "${d#origin/}"
  elif git show-ref --verify -q refs/heads/main 2>/dev/null; then
    printf 'main\n'
  else
    printf 'master\n'
  fi
}

# --- the evidence-merge guard (REQ-TOUCH-017, REQ-TOUCH-018) -----------------
# A merge-family command landing on the default branch needs current green
# evidence for every sdlc/ ref it names: a committed evidence.json, read from
# the ref, whose evidence tree is the ref's own and whose check and test exit
# codes are 0. A ref that does not resolve, a ref that resolves to no feature
# and a state script that cannot be found are refusals under the guard's mode,
# never allows. Merges landing anywhere else (a task branch onto sdlc/<f>) are
# not this guard's business.

# evidence_guard_ref <ref> <landing> — evaluate one named ref.
evidence_guard_ref() {
  local ref="$1" land="$2" x feature sstate ev_out ev_rc=0
  x=$ref
  case "$x" in
    refs/heads/*) x=${x#refs/heads/} ;;
    refs/remotes/*) x=${x#refs/remotes/}; x=${x#*/} ;;
  esac
  case "$x" in
    sdlc/*) ;;
    */sdlc/*) x=${x#*/} ;;   # <remote>/sdlc/<x>
  esac
  x=${x#sdlc/}
  if [ "${ref#-}" != "$ref" ] || ! git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
    guard_refuse evidence-merge "evidence-merge: the command merges '$ref' into $land, and '$ref' does not resolve to a commit here, so its evidence cannot be read.
Name an existing branch (fetch it first if it is a remote one), then merge again." || exit 2
    return 0
  fi
  if ! feature=$(feature_of_branch "$x"); then
    guard_refuse evidence-merge "evidence-merge: the command merges '$ref' into $land, and no specs/<feature>/ resolves to it (a feature named '$x', or a prefix of it followed by '-').
Commit the feature's spec on the branch, record its evidence, then merge again." || exit 2
    return 0
  fi
  sstate="$top/scripts/sdlc-state.sh"
  [ -f "$sstate" ] || sstate="$HOME/.claude/scripts/sdlc-state.sh"
  if [ ! -f "$sstate" ]; then
    guard_refuse evidence-merge "evidence-merge: cannot verify the evidence of '$feature' for '$ref' — sdlc-state.sh was not found.
Looked in:
  $top/scripts/sdlc-state.sh
  $HOME/.claude/scripts/sdlc-state.sh
Run install.sh from the framework checkout, then merge again." || exit 2
    return 0
  fi
  ev_out=$(bash "$sstate" evidence-state "$feature" "$ref" < /dev/null 2>/dev/null) || ev_rc=$?
  if [ "$ev_rc" -eq 0 ] && [ "$ev_out" = green ]; then
    return 0
  fi
  [ -n "$ev_out" ] || ev_out="no answer (exit $ev_rc)"
  guard_refuse evidence-merge "evidence-merge: '$ref' (feature '$feature') would land on the default branch $land without current green evidence — state: $ev_out.
On the branch, run: sdlc-state.sh evidence $feature, then commit specs/$feature/evidence.json, and merge again." || exit 2
  return 0
}

# merge_guard — every merge-family command in the shape pass: where it lands,
# and, on the default branch, every sdlc/ ref it names.
merge_guard() {
  local def tag i kind val land tag2 j ref lo lo_sub lo_opt lo_what guarded pw
  def=$(default_branch)
  while IFS=$'\t' read -r tag i kind val; do
    [ "$tag" = LM ] || continue
    if [ "$kind" = bad ]; then
      guard_refuse evidence-merge "evidence-merge: cannot tell which branch the merge lands on — the git checkout/switch before it names '$val', which the gate cannot read as a branch (a variable, '-', '@{-1}', a sha, --detach or an option it does not know).
Check out the branch by its literal name, then merge." || exit 2
      continue
    fi
    land=$(resolve_landing "$kind" "$val")
    # An option word outside the closed list (LO): the parse of the remote
    # (pull) or of the branch a rebase lands on cannot be trusted. Refused
    # when the command may land on the default branch: it is there already,
    # or (rebase) any positional word names it or cannot be read.
    lo=$(printf '%s\n' "$shapes" | awk -F '\t' -v i="$i" '$1 == "LO" && $2 == i { print $3 "\t" $4; exit }')
    if [ -n "$lo" ]; then
      lo_sub=${lo%%$'\t'*}; lo_opt=${lo#*$'\t'}
      guarded=0
      [ -n "$land" ] && [ "$land" = "$def" ] && guarded=1
      if [ "$lo_sub" = rebase ]; then
        while IFS=$'\t' read -r tag2 j pw; do
          [ "$j" = "$i" ] || continue
          [ "$tag2" = PD ] && guarded=1
          [ "$tag2" = P ] || continue
          case "$pw" in "$def"|"refs/heads/$def") guarded=1 ;; esac   # any positional names the default branch
        done <<< "$shapes"
      fi
      [ "$guarded" -eq 1 ] || continue
      if [ "$lo_sub" = rebase ]; then
        lo_what="which branch the rebase lands on"
      else
        lo_what="which remote the pull fetches from"
      fi
      guard_refuse evidence-merge "evidence-merge: the git $lo_sub names '$lo_opt', an option the gate does not know; it may take a value and shift the words after it, so the gate cannot tell $lo_what, and the default branch $def may be rewritten.
Spell the command with options the gate knows (see the closed lists in check-gate.sh), then run it again." || exit 2
      continue
    fi
    [ -n "$land" ] && [ "$land" = "$def" ] || continue
    while IFS=$'\t' read -r tag2 j ref; do
      [ "$tag2" = R ] && [ "$j" = "$i" ] || continue
      evidence_guard_ref "$ref" "$land"
    done <<< "$shapes"
  done <<< "$shapes"
}

if [ "$is_merge" -eq 1 ]; then
  merge_guard
  # A merge does not pass the commit gate: the checks are not its contract.
  # Allowed here, with any warning carried to the model as context.
  if [ "$is_commit" -ne 1 ]; then
    guard_context_json "" || true
    exit 0
  fi
fi

# The branch each commit lands on: the last literal checkout/switch target
# before it, else the current branch. Every commit in the command is weighed,
# and the stamp guard runs once per distinct landing branch (the checks below
# still run once). A target the gate cannot read is a refusal under the stamp
# guard's mode; in warn mode the stamp guard is then not evaluated for that
# commit (there is no branch to evaluate it on).
landings=$'\n'
landing_branches=""
seen_lc=0
while IFS=$'\t' read -r lc_tag lc_kind lc_val; do
  [ "$lc_tag" = LC ] || continue
  seen_lc=1
  if [ "$lc_kind" = bad ]; then
    case "$landings" in *$'\n'"bad:$lc_val"$'\n'*) continue ;; esac
    landings="${landings}bad:$lc_val"$'\n'
    guard_refuse gate1-stamp "gate1-stamp: cannot tell which branch the commit lands on — the git checkout/switch before it names '$lc_val', which the gate cannot read as a branch (a variable, '-', '@{-1}', a sha, --detach or an option it does not know).
Check out the branch by its literal name, then commit." || exit 2
    continue
  fi
  lb=$(resolve_landing "$lc_kind" "$lc_val")
  case "$landings" in *$'\n'"br:$lb"$'\n'*) continue ;; esac
  landings="${landings}br:$lb"$'\n'
  landing_branches="${landing_branches}${lb}"$'\n'
done <<< "$shapes"
# No LC line at all (the shape pass did not run, or read no commit the grep
# above saw): the commit lands on the current branch, as before.
[ "$seen_lc" -eq 1 ] || landing_branches=$(current_branch)
stamp_guard

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
