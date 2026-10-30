#!/usr/bin/env perl
# The command check of role-guard.sh for a bound child session. It reads one
# shell command on stdin and prints one line when the command must be denied:
#   deny<TAB><what the child does not do>
#   parse<TAB><why the command cannot be parsed>
#   bad<TAB><guard.deny entry><TAB><why it is not a regex>
# and nothing when the command passes. role-guard.sh denies on every line.
#
# It parses shell words, so quoting does not hide a verb and an argument
# never counts as a command:
# - Simple commands split on ; && || | & ( ) and newlines outside quotes.
# - Quote removal: 'single', "double", $'ansi', and backslash escapes.
# - Leading VAR=value words, shell keywords and the wrappers env, command,
#   exec, nohup, time, sudo and xargs (with their options) are dropped. A
#   path command (/usr/bin/git) becomes its basename.
# - Recursion: the script after bash|sh|zsh|dash|ksh -c, the words after
#   eval, $(...), `...`, <(...) and >(...) (also inside double quotes and
#   unquoted heredoc bodies), and the heredoc, <<< or echo|printf text that
#   a pipe or redirection feeds to a shell without -c.
# - Rules on argv: git push (git options may stand before it), gh pr and gh
#   issue verbs outside the read list, gh api writes, az repos pr, az boards
#   work-item, az pipelines run and az pipelines build queue.
# - guard.deny: each Perl regex (in STORY_GUARD_DENY, one per line) is
#   matched against the words of each simple command joined by single
#   spaces, before and after the drop of VAR=value words and wrappers.
# - A write to the binding folder (STORY_SESSIONS_DIR, or any path with a
#   .sessions segment): rm, mv, cp, tee, truncate, ln, sed -i, and > or >>.
# Unbalanced quotes or parentheses give a parse line, so the child is denied.
#
# Board mode (STORY_GUARD_MODE=board, for board-read-guard.sh): every simple
# command is classified, not only the first hit. It prints one line per hit:
#   read<TAB><label>   a story, task or issue read (az boards work-item show,
#                      az boards query, az devops invoke and az rest on wit,
#                      gh issue view|list|status, gh search issues, gh project
#                      item-list, gh api on issues, a graphql query on issues,
#                      a prefix in STORY_BOARD_SHOW, a regex in STORY_BOARD_READS)
#   write<TAB><label>  a board or issue write, or anything the default mode denies
#   badread<TAB><entry><TAB><why>  a STORY_BOARD_READS entry that is not a regex
# A built-in read rule wins over the default rules for the same command, so a
# WIQL POST is a read, not a write. A read from STORY_BOARD_SHOW or
# STORY_BOARD_READS does not: a command the default rules deny is a write.
# parse and bad lines are the same as in the default mode.
use strict;
use warnings;

my $MAX_DEPTH = 8;
my $SESSIONS = $ENV{STORY_SESSIONS_DIR} // '';
my @deny;
for my $re (grep { length } split /\n/, ($ENV{STORY_GUARD_DENY} // '')) {
  my $q = eval { qr/$re/ };
  if (!defined $q) {
    (my $e = $@) =~ s/ at \S+ line \d+.*//s;
    print "bad\t$re\t$e\n";
    exit 0;
  }
  push @deny, [$re, $q];
}
my $BOARD = ($ENV{STORY_GUARD_MODE} // '') eq 'board';
my (@HITS, @READS, @SHOW);
if ($BOARD) {
  for my $re (grep { length } split /\n/, ($ENV{STORY_BOARD_READS} // '')) {
    my $q = eval { qr/$re/ };
    if (!defined $q) {
      (my $e = $@) =~ s/ at \S+ line \d+.*//s;
      print "badread\t$re\t$e\n";
      exit 0;
    }
    push @READS, [$re, $q];
  }
  @SHOW = grep { length } split /\n/, ($ENV{STORY_BOARD_SHOW} // '');
}

# denied: the deny line in the default mode. In board mode it records a write
# hit and returns nothing, so the analysis goes on to the next command.
sub denied {
  my ($why) = @_;
  if ($BOARD) { push @HITS, "write\t$why"; return; }
  return "deny\t$why";
}


sub newcmd { return { words => [], quoted => [], redirs => [], heredocs => [], herestrings => [], nested => [], pipe => 0 }; }

# read_subst: from just after "$(" or "<(" to the matching ")". Returns the inner
# text. $arith is true for $(( ... )): no heredocs and no comments there. It
# skips heredoc bodies and # comments, so a ) or a quote in them does not end
# the substitution early, as in git commit -m "$(cat <<'EOF' ... EOF )".
sub read_subst {
  my ($s, $ip, $arith) = @_;
  my $depth = 1;
  my $start = $$ip;
  my $n = length $s;
  my @pend;
  my $wordstart = 1;
  while ($$ip < $n) {
    my $ch = substr($s, $$ip, 1);
    if ($ch eq "\n" && !$arith) {
      $$ip++;
      for my $h (@pend) {
        my ($delim, $dash) = @$h;
        while ($$ip < $n) {
          my $end = index($s, "\n", $$ip);
          my $line = $end < 0 ? substr($s, $$ip) : substr($s, $$ip, $end - $$ip);
          $$ip = $end < 0 ? $n : $end + 1;
          my $t = $dash ? ($line =~ s/^\t+//r) : $line;
          last if $t eq $delim;
        }
      }
      @pend = ();
      $wordstart = 1;
      next;
    }
    if ($ch eq '#' && $wordstart && !$arith) {
      my $e = index($s, "\n", $$ip);
      $$ip = $e < 0 ? $n : $e;
      next;
    }
    if ($ch eq '<' && !$arith && substr($s, $$ip, 3) ne '<<<' && substr($s, $$ip, 2) eq '<<') {
      if (substr($s, $$ip) =~ /\A<<(-?)[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/) {
        push @pend, [$3, $1 eq '-'];
        $$ip += length $&;
        $wordstart = 0;
        next;
      }
    }
    $wordstart = ($ch =~ /[\s;&|(]/) ? 1 : 0;
    if ($ch eq '\\') { $$ip += 2; $wordstart = 0; next; }
    if ($ch eq "'") {
      my $end = index($s, "'", $$ip + 1);
      die "an unclosed single quote\n" if $end < 0;
      $$ip = $end + 1;
      next;
    }
    if ($ch eq '"') { $$ip++; read_dq($s, $ip, newcmd(), '"'); next; }
    if ($ch eq '`') { read_backtick($s, $ip); next; }
    if ($ch eq '(') { $depth++; }
    elsif ($ch eq ')') {
      $depth--;
      if ($depth == 0) { my $inner = substr($s, $start, $$ip - $start); $$ip++; return $inner; }
    }
    $$ip++;
  }
  die "an unclosed \$( or (\n";
}

# read_backtick: $$ip at the opening backtick. Returns the inner script.
# read_arith: from just after "$((" to the matching ")". A command substitution
# inside runs before the arithmetic, so the guard cannot skip it: parse error.
sub read_arith {
  my ($s, $ip) = @_;
  my $inner = read_subst($s, $ip, 1);
  die "an arithmetic expansion that holds a command substitution (\$( or a backtick)\n" if $inner =~ /\$\(|`/;
  return $inner;
}

sub read_backtick {
  my ($s, $ip) = @_;
  my $n = length $s;
  my $out = '';
  $$ip++;
  while ($$ip < $n) {
    my $ch = substr($s, $$ip, 1);
    if ($ch eq '\\' && $$ip + 1 < $n) { $out .= substr($s, $$ip + 1, 1); $$ip += 2; next; }
    if ($ch eq '`') { $$ip++; return $out; }
    $out .= $ch;
    $$ip++;
  }
  die "an unclosed backtick\n";
}

# read_dq: the text of a double-quoted part from just after the quote. With
# $term undef it reads to the end (an unquoted heredoc body). Command
# substitutions go to $cmd->{nested}.
sub read_dq {
  my ($s, $ip, $cmd, $term) = @_;
  my $n = length $s;
  my $out = '';
  while ($$ip < $n) {
    my $ch = substr($s, $$ip, 1);
    if (defined $term && $ch eq $term) { $$ip++; return $out; }
    if ($ch eq '\\' && $$ip + 1 < $n) {
      my $nx = substr($s, $$ip + 1, 1);
      if ($nx =~ /[\$`"\\]/) { $out .= $nx; }
      elsif ($nx ne "\n") { $out .= "\\$nx"; }
      $$ip += 2;
      next;
    }
    if ($ch eq '`') { push @{$cmd->{nested}}, read_backtick($s, $ip); $out .= '`...`'; next; }
    if ($ch eq '$' && substr($s, $$ip + 1, 1) eq '(') {
      if (substr($s, $$ip + 2, 1) eq '(') { $$ip += 3; read_arith($s, $ip); $out .= '$((...))'; next; }
      $$ip += 2;
      push @{$cmd->{nested}}, read_subst($s, $ip);
      $out .= '$(...)';
      next;
    }
    $out .= $ch;
    $$ip++;
  }
  die "an unclosed double quote\n" if defined $term;
  return $out;
}

# lex: the simple commands of a script, each with its words (quotes removed),
# redirections, heredoc bodies, <<< strings and nested scripts.
sub lex {
  my ($s) = @_;
  my @cmds;
  my $cur = newcmd();
  my ($word, $inword, $quoted) = ('', 0, 0);
  my $want;        # the redirection operator that waits for its target word
  my @pending;     # heredocs that wait for their body: [cmd, delimiter, dash, quoted]
  my $n = length $s;
  my $i = 0;
  my $endword = sub {
    if ($inword) {
      if (defined $want) {
        if ($want eq '<<' || $want eq '<<-') { push @pending, [$cur, $word, $want eq '<<-', $quoted]; }
        elsif ($want eq '<<<') { push @{$cur->{herestrings}}, $word; }
        else { push @{$cur->{redirs}}, [$want, $word]; }
        undef $want;
      } else {
        push @{$cur->{words}}, $word;
        push @{$cur->{quoted}}, $quoted;
      }
    }
    ($word, $inword, $quoted) = ('', 0, 0);
  };
  my $endcmd = sub {
    my ($pipe) = @_;
    $endword->();
    die "a redirection without a target\n" if defined $want;
    $cur->{pipe} = $pipe;
    push @cmds, $cur;
    $cur = newcmd();
  };
  while ($i < $n) {
    my $ch = substr($s, $i, 1);
    if ($ch eq '\\') {
      if ($i + 1 < $n && substr($s, $i + 1, 1) eq "\n") { $i += 2; next; }
      if ($i + 1 < $n) { $word .= substr($s, $i + 1, 1); $inword = 1; }
      $i += 2;
      next;
    }
    if ($ch eq "'") {
      my $end = index($s, "'", $i + 1);
      die "an unclosed single quote\n" if $end < 0;
      $word .= substr($s, $i + 1, $end - $i - 1);
      ($inword, $quoted) = (1, 1);
      $i = $end + 1;
      next;
    }
    if ($ch eq '"') {
      $i++;
      $word .= read_dq($s, \$i, $cur, '"');
      ($inword, $quoted) = (1, 1);
      next;
    }
    if ($ch eq '`') {
      push @{$cur->{nested}}, read_backtick($s, \$i);
      $word .= '`...`';
      $inword = 1;
      next;
    }
    if ($ch eq '$') {
      my $nx = substr($s, $i + 1, 1);
      if ($nx eq '(') {
        if (substr($s, $i + 2, 1) eq '(') { $i += 3; read_arith($s, \$i); $word .= '$((...))'; $inword = 1; next; }
        $i += 2;
        push @{$cur->{nested}}, read_subst($s, \$i);
        $word .= '$(...)';
        $inword = 1;
        next;
      }
      if ($nx eq "'") {
        my $j = $i + 2;
        my $out = '';
        while (1) {
          die "an unclosed \$' quote\n" if $j >= $n;
          my $c = substr($s, $j, 1);
          if ($c eq '\\' && $j + 1 < $n) {
            my $rest = substr($s, $j + 1);
            if ($rest =~ /\A(?:x([0-9a-fA-F]{1,2})|([0-7]{1,3})|u([0-9a-fA-F]{1,4})|U([0-9a-fA-F]{1,8}))/) {
              $out .= chr(defined $1 ? hex($1) : defined $2 ? oct($2) & 0xFF : hex($3 // $4));
              $j += 1 + length $&;
              next;
            }
            my $e = substr($rest, 0, 1);
            my %esc = (n => "\n", t => "\t", r => "\r", a => "\a", b => "\b", e => "\e", E => "\e", f => "\f", v => "\x0b");
            $out .= exists $esc{$e} ? $esc{$e} : $e;
            $j += 2;
            next;
          }
          last if $c eq "'";
          $out .= $c;
          $j++;
        }
        $word .= $out;
        ($inword, $quoted) = (1, 1);
        $i = $j + 1;
        next;
      }
    }
    if ($ch eq '#' && !$inword) {
      my $end = index($s, "\n", $i);
      $i = $end < 0 ? $n : $end;
      next;
    }
    if ($ch eq ' ' || $ch eq "\t") { $endword->(); $i++; next; }
    if ($ch eq "\n") {
      $endcmd->(0);
      $i++;
      for my $h (@pending) {
        my ($c, $delim, $dash, $q) = @$h;
        my $body = '';
        while ($i < $n) {
          my $end = index($s, "\n", $i);
          my $line = $end < 0 ? substr($s, $i) : substr($s, $i, $end - $i);
          $i = $end < 0 ? $n : $end + 1;
          my $t = $dash ? ($line =~ s/^\t+//r) : $line;
          last if $t eq $delim;
          $body .= "$line\n";
        }
        push @{$c->{heredocs}}, { body => $body, quoted => $q };
      }
      @pending = ();
      next;
    }
    if ($ch eq ';') { $endcmd->(0); $i++; next; }
    if ($ch eq '&') {
      if (substr($s, $i, 2) eq '&&') { $endcmd->(0); $i += 2; next; }
      if (substr($s, $i, 2) eq '&>') {
        $endword->();
        my $op = substr($s, $i, 3) eq '&>>' ? '>>' : '>';
        $want = $op;
        $i += $op eq '>>' ? 3 : 2;
        next;
      }
      $endcmd->(0); $i++; next;
    }
    if ($ch eq '|') {
      if (substr($s, $i, 2) eq '||') { $endcmd->(0); $i += 2; next; }
      if (substr($s, $i, 2) eq '|&') { $endcmd->(1); $i += 2; next; }
      $endcmd->(1); $i++; next;
    }
    if ($ch eq '(' || $ch eq ')') { $endcmd->(0); $i++; next; }
    if ($ch eq '<' || $ch eq '>') {
      if (substr($s, $i + 1, 1) eq '(') {
        $i += 2;
        push @{$cur->{nested}}, read_subst($s, \$i);
        $word .= 'PROCESS';
        $inword = 1;
        next;
      }
      # A word of digits right before the operator is a file descriptor.
      if ($inword && !$quoted && $word =~ /^\d+$/) { ($word, $inword) = ('', 0); }
      $endword->();
      my $op;
      for my $o ('<<<', '<<-', '>>', '>|', '>&', '<&', '<>', '<<', '>', '<') {
        if (substr($s, $i, length $o) eq $o) { $op = $o; last; }
      }
      $i += length $op;
      $op = '>' if $op eq '>|';
      $want = $op;
      next;
    }
    $word .= $ch;
    $inword = 1;
    $i++;
  }
  $endcmd->(0);
  return \@cmds;
}

my %KEYWORD = map { $_ => 1 } qw(! { } if then else elif fi do done while until in);
my %WRAPPER = map { $_ => 1 } qw(env command exec nohup time sudo xargs builtin noglob nocorrect nice timeout setsid
  stdbuf ionice flock caffeinate doas chronic watch repeat);
my %OPTARG = (
  env => { map { $_ => 1 } qw(-u --unset -C --chdir -P) },
  sudo => { map { $_ => 1 } qw(-u --user -g --group -C --close-from -D --chdir -h --host -p --prompt -r --role -t --type -U --other-user -T --command-timeout) },
  xargs => { map { $_ => 1 } qw(-I -J -n -L -l -P -d -E -e -s -a --max-args --max-lines --max-procs --delimiter --eof --max-chars --arg-file --replace) },
  exec => { '-a' => 1 },
  nice => { '-n' => 1 }, timeout => { map { $_ => 1 } qw(-k -s --kill-after --signal) },
  stdbuf => { map { $_ => 1 } qw(-i -o -e) }, ionice => { map { $_ => 1 } qw(-c -n -p -P -t) },
  doas => { map { $_ => 1 } qw(-u -C) }, caffeinate => { map { $_ => 1 } qw(-t -w) },
  watch => { map { $_ => 1 } qw(-n -d --interval) }, flock => { map { $_ => 1 } qw(-w -E) },
);
my %POSITIONAL = (timeout => 1, flock => 1, repeat => 1);
my ($DYN, $VIA_XARGS);

sub base { my ($w) = @_; $w =~ s{.*/}{}; return $w; }

# normalize: argv without leading VAR=value words, keywords and wrappers.
# An empty list means the command runs nothing (command -v git). It sets $DYN
# to a command word that the guard cannot read (a variable, a substitution,
# a brace list or =cmd) and $VIA_XARGS when xargs supplies the arguments.
sub normalize {
  my @w = @_;
  ($DYN, $VIA_XARGS) = (undef, 0);
  while (@w) {
    if ($w[0] =~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/ || $KEYWORD{$w[0]}) { shift @w; next; }
    if ($w[0] eq 'function' || $w[0] eq 'coproc') { shift @w; shift @w if @w > 1; next; }
    my $b = base($w[0]);
    last unless $WRAPPER{$b};
    $VIA_XARGS = 1 if $b eq 'xargs';
    shift @w;
    while (@w && $w[0] =~ /^-/) {
      my $o = shift @w;
      last if $o eq '--';
      return () if $b eq 'command' && $o =~ /^-[pvV]*[vV]/;
      if ($b eq 'env' && ($o =~ /^-S(.*)$/s || $o =~ /^--split-string(?:=(.*))?$/s)) {
        my $str = (defined $1 && length $1) ? $1 : shift(@w) // '';
        unshift @w, grep { length } split /\s+/, $str;
        next;
      }
      shift @w if $OPTARG{$b} && $OPTARG{$b}{$o} && @w;
    }
    splice(@w, 0, $POSITIONAL{$b}) if $POSITIONAL{$b};
  }
  if (@w) {
    my $f = $w[0];
    $DYN = $f if ($f =~ /^[\$`=]/ && $f !~ m{^\$\{?[A-Za-z_]\w*\}?/}) || $f =~ /\{[^{}]*,[^{}]*\}/;
    $w[0] = base($w[0]);
  }
  return @w;
}

my %SHELL = map { $_ => 1 } qw(bash sh zsh dash ksh fish csh tcsh ash mksh rbash su script);

# shell_script: for a shell argv, (1, script) with -c, (0) when it reads stdin,
# or () when it runs a script file.
sub shell_script {
  my @w = @_;
  shift @w;
  my $c = 0;
  while (@w && $w[0] =~ /^[-+]/) {
    my $o = shift @w;
    last if $o eq '--' || $o eq '-';
    if ($o =~ /^[-+][oO]$/ || $o eq '--rcfile' || $o eq '--init-file') { shift @w; next; }
    next if $o =~ /^--/;
    $c = 1 if $o =~ /^-[A-Za-z]*c/;
  }
  return (1, $w[0] // '') if $c;
  return (0) if !@w || $w[0] eq '-s' || $w[0] eq '/dev/stdin';
  return ();
}

# protected: a path the child never writes: a .sessions folder (case-insensitive,
# globs included), the repo config and the settings files.
sub clean_path {
  my ($p) = @_;
  $p = lc $p;
  $p =~ s{/+}{/}g;
  1 while $p =~ s{(?:^|/)\.(?=/|$)}{}g;
  1 while $p =~ s{[^/.][^/]*/\.\.(?:/|$)}{}g;
  return $p;
}

sub protected {
  my ($p) = @_;
  $p = clean_path($p);
  return 1 if length $SESSIONS && index($p, lc $SESSIONS) == 0;
  return 1 if $p =~ m{(?:^|/)\.claude/settings(?:\.local)?\.json$} || $p =~ m{(?:^|/)story\.json$};
  for my $seg (split m{/}, $p) {
    return 1 if $seg eq '.sessions';
    next unless $seg =~ /[*?\[]/;
    (my $re = quotemeta $seg) =~ s/\\\*/.*/g;
    $re =~ s/\\\?/./g;
    $re =~ s/\\\[(.*?)\\\]/[$1]/g;
    return 1 if eval { '.sessions' =~ /^$re$/ };
  }
  return 0;
}

my %GH_PR_READ = map { $_ => 1 } qw(view list diff checks status checkout);
my %GH_ISSUE_READ = map { $_ => 1 } qw(view list status);
my %GH_MUTATING = map { $_ => 1 } qw(create delete edit set rename run rerun cancel enable disable transfer archive
  unarchive fork import install upgrade remove lock unlock pin unpin develop sync deploy add update);
my %AZ_MUTATING = map { $_ => 1 } qw(create delete update add remove set run queue import approve);
my %WRITER = map { $_ => 1 } qw(rm mv cp tee truncate ln unlink install dd touch chmod chown rsync rmdir);
my $DYNAMIC = qr/[\$`{}]/;

# gh_api: deny reason for a gh api call, or undef. Reads the option clusters (-iXPOST, -if).
sub gh_api {
  my @a = @_;
  my ($method, $field);
  for (my $j = 0; $j < @a; $j++) {
    my $o = $a[$j];
    if ($o eq '--method') { $method = $a[$j + 1] // ''; $j++; }
    elsif ($o =~ /^--method=(.*)$/) { $method = $1; }
    elsif ($o =~ /^--(?:field|raw-field|input)(?:$|=)/) { $field = $o; }
    elsif ($o =~ /^-([A-Za-z]+)(.*)$/s && $o !~ /^--/) {
      my ($cl, $rest) = ($1, $2);
      my @c = split //, $cl;
      for my $k (0 .. $#c) {
        my $c = $c[$k];
        my $tail = join('', @c[$k + 1 .. $#c]) . $rest;
        if ($c eq 'X') { $method = length $tail ? $tail : ($a[$j + 1] // ''); $j++ unless length $tail; last; }
        if ($c eq 'f' || $c eq 'F') { $field = "-$c"; last; }
        if ($c =~ /^[HpqtR]$/) { $j++ unless length $tail; last; }
      }
    }
  }
  return "run gh api $method" if defined $method && uc($method) ne 'GET';
  return "run gh api with $field (gh sends a POST)" if defined $field && !defined $method;
  return;
}

# optval: the value of the first named option in the argv ref ("--x v" or "--x=v").
sub optval {
  my ($a, @names) = @_;
  my %n = map { $_ => 1 } @names;
  for (my $j = 0; $j < @$a; $j++) {
    my $w = $a->[$j];
    return $a->[$j + 1] if $n{$w} && $j + 1 < @$a;
    return $2 if $w =~ /^(--[A-Za-z-]+)=(.*)$/s && $n{$1};
  }
  return;
}

my %GH_API_VALUE = map { $_ => 1 } qw(-X --method -H --header -f --raw-field -F --field --input -q --jq -t --template -p --preview --hostname --cache);

# graphql_text: a GraphQL document without its comments and strings. GraphQL
# ignores a comment, and a string is a value, not a keyword.
sub graphql_text {
  (my $doc = $_[0]) =~ s/"""(?:[^"\\]|\\.|"(?!""))*"""|"(?:[^"\\\r\n]|\\.)*"|#[^\r\n]*/ /gs;
  return $doc;
}

# graphql_mutation: true when an operation of the document is a mutation: the
# word mutation outside every brace and parenthesis. Inside them it is a field,
# an alias or an argument.
sub graphql_mutation {
  my ($doc) = @_;
  my $depth = 0;
  while ($doc =~ /([{(])|([})])|\b(mutation)\b/g) {
    if (defined $1) { $depth++; }
    elsif (defined $2) { $depth-- if $depth > 0; }
    elsif ($depth == 0) { return 1; }
  }
  return 0;
}

# gh_api_board: (kind, label) for a gh api call on issues, or nothing.
sub gh_api_board {
  my @a = @_;
  my ($ep, @fields);
  for (my $j = 0; $j < @a; $j++) {
    my $w = $a[$j];
    if ($w =~ /^-/) {
      if ($GH_API_VALUE{$w}) { push @fields, $a[$j + 1] // '' if $w =~ /^(?:-f|-F|--field|--raw-field)$/; $j++; }
      elsif ($w =~ /^--(?:field|raw-field)=(.*)$/s) { push @fields, $1; }
      elsif ($w =~ /^-[fF](.+)$/s) { push @fields, $1; }
      next;
    }
    $ep //= $w;
  }
  return unless defined $ep;
  if ($ep eq 'graphql') {
    my ($query) = map { /^query=(.*)$/s ? $1 : () } @fields;
    return unless defined $query;
    my $doc = graphql_text($query);
    return ('write', 'run gh api graphql with a mutation') if graphql_mutation($doc);
    return ('read', 'run gh api graphql on issues') if $doc =~ /\bissues?\s*[({]/;
    return;
  }
  (my $path = $ep) =~ s{^/+}{};
  return unless $path =~ m{^repos/[^/]+/[^/]+/issues(?:[/?]|$)} || $path =~ m{^search/issues(?:[?]|$)};
  my $w = gh_api(@a);
  return ('write', $w) if defined $w;
  return ('read', "run gh api $path");
}

# board_class: (read|write, label, source) for a story, task or issue command, or
# nothing. The built-in classes come first. A board.show prefix or a board.reads
# regex (source "config") only adds reads for commands they do not classify, so a
# broad prefix such as "gh api" cannot make a write a read.
sub board_class {
  my @a = @_;
  my ($kind, $label) = builtin_class(@a);
  return ($kind, $label, 'builtin') if defined $kind;
  my $text = join ' ', @a;
  for my $p (@SHOW) { return ('read', "run $p", 'config') if $text eq $p || index($text, "$p ") == 0; }
  for my $d (@READS) { return ('read', "run a command that matches the board.reads entry $d->[0]", 'config') if $text =~ $d->[1]; }
  return;
}

# builtin_class: (read|write, label) for an az boards, az devops, az rest or gh
# command on work items or issues, or nothing.
sub builtin_class {
  my @a = @_;
  my $cmd = $a[0];
  if ($cmd eq 'az') {
    my @p;
    my $VAL = qr/^(?:--output|-o|--query|--subscription|--organization|--org|--project|-p|--detect)$/;
    for (my $j = 1; $j < @a; $j++) {
      my $w = $a[$j];
      if ($w =~ /^-/) { $j++ if $w =~ $VAL && $w !~ /=/; next; }
      push @p, $w;
    }
    my ($g, $s, $v, $x) = map { $_ // '' } @p[0 .. 3];
    if ($g eq 'boards' && $s eq 'work-item') {
      return if $v eq '';
      return ('read', 'run az boards work-item show') if $v eq 'show';
      if ($v eq 'relation') {
        return ('read', 'run az boards work-item relation show') if $x eq 'show';
        return if $x eq '' || $x eq 'list-type';
        return ('write', "run az boards work-item relation $x");
      }
      return ('write', "run az boards work-item $v");
    }
    return ('read', 'run az boards query') if $g eq 'boards' && $s eq 'query';
    if ($g eq 'devops' && $s eq 'invoke') {
      return unless lc(optval(\@a, '--area') // '') eq 'wit';
      my $m = uc(optval(\@a, '--http-method') // 'GET');
      my $res = lc(optval(\@a, '--resource') // '');
      return ('read', "run az devops invoke --area wit --resource $res") if $m eq 'GET' || ($m eq 'POST' && $res =~ /^(?:wiql|workitemsbatch)$/);
      return ('write', "run az devops invoke --area wit with the method $m");
    }
    if ($g eq 'rest') {
      my $url = optval(\@a, '--url', '--uri', '-u') // return;
      return unless $url =~ m{/_apis/wit/}i;
      my $m = uc(optval(\@a, '--method', '-m') // 'GET');
      return ('read', 'run az rest on a work item URL') if $m eq 'GET' || ($m eq 'POST' && $url =~ m{/_apis/wit/(?:wiql|workitemsbatch)(?:[/?]|$)}i);
      return ('write', "run az rest with the method $m on a work item URL");
    }
    return;
  }
  if ($cmd eq 'gh') {
    my $i = 1;
    my $skip = sub { while ($i < @a && $a[$i] =~ /^-/) { my $o = $a[$i]; $i += ($o =~ /^(?:-R|--repo|--hostname)$/) ? 2 : 1; } };
    $skip->();
    my $group = $a[$i] // return;
    $i++;
    return gh_api_board(@a[$i .. $#a]) if $group eq 'api';
    $skip->();
    my $verb = $a[$i] // '';
    if ($group eq 'issue') {
      return if $verb eq '';
      return ('read', "run gh issue $verb") if $GH_ISSUE_READ{$verb};
      return ('write', "run gh issue $verb");
    }
    return ('read', 'run gh search issues') if $group eq 'search' && $verb eq 'issues';
    return ('read', 'run gh project item-list') if $group eq 'project' && $verb eq 'item-list';
    return;
  }
  return;
}

# verdict: the deny line for one argv in the default mode. In board mode a
# board command records its read or write hit; any other command records the
# default deny as a write hit. It returns nothing in board mode.
sub verdict {
  my @argv = @_;
  if ($BOARD) {
    my ($kind, $label, $source) = board_class(@argv);
    if (defined $kind) {
      my $r = $source eq 'config' ? rules(@argv) : undef;
      push @HITS, defined $r ? "write\t$r" : "$kind\t$label";
      return;
    }
  }
  my $r = rules(@argv);
  return defined $r ? denied($r) : undef;
}

# rules: the built-in deny rules on one normalized argv.
sub rules {
  my @a = @_;
  my $cmd = $a[0];
  if ($cmd eq 'git') {
    my $i = 1;
    while ($i < @a && $a[$i] =~ /^-/) {
      my $o = $a[$i];
      return "run git with a -c alias ($a[$i + 1])" if $o eq '-c' && ($a[$i + 1] // '') =~ /^alias\./i;
      $i += ($o =~ /^(?:-C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--exec-path)$/) ? 2 : 1;
    }
    my $sub = $a[$i];
    if (!defined $sub) { return $VIA_XARGS ? 'run git with arguments from xargs' : undef; }
    return "run git with a name the guard cannot read ($sub)" if $sub =~ $DYNAMIC;
    return 'run git push' if $sub eq 'push';
    return "run git $sub" if $sub =~ /^(?:send-pack|http-push)$/;
    return 'run git subtree push' if $sub eq 'subtree' && ($a[$i + 1] // '') eq 'push';
    return 'run git config for an alias' if $sub eq 'config' && grep { /^alias\./i } @a[$i + 1 .. $#a];
    return;
  }
  if ($cmd eq 'gh') {
    my $i = 1;
    my $skip = sub { while ($i < @a && $a[$i] =~ /^-/) { my $o = $a[$i]; $i += ($o =~ /^(?:-R|--repo|--hostname)$/) ? 2 : 1; } };
    $skip->();
    my $group = $a[$i];
    if (!defined $group) { return $VIA_XARGS ? 'run gh with arguments from xargs' : undef; }
    $i++;
    return "run gh with a name the guard cannot read ($group)" if $group =~ $DYNAMIC;
    if ($group eq 'pr' || $group eq 'issue') {
      $skip->();
      my $verb = $a[$i];
      return unless defined $verb;
      return "run gh $group with a name the guard cannot read ($verb)" if $verb =~ $DYNAMIC;
      my $read = $group eq 'pr' ? \%GH_PR_READ : \%GH_ISSUE_READ;
      return "run gh $group $verb" unless $read->{$verb};
      return;
    }
    return gh_api(@a[$i .. $#a]) if $group eq 'api';
    $skip->();
    my $verb = $a[$i];
    return "run gh $group $verb" if defined $verb && $GH_MUTATING{$verb};
    return;
  }
  if ($cmd eq 'az') {
    my @p;
    my $VAL = qr/^(?:--output|-o|--query|--subscription|--organization|--org|--project|-p|--detect)$/;
    for (my $j = 1; $j < @a; $j++) {
      my $w = $a[$j];
      if ($w =~ /^-/) { $j++ if $w =~ $VAL && $w !~ /=/; next; }
      push @p, $w;
    }
    return 'run az with arguments from xargs' if !@p && $VIA_XARGS;
    return "run az with a name the guard cannot read ($p[0])" if @p && grep { /$DYNAMIC/ } @p[0 .. ($#p < 2 ? $#p : 2)];
    my $g = join ' ', @p[0 .. ($#p < 1 ? $#p : 1)];
    if ($g eq 'repos pr') {
      my $sub = $p[2] // return;
      return if $sub =~ /^(?:show|list|checkout)$/;
      return if $sub =~ /^(?:policy|reviewer|work-item)$/ && ($p[3] // '') eq 'list';
      return 'run az repos pr ' . join(' ', grep { defined } @p[2, 3]);
    }
    if ($g eq 'boards work-item') {
      my $sub = $p[2] // return;
      return if $sub eq 'show';
      return if $sub eq 'relation' && ($p[3] // '') =~ /^(?:show|list-type)$/;
      return 'run az boards work-item ' . join(' ', grep { defined } @p[2, 3]);
    }
    return 'run az pipelines run' if $g eq 'pipelines run';
    return 'run az pipelines build queue' if $g eq 'pipelines build' && ($p[2] // '') eq 'queue';
    if (($p[0] // '') =~ /^(?:pipelines|repos|boards|devops|artifacts)$/) {
      for my $w (@p[1 .. ($#p < 3 ? $#p : 3)]) { return "run az $p[0] $w" if $AZ_MUTATING{$w}; }
    }
    if (($p[0] // '') eq 'rest' || $g eq 'devops invoke') {
      for (my $j = 1; $j < @a; $j++) {
        my $m = $a[$j] =~ /^(?:--method|-m|--http-method)$/ ? ($a[$j + 1] // '') : $a[$j] =~ /^--(?:method|http-method)=(.*)$/ ? $1 : next;
        return "run az $g with the method $m" if uc($m) ne 'GET';
      }
    }
    return;
  }
  if ($cmd eq 'cd' || $cmd eq 'pushd') {
    return "enter the binding folder or the .claude folder ($cmd $a[1]). Only story-bind.sh of the orchestrator changes them" if defined $a[1] && (protected($a[1]) || clean_path($a[1]) =~ m{(?:^|/)\.(?:claude|plans)/?$});
    return;
  }
  my $sedi = $cmd eq 'sed' && grep { /^-[A-Za-z]*i|^--in-place/ } @a[1 .. $#a];
  if ($WRITER{$cmd} || $sedi || ($cmd eq 'find' && grep { $_ eq '-delete' } @a)) {
    for my $w (@a[1 .. $#a]) {
      (my $path = $w) =~ s/^of=//;
      return "change the binding files or the repo config ($cmd $w). Only story-bind.sh of the orchestrator does that" if protected($path);
      return "remove the .plans or .claude folder ($cmd $w)" if $cmd =~ /^(?:rm|mv|rmdir|unlink)$/ && clean_path($path) =~ m{(?:^|/)\.(?:plans|claude)/?$};
    }
  }
  return;
}

# feed_text: the text that an echo or printf command writes.
sub feed_text {
  my @w = @_;
  my $cmd = shift @w;
  my $t;
  if ($cmd eq 'echo') {
    shift @w while @w && $w[0] =~ /^-[neE]+$/;
    $t = join ' ', @w;
  } else {
    my $fmt = shift(@w) // '';
    my $i = 0;
    $fmt =~ s/%[sb]/ $i < @w ? $w[$i++] : '' /ge;
    $t = join ' ', $fmt, @w[$i .. $#w];
  }
  $t =~ s/\\n/\n/g;
  $t =~ s/\\x([0-9a-fA-F]{2})/chr(hex($1))/ge;
  return $t;
}

# check_argv: the verdict for one command that runs as argv (after normalize).
sub check_argv {
  my ($c, $k, $cmds, $depth, @argv) = @_;
  my $b = $argv[0];
  if ($b eq 'eval') {
    return analyse(join(' ', @argv[1 .. $#argv]), $depth + 1);
  }
  if ($b eq 'emulate') {
    for my $j (1 .. $#argv - 1) { return analyse($argv[$j + 1], $depth + 1) if $argv[$j] eq '-c'; }
    return;
  }
  if ($b eq 'source' || $b eq '.' || $SHELL{$b}) {
    return denied("run a script from a process substitution that the guard cannot see ($b)") if grep { $_ eq 'PROCESS' } @argv[1 .. $#argv];
    my @sh = $b eq 'source' || $b eq '.' ? ((grep { $_ eq '/dev/stdin' } @argv) ? (0) : ()) : shell_script(@argv);
    if (@sh && $sh[0]) { return analyse($sh[1], $depth + 1); }
    if (@sh) {
      my @feed = (map({ $_->{body} } @{$c->{heredocs}}), @{$c->{herestrings}});
      my $m = $k;
      while ($m > 0 && $cmds->[$m - 1]{pipe}) {
        my $p = $cmds->[$m - 1];
        push @feed, map({ $_->{body} } @{$p->{heredocs}}), @{$p->{herestrings}};
        my @pa = normalize(@{$p->{words}});
        push @feed, feed_text(@pa) if @pa && $pa[0] =~ /^(?:echo|printf)$/;
        last unless @pa && $pa[0] =~ /^(?:cat|tee)$/;
        $m--;
      }
      for my $f (@feed) { my $r = analyse($f, $depth + 1); return $r if defined $r; }
    }
    return;
  }
  if ($b eq 'find') {
    for (my $j = 1; $j < @argv; $j++) {
      next unless $argv[$j] =~ /^-(?:exec|execdir|ok|okdir)$/;
      my @sub;
      for (my $m = $j + 1; $m < @argv && $argv[$m] ne ';' && $argv[$m] ne '+'; $m++) { push @sub, $argv[$m]; }
      my @n = normalize(@sub);
      if (defined $DYN) { return denied("run a command whose name the guard cannot read ($DYN)"); }
      if (@n) { my $r = check_argv($c, $k, $cmds, $depth, @n); return $r if defined $r; my $d = verdict(@n); return $d if defined $d; }
    }
  }
  if ($b eq 'git') {
    my %RUNS = map { $_ => 1 } qw(foreach run);
    for my $j (1 .. $#argv - 1) {
      my $w = $argv[$j];
      if (($w eq '-x' || $w eq '--exec') && ($argv[1] // '') =~ /^(?:rebase|difftool)$/ || $w =~ /^--exec=(.*)$/) {
        my $r = analyse($w =~ /^--exec=(.*)$/ ? $1 : $argv[$j + 1], $depth + 1); return $r if defined $r;
      }
      if ($RUNS{$w} && ($argv[$j - 1] // '') =~ /^(?:submodule|bisect)$/) {
        my $r = analyse(join(' ', @argv[$j + 1 .. $#argv]), $depth + 1); return $r if defined $r;
      }
    }
  }
  return verdict(@argv);
}

my $ASSIGN = qr/^(?:CLAUDE_CODE_[A-Z0-9_]+|STORY_[A-Z0-9_]+|CLAUDE_PROJECT_DIR|CLAUDE_CONFIG_DIR|CLAUDE_PLUGIN_ROOT)=/;

sub analyse {
  my ($script, $depth) = @_;
  return "parse\tthe command nests shells or substitutions deeper than $MAX_DEPTH levels" if $depth > $MAX_DEPTH;
  my $cmds = eval { lex($script) };
  if (!defined $cmds) { (my $e = $@) =~ s/\s+$//; return "parse\tthe command has $e"; }
  for my $k (0 .. $#$cmds) {
    my $c = $cmds->[$k];
    my @nested = @{$c->{nested}};
    for my $h (@{$c->{heredocs}}) {
      next if $h->{quoted};
      my $tmp = newcmd();
      my $j = 0;
      eval { read_dq($h->{body}, \$j, $tmp, undef); 1 } or return "parse\tthe heredoc body has $@";
      push @nested, @{$tmp->{nested}};
    }
    for my $sub (@nested) { my $r = analyse($sub, $depth + 1); return $r if defined $r; }
    for my $r (@{$c->{redirs}}) {
      next unless $r->[0] =~ /^>/ && protected($r->[1]);
      my $d = denied("write to the binding files or the repo config ($r->[0] $r->[1]). Only story-bind.sh of the orchestrator does that");
      return $d if defined $d;
    }
    my $first = base(($c->{words}[0] // ''));
    for my $wi (0 .. $#{$c->{words}}) {
      my $w = $c->{words}[$wi];
      next unless $w =~ $ASSIGN;
      next if $c->{quoted}[$wi] && $first !~ /^(?:export|declare|typeset|readonly|local|env|sh|bash|zsh)$/;
      (my $name = $w) =~ s/=.*//s;
      my $d = denied("set $name in a command. The session identity and the story variables belong to the harness");
      return $d if defined $d;
    }
    for my $d (@deny) {
      for my $text (join(' ', @{$c->{words}}), join(' ', normalize(@{$c->{words}}))) {
        next unless length $text && $text =~ $d->[1];
        my $x = denied("run a command that matches the guard.deny entry $d->[0]");
        return $x if defined $x;
        last;
      }
    }
    my @argv = normalize(@{$c->{words}});
    if (defined $DYN) { my $x = denied("run a command whose name the guard cannot read ($DYN)"); return $x if defined $x; next; }
    next unless @argv;
    my $r = check_argv($c, $k, $cmds, $depth, @argv);
    return $r if defined $r;
  }
  return;
}

local $/;
my $input = <STDIN> // '';
my $hit = analyse($input, 0);
if ($BOARD) { my %seen; print "$_\n" for grep { !$seen{$_}++ } @HITS; }
print "$hit\n" if defined $hit;
exit 0;
