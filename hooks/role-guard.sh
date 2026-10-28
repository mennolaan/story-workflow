#!/usr/bin/env bash
# Claude Code PreToolUse (AskUserQuestion|Bash): a bound child session (plan,
# implement, pr-review) does not ask the user and does not act outward. Only
# the orchestrator does (skills/story/SKILL.md, "Authority").
# Denied for a child role:
#   AskUserQuestion
#   git push
#   az repos pr, every command except show, list, checkout and <group> list
#   az boards work-item, every command except show and relation show|list-type
#   az pipelines run, az pipelines build queue
#   gh pr, every command except view, list, diff, checks, status and checkout
#   gh issue, every command except view, list and status
#   each Perl regex in "guard.deny" of .claude/story.json, matched with /m on
#   the same cleaned command as the rules above
# in Bash and in mcp__terminal__run_in_terminal (the user's own shell). A
# guard.deny value that is not a list of strings, or an entry that is not a
# valid regex, exits 1 with the reason.
# Without .claude/story.json every call passes with no output (story_enabled).
# The orchestrator and unbound sessions pass. Heredoc bodies and quoted
# strings are removed before the match, so a commit message or a notes file
# that mentions "git push" is not a push. Kept, because they run: command
# substitutions inside double quotes, the quoted script after
# `bash|sh|zsh -c` or `eval`, a heredoc body on a line that names bash,
# sh or zsh, and a quoted string that `<<<` or a pipe feeds to bash, sh or
# zsh. A command after a path matches too (`/usr/bin/git push`).
# mcp__ccd_session_mgmt__clear_session passes with no decision only for a bound
# orchestrator whose target is bound with the orchestrator as its parent.
# Every other call gets "ask" (a prompt even in auto mode), because the
# settings allow clear_session for every session of the repo.
# Deny is the JSON permissionDecision form (code.claude.com/docs/en/hooks,
# as of 2026-10-27). Without jq, or on an input that is not JSON, it exits 1
# with the reason: a non-blocking error the user sees. Without jq a
# clear_session call gets a fixed "ask", because after an exit 1 the settings
# allow rule approves the call with no check.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

input="$(cat)"
story_enabled || exit 0
if ! command -v jq >/dev/null 2>&1; then
  if grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"mcp__ccd_session_mgmt__clear_session"' <<<"${input}"; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"role-guard: jq is not on PATH, so the clear_session check did not run. Approve only the clear of your own idle child. Install jq (brew install jq)."}}'
    exit 0
  fi
  echo "role-guard: jq is not on PATH, so the guard did not run. Install it (brew install jq)." >&2
  exit 1
fi
jq -e . >/dev/null 2>&1 <<<"${input}" || { echo "role-guard: the hook input is not JSON, so the guard did not run. Input: ${input:0:200}" >&2; exit 1; }

b="$(story_binding "${input}")"
tool="$(jq -r '.tool_name // empty' <<<"${input}")"

if [ "${tool}" = mcp__ccd_session_mgmt__clear_session ]; then
  target="$(jq -r '.tool_input.session_id // empty' <<<"${input}")"
  ask() {
    jq -cn --arg r "role-guard: clear_session of ${target:-an unnamed session} needs your approval, because $1. The settings allow clear_session only for an orchestrator that resets its own idle child." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
    exit 0
  }
  [ -n "${b}" ] || ask "this session is not bound to a story"
  [ "$(story_field "${b}" role)" = orchestrator ] || ask "this session is not an orchestrator"
  [ -n "${target}" ] && [ "${target}" != self ] || ask "the target is this session itself"
  [ "${target}" = "$(story_clean "${target}")" ] || ask "the target id holds characters outside A-Z a-z 0-9 . _ -"
  dir="$(story_plans_dir)" || ask "the shared .plans folder is not found"
  tb="${dir}/.sessions/${target}.json"
  [ -f "${tb}" ] || ask "the target is not bound to a story"
  [ "$(story_field "${tb}" parent)" = "$(basename "${b}" .json)" ] || ask "the target is not a child of this orchestrator"
  exit 0
fi

[ -n "${b}" ] || exit 0
role="$(story_field "${b}" role)"
story_is_child "${role}" || exit 0
slug="$(story_field "${b}" slug)"
parent="$(story_field "${b}" parent)"

deny() {
  jq -cn --arg r "role-guard: the ${role} session of story ${slug} does not $1. Only the orchestrator (${parent:-see the binding}) does that. Send a QUESTION with the options and your recommendation to the orchestrator with SendMessage, then end the turn." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

case "${tool}" in
  AskUserQuestion) deny "ask the user (AskUserQuestion)" ;;
  Bash|mcp__terminal__run_in_terminal) ;;
  *) exit 0 ;;
esac

cmd="$(jq -r '.tool_input.command // empty' <<<"${input}")"
[ -n "${cmd}" ] || exit 0
config="$(story_config_file)"
extra="$(jq -r '(.guard.deny // []) | if type == "array" and all(.[]; type == "string") then .[] else error("guard.deny is not a list of strings") end' "${config}" 2>&1)" \
  || { echo "role-guard: guard.deny in ${config} must be a list of regex strings, so the guard did not run: ${extra}" >&2; exit 1; }

hit="$(printf '%s' "${cmd}" | STORY_GUARD_DENY="${extra}" perl -e '
  local $/; my $s = <STDIN>;
  my @out; my $delim; my $dash; my $keep;
  for my $line (split /\n/, $s, -1) {
    if (defined $delim) {
      my $t = $dash ? ($line =~ s/^\t+//r) : $line;
      if ($t eq $delim) { undef $delim; } elsif ($keep) { push @out, $line; }
      next;
    }
    if ($line =~ /<<(-?)\s*([\x27"]?)([A-Za-z_][A-Za-z0-9_]*)\2/) { $dash = $1; $delim = $3; $keep = $line =~ /(?:^|[\s;&|(){}!`\/])(?:ba|z)?sh(?:\s|$)/; }
    push @out, $line;
  }
  $s = join "\n", @out;
  my $run = qr/(?:\b(?:ba|z)?sh(?:\s+--?[A-Za-z][\w-]*)*?\s+-[A-Za-z]*c[A-Za-z]*(?:\s+--?[A-Za-z][\w-]*)*|\beval)\s+/;
  $s =~ s/$run\x27([^\x27]*)\x27/ ; $1 ; /g;
  $s =~ s/$run"((?:\\.|[^"\\])*)"/ ; $1 ; /gs;
  my $sh = qr/(?:^|[\s;&|(){}!`\/])(?:ba|z)?sh\b/;
  $s =~ s/(${sh}[^\n|;&]*<<<\s*)\x27([^\x27]*)\x27/$1 ; $2 ; /g;
  $s =~ s/(${sh}[^\n|;&]*<<<\s*)"((?:\\.|[^"\\])*)"/$1 ; $2 ; /gs;
  $s =~ s/\x27([^\x27]*)\x27(?=[^\n;&]*\|\s*(?:\S*\/)?(?:ba|z)?sh\b)/ ; $1 ; /g;
  $s =~ s/"((?:\\.|[^"\\])*)"(?=[^\n;&]*\|\s*(?:\S*\/)?(?:ba|z)?sh\b)/ ; $1 ; /gs;
  $s =~ s/\x27[^\x27]*\x27/ Q /g;
  $s =~ s{"((?:\\.|[^"\\])*)"}{ my $in = $1; my @subs = ($in =~ /\$\(([^()]*)\)/g); " Q " . join(" ; ", @subs) . " " }gse;
  my $b = qr/(?:^|[\s;&|(){}!`\/])/;
  my $opt = qr/(?:\s+(?:-C|-c)\s+\S+|\s+--?[A-Za-z][\w-]*(?:=\S+)?)*/;
  my @rules = (
    [qr/${b}git${opt}\s+push\b/, "git push"],
    [qr/${b}az\s+repos\s+pr\s+(?!(?:show|list|checkout)\b|(?:policy|reviewer|work-item)\s+list\b)([a-z][a-z-]*(?:\s+[a-z][a-z-]*)?)/, "az repos pr"],
    [qr/${b}az\s+boards\s+work-item\s+(?!show\b|relation\s+(?:show|list-type)\b)([a-z][a-z-]*(?:\s+[a-z][a-z-]*)?)/, "az boards work-item"],
    [qr/${b}az\s+pipelines\s+run\b/, "az pipelines run"],
    [qr/${b}az\s+pipelines\s+build\s+queue\b/, "az pipelines build queue"],
    [qr/${b}gh\s+pr\s+(?!(?:view|list|diff|checks|status|checkout)\b)([a-z][a-z-]*)/, "gh pr"],
    [qr/${b}gh\s+issue\s+(?!(?:view|list|status)\b)([a-z][a-z-]*)/, "gh issue"],
  );
  for my $r (@rules) {
    if ($s =~ $r->[0]) { my $x = $1 // ""; print "run " . $r->[1] . ($x ne "" ? " $x" : ""); exit 0; }
  }
  for my $re (grep { length } split /\n/, ($ENV{STORY_GUARD_DENY} // "")) {
    my $q = eval { qr/$re/m };
    if (!defined $q) { (my $e = $@) =~ s/ at -e line .*//s; print "BAD\t$re\t$e"; exit 0; }
    if ($s =~ $q) { print "run a command that matches the guard.deny entry $re"; exit 0; }
  }
')"
case "${hit}" in
  BAD$'\t'*)
    IFS=$'\t' read -r _ re why <<<"${hit}"
    echo "role-guard: the guard.deny entry '${re}' in ${config} is not a valid Perl regex (${why}), so the guard did not run. Fix the entry." >&2
    exit 1 ;;
esac
[ -n "${hit}" ] && deny "${hit}"
exit 0
