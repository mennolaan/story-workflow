#!/usr/bin/env bash
# Claude Code PreToolUse (hooks/hooks.json routes Agent, Task, Bash, Monitor
# and mcp__.*): story, task and issue reads run only in the story-reader agent
# (agents/story-reader.md), on haiku. A read returns large JSON, and on the
# session model all of it stays in the context. The reader returns a digest.
# Three checks:
#   R1 read gate. Bash, Monitor, mcp__terminal__run_in_terminal, and each MCP
#      tool whose name fully matches a regex in board.readTools: every caller
#      that is not a reader is denied a board read.
#   R2 the reader only reads. In a reader: a board or issue write, every rule
#      of role-guard.pl (git push, gh pr writes, az pipelines run, guard.deny,
#      the binding files), a command the guard cannot parse, and every MCP
#      tool outside board.readTools are denied. The terminal tool is checked
#      as a command.
#   R3 spawn gate. Agent and Task: a story-reader spawn needs model "haiku".
#      While CLAUDE_CODE_SUBAGENT_MODEL_FORCE makes every subagent run on
#      CLAUDE_CODE_SUBAGENT_MODEL, the spawn passes when that model is haiku
#      and is denied when it is not, because FORCE ignores the parameter.
# A reader: the hook input has agent_id, and agent_type is story-reader or
# story-workflow:story-reader. agent_type alone never counts: a main thread
# started with --agent has agent_type and no agent_id, and no spawn gate
# checked its model.
# The subagent_type of a spawn is normalized as the Agent tool does it (NFKC,
# lower case, no white space, dash punctuation or _), so StoryReader and
# story_reader are the reader too.
# Reads (role-guard.pl board mode): az boards work-item show and relation
# show, az boards query, az devops invoke and az rest on wit (GET, or a POST of
# wiql or workitemsbatch), gh issue view|list|status, gh search issues, gh
# project item-list, gh api on issues with GET, gh api graphql on issues, the
# words of board.show before the first word with { or the first option, and
# each Perl regex in board.reads.
# Config (.claude/story.json): board.reader false turns the guard off.
# board.reads and board.readTools are lists of Perl regex strings.
# Fail loud. Input that is not JSON: exit 1. No jq: deny when the input looks
# like a board read or a reader spawn, else exit 1. A command the parser
# cannot parse: a reader is denied, another caller only when the command
# looks like a board read. A parser failure: a reader is denied, another
# caller too when the command looks like a board read, else exit 1. A config
# jq cannot read, or a bad regex entry: every command and MCP call is denied,
# with the file and the entry.
# Without .claude/story.json every call passes with no output (story_enabled).
# A cost gate, not a security boundary: a read inside a script file, in
# another language or with curl is not seen.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

looks_like_read='boards|issue|_apis/wit|graphql'
hint='Spawn the story-reader agent (Agent, subagent_type "story-workflow:story-reader", model "haiku") with the read in its prompt, and use its digest. A subagent asks its caller to do that. Board writes stay in this thread.'

input="$(cat)"
story_enabled || exit 0
if ! command -v jq >/dev/null 2>&1; then
  if grep -Eiq "${looks_like_read}|story.?reader" <<<"${input}"; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"board-read-guard: jq is not on PATH, so the guard cannot check this call, which looks like a board read or a story-reader spawn, and denies it. Install jq (brew install jq)."}}'
    exit 0
  fi
  echo "board-read-guard: jq is not on PATH, so the guard did not run. Install it (brew install jq)." >&2
  exit 1
fi
# One jq call for the input and one for the config. @sh quotes each value for
# the shell, so the eval only assigns.
tool="" agent_id="" agent_type="" cmd="" type="" model=""
# shellcheck disable=SC2016 # the jq program is in single quotes on purpose.
fields="$(jq -r '@sh "tool=\(.tool_name // "" | tostring) agent_id=\(.agent_id // "" | tostring) agent_type=\(.agent_type // "" | tostring) cmd=\(.tool_input.command // "" | tostring) type=\(.tool_input.subagent_type // "" | tostring) model=\(.tool_input.model // "" | tostring)"' <<<"${input}" 2>/dev/null)" \
  || { echo "board-read-guard: the hook input is not JSON, so the guard did not run. Input: ${input:0:200}" >&2; exit 1; }
eval "${fields}"

deny() {
  jq -cn --arg r "board-read-guard: $1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

truthy() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0 ;; esac
  return 1
}

reader=""
if [ -n "${agent_id}" ]; then
  case "${agent_type}" in story-reader|story-workflow:story-reader) reader=1 ;; esac
fi

config="$(story_config_file)"
off=false reads="" tools="" show="" broken=""
# shellcheck disable=SC2016 # the jq program is in single quotes on purpose.
if cfg="$(jq -r 'def strs($k): (.board[$k] // []) | if type == "array" and all(.[]; type == "string") then join("\n") else error("board.\($k) is not a list of strings") end;
  @sh "off=\(.board.reader == false) reads=\(strs("reads")) tools=\(strs("readTools")) show=\(.board.show // "" | if type == "string" then . else "" end)"' "${config}" 2>&1)"; then
  eval "${cfg}"
else
  broken="${cfg}"
fi
[ "${off}" = true ] && exit 0

case "${tool}" in
  Agent|Task)
    [ -n "${type}" ] || exit 0
    norm="$(perl -CSA -MUnicode::Normalize -e 'my $s = lc NFKC(shift); $s =~ s/[\s\p{Pd}_]+//g; print $s' "${type}" 2>/dev/null)" \
      || norm="$(printf '%s' "${type}" | tr '[:upper:]' '[:lower:]' | tr -d ' \t_-')"
    case "${norm}" in storyreader|storyworkflow:storyreader) ;; *) exit 0 ;; esac
    if truthy "${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-}" && [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
      case "${CLAUDE_CODE_SUBAGENT_MODEL}" in *[Hh][Aa][Ii][Kk][Uu]*) exit 0 ;; esac
      deny "CLAUDE_CODE_SUBAGENT_MODEL_FORCE makes every subagent run on '${CLAUDE_CODE_SUBAGENT_MODEL}', so ${type} cannot run on haiku. Unset it, or set CLAUDE_CODE_SUBAGENT_MODEL=haiku."
    fi
    [ "${model}" = haiku ] || deny "spawn ${type} with model \"haiku\". This call has model '${model:-none}'."
    exit 0 ;;
  Bash|Monitor|mcp__terminal__run_in_terminal) ;;
  mcp__*)
    [ -z "${broken}" ] || deny "${config} cannot be read (${broken}), so the guard cannot check ${tool}. Fix the file."
    [ -z "${reader}" ] && [ -z "${tools}" ] && exit 0
    hit="$(STORY_READ_TOOLS="${tools}" perl -e '
      my $t = shift;
      my @q;
      for my $re (grep { length } split /\n/, ($ENV{STORY_READ_TOOLS} // "")) {
        my $q = eval { qr/^(?:$re)$/ };
        if (!defined $q) { print "BAD\t$re"; exit 0; }
        push @q, [$re, $q];
      }
      for my $p (@q) { if ($t =~ $p->[1]) { print "HIT\t$p->[0]"; exit 0; } }' "${tool}")" \
      || deny "the tool check (perl) failed, so the guard cannot check ${tool}. Check perl."
    case "${hit}" in
      BAD$'\t'*) deny "the board.readTools entry '${hit#BAD$'\t'}' in ${config} is not a valid Perl regex. Fix the entry." ;;
      HIT$'\t'*)
        [ -n "${reader}" ] && exit 0
        deny "${tool} reads the board on the session model (the board.readTools entry '${hit#HIT$'\t'}'). ${hint}" ;;
    esac
    [ -n "${reader}" ] && deny "the story-reader agent only reads, and ${tool} is not a read tool of board.readTools in ${config}. Return the digest. The caller does the rest."
    exit 0 ;;
  *) exit 0 ;;
esac

[ -n "${cmd}" ] || exit 0
[ -z "${broken}" ] || deny "${config} cannot be read (${broken}), so the guard cannot check this command. Fix the file."

# The board.show words before the first word with { or the first option. The
# command path is reduced to its basename, as the parser normalizes it.
show_words=()
read -r -a show_words <<<"${show}"
prefix=""
for w in ${show_words[@]+"${show_words[@]}"}; do
  case "${w}" in *'{'*|-*) break ;; esac
  [ -n "${prefix}" ] || w="${w##*/}"
  prefix="${prefix:+${prefix} }${w}"
done

deny_list=""
sessions=""
if [ -n "${reader}" ]; then
  deny_list="$(jq -r '(.guard.deny // []) | if type == "array" and all(.[]; type == "string") then .[] else error("guard.deny is not a list of strings") end' "${config}" 2>&1)" \
    || deny "${config} cannot be read: ${deny_list}. Fix the file."
  sessions="$(story_plans_dir 2>/dev/null)/.sessions"
fi

hits="$(printf '%s' "${cmd}" | STORY_GUARD_MODE=board STORY_BOARD_SHOW="${prefix}" STORY_BOARD_READS="${reads}" \
  STORY_GUARD_DENY="${deny_list}" STORY_SESSIONS_DIR="${sessions}" perl "${here}/role-guard.pl")"
prc=$?
if [ "${prc}" -ne 0 ]; then
  [ -z "${reader}" ] || deny "the command check (role-guard.pl) failed with exit ${prc}, so the story-reader agent runs no command. Check perl."
  if grep -Eiq "${looks_like_read}" <<<"${cmd}"; then deny "the command check (role-guard.pl) failed with exit ${prc}, and the command looks like a board read. Check perl. ${hint}"; fi
  echo "board-read-guard: the command check (role-guard.pl) failed with exit ${prc}, so the guard did not check the command. Check perl." >&2
  exit 1
fi

read_hits=""
write_hits=""
parse=""
bad=""
while IFS=$'\t' read -r kind what why; do
  case "${kind}" in
    read) read_hits="${read_hits:+${read_hits}; }${what}" ;;
    write) write_hits="${write_hits:+${write_hits}; }${what}" ;;
    parse) parse="${what}" ;;
    bad) bad="the guard.deny entry '${what}' in ${config} is not a valid Perl regex (${why})" ;;
    badread) bad="the board.reads entry '${what}' in ${config} is not a valid Perl regex (${why})" ;;
  esac
done <<<"${hits}"

[ -z "${bad}" ] || deny "${bad}. Fix the entry."
if [ -n "${reader}" ]; then
  [ -z "${write_hits}" ] || deny "the story-reader agent only reads. This command does more: ${write_hits}. Return the digest. The caller does the write."
  [ -z "${parse}" ] || deny "the story-reader agent runs only commands that the guard can parse (${parse}). Rewrite the command with balanced quotes."
  exit 0
fi
[ -z "${read_hits}" ] || deny "this command reads the board on the session model: ${read_hits}. ${hint}"
if [ -n "${parse}" ] && grep -Eiq "${looks_like_read}" <<<"${cmd}"; then
  deny "the guard cannot parse this command (${parse}), and it looks like a board read. Rewrite it with balanced quotes. ${hint}"
fi
exit 0
