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
#   matched with /m against the words of each simple command joined by single
#   spaces, before and after the drop of VAR=value words and wrappers.
# - A write to the binding folder (STORY_SESSIONS_DIR, or any path with a
#   .sessions segment): rm, mv, cp, tee, truncate, ln, sed -i, and > or >>.
# Unbalanced quotes or parentheses give a parse line, so the child is denied.
use strict;
use warnings;

my $MAX_DEPTH = 8;
my $SESSIONS = $ENV{STORY_SESSIONS_DIR} // '';
my @deny;
for my $re (grep { length } split /\n/, ($ENV{STORY_GUARD_DENY} // '')) {
  my $q = eval { qr/$re/m };
  if (!defined $q) {
    (my $e = $@) =~ s/ at \S+ line \d+.*//s;
    print "bad\t$re\t$e\n";
    exit 0;
  }
  push @deny, [$re, $q];
}


sub newcmd { return { words => [], redirs => [], heredocs => [], herestrings => [], nested => [], pipe => 0 }; }

# read_subst: from just after "$(" or "<(" to the matching ")". Returns the inner text.
sub read_subst {
  my ($s, $ip) = @_;
  my $depth = 1;
  my $start = $$ip;
  my $n = length $s;
  while ($$ip < $n) {
    my $ch = substr($s, $$ip, 1);
    if ($ch eq '\\') { $$ip += 2; next; }
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
      if (substr($s, $$ip + 2, 1) eq '(') { $$ip += 2; read_subst($s, $ip); $out .= '$((...))'; next; }
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
        if (substr($s, $i + 2, 1) eq '(') { $i += 2; read_subst($s, \$i); $word .= '$((...))'; $inword = 1; next; }
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
            my $e = substr($s, $j + 1, 1);
            $out .= $e eq 'n' ? "\n" : $e eq 't' ? "\t" : $e;
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
my %WRAPPER = map { $_ => 1 } qw(env command exec nohup time sudo xargs builtin);
my %OPTARG = (
  env => { map { $_ => 1 } qw(-u --unset -C --chdir -S --split-string) },
  sudo => { map { $_ => 1 } qw(-u --user -g --group -C --close-from -D --chdir -h --host -p --prompt -r --role -t --type -U --other-user -T --command-timeout) },
  xargs => { map { $_ => 1 } qw(-I -n -L -l -P -d -E -e -s -a --max-args --max-lines --max-procs --delimiter --eof --max-chars --arg-file --replace) },
  exec => { '-a' => 1 },
);

sub base { my ($w) = @_; $w =~ s{.*/}{}; return $w; }

# normalize: argv without leading VAR=value words, keywords and wrappers.
# An empty list means the command runs nothing (command -v git).
sub normalize {
  my @w = @_;
  while (@w) {
    if ($w[0] =~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/ || $KEYWORD{$w[0]}) { shift @w; next; }
    my $b = base($w[0]);
    last unless $WRAPPER{$b};
    shift @w;
    while (@w && $w[0] =~ /^-/) {
      my $o = shift @w;
      last if $o eq '--';
      return () if $b eq 'command' && $o =~ /^-[pvV]*[vV]/;
      shift @w if $OPTARG{$b} && $OPTARG{$b}{$o} && @w;
    }
  }
  $w[0] = base($w[0]) if @w;
  return @w;
}

my %SHELL = map { $_ => 1 } qw(bash sh zsh dash ksh);

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
  return (0) if !@w || $w[0] eq '-s';
  return ();
}

sub under_sessions {
  my ($p) = @_;
  return 1 if $p =~ m{(?:^|/)\.sessions(?:/|$)};
  return 1 if length $SESSIONS && index($p, $SESSIONS) == 0;
  return 0;
}

my %GH_PR_READ = map { $_ => 1 } qw(view list diff checks status checkout);
my %GH_ISSUE_READ = map { $_ => 1 } qw(view list status);

# rules: the built-in deny rules on one normalized argv.
sub rules {
  my @a = @_;
  my $cmd = $a[0];
  if ($cmd eq 'git') {
    my $i = 1;
    while ($i < @a && $a[$i] =~ /^-/) {
      my $o = $a[$i];
      $i += ($o =~ /^(?:-C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--exec-path)$/) ? 2 : 1;
    }
    return 'run git push' if ($a[$i] // '') eq 'push';
    return;
  }
  if ($cmd eq 'gh') {
    my $i = 1;
    my $skip = sub { while ($i < @a && $a[$i] =~ /^-/) { my $o = $a[$i]; $i += ($o =~ /^(?:-R|--repo|--hostname)$/) ? 2 : 1; } };
    $skip->();
    my $group = $a[$i] // '';
    $i++;
    if ($group eq 'pr' || $group eq 'issue') {
      $skip->();
      my $verb = $a[$i];
      return unless defined $verb;
      my $read = $group eq 'pr' ? \%GH_PR_READ : \%GH_ISSUE_READ;
      return "run gh $group $verb" unless $read->{$verb};
      return;
    }
    if ($group eq 'api') {
      my ($method, $field);
      for (my $j = $i; $j < @a; $j++) {
        my $o = $a[$j];
        if ($o eq '-X' || $o eq '--method') { $method = $a[$j + 1] // ''; $j++; }
        elsif ($o =~ /^-X(.+)$/ || $o =~ /^--method=(.*)$/) { $method = $1; }
        elsif ($o =~ /^(?:-[fF]|--field|--raw-field|--input)(?:$|=)/ || $o =~ /^-[fF]./) { $field = $o; }
      }
      return "run gh api $method" if defined $method && uc($method) ne 'GET';
      return "run gh api with $field (gh sends a POST)" if defined $field && !defined $method;
      return;
    }
    return;
  }
  if ($cmd eq 'az') {
    my @p;
    for my $w (@a[1 .. $#a]) { last if $w =~ /^-/; push @p, $w; }
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
    return;
  }
  if ($cmd =~ /^(?:rm|mv|cp|tee|truncate|ln|unlink|install)$/ || ($cmd eq 'sed' && grep { /^-[A-Za-z]*i|^--in-place/ } @a[1 .. $#a])) {
    for my $w (@a[1 .. $#a]) {
      return "change the binding files ($cmd $w). Only story-bind.sh of the orchestrator does that" if under_sessions($w);
    }
  }
  return;
}

sub printf_text {
  my @w = @_;
  my $t = join ' ', @w;
  $t =~ s/\\n/\n/g;
  return $t;
}

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
      return "deny\twrite to the binding files ($r->[0] $r->[1]). Only story-bind.sh of the orchestrator does that"
        if $r->[0] =~ /^>/ && under_sessions($r->[1]);
    }
    my @argv = normalize(@{$c->{words}});
    for my $d (@deny) {
      for my $text (join(' ', @{$c->{words}}), join(' ', @argv)) {
        return "deny\trun a command that matches the guard.deny entry $d->[0]" if length $text && $text =~ $d->[1];
      }
    }
    next unless @argv;
    my $b = $argv[0];
    if ($b eq 'eval') {
      my $r = analyse(join(' ', @argv[1 .. $#argv]), $depth + 1);
      return $r if defined $r;
      next;
    }
    if ($SHELL{$b}) {
      my @sh = shell_script(@argv);
      if (@sh && $sh[0]) {
        my $r = analyse($sh[1], $depth + 1);
        return $r if defined $r;
      } elsif (@sh) {
        my @feed = (map({ $_->{body} } @{$c->{heredocs}}), @{$c->{herestrings}});
        if ($k > 0 && $cmds->[$k - 1]{pipe}) {
          my $p = $cmds->[$k - 1];
          push @feed, map({ $_->{body} } @{$p->{heredocs}}), @{$p->{herestrings}};
          my @pa = normalize(@{$p->{words}});
          push @feed, printf_text(@pa[1 .. $#pa]) if @pa && $pa[0] =~ /^(?:echo|printf)$/;
        }
        for my $f (@feed) { my $r = analyse($f, $depth + 1); return $r if defined $r; }
      }
      next;
    }
    my $r = rules(@argv);
    return "deny\t$r" if defined $r;
  }
  return;
}

local $/;
my $input = <STDIN> // '';
my $hit = analyse($input, 0);
print "$hit\n" if defined $hit;
exit 0;
