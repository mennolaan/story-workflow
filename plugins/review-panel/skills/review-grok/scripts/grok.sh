#!/usr/bin/env bash
# Grok finder adapter of /review-grok (Grok Build CLI). Contract:
#   grok.sh preflight [--static]   CLI on PATH, version in lib.sh, logged in, and one probe turn
#                                  that must report exactly the allowlist; --static skips the probe
#   grok.sh version                print the CLI version
#   grok.sh run <prompt-file> <out-file> <log-file> <cwd> [--model m] [--effort e] [--timeout s] [--schema f] [--dry-run]
# `run` is read-only, writes only <out-file> (the final message, or with --schema the structured
# JSON) and <log-file>, and exits non-zero on any failure, a timeout and the turn cap included.
#
# Isolation: every grok process starts with HOME and GROK_HOME in a fresh private temp dir that
# holds only a symlink to the real auth.json. Grok then loads no user config, no plugin, no MCP
# server, no hook, no skill and no memory of an earlier run: it discovers plugins under
# $HOME/.claude/plugins, and GROK_CONFIG plugins.disabled does not unload them (verified on
# 1.0.46, 2026-10-05). GROK_CLAUDE_*_ENABLED=0 also blocks the Claude files of the repo under review.
#
# Read-only: the tool allowlist is read_file, grep and list_dir; Agent, search_tool and use_tool are
# denied; web and subagents are off. The run has no write tool and no shell. The runner proves it
# afterwards (check_tree_untouched). preflight runs one probe turn in an empty dir and fails unless
# the available_commands events name exactly the allowlist.
# The kernel sandbox is opt-in (REVIEW_GROK_SANDBOX=<profile>): the built-in read-only
# profile refuses to start while /var/run/docker.sock is a symlink, as OrbStack makes it
# ("runtime-socket deny path ... endpoint is a symlink", 1.0.4 and 1.0.46). Grok refuses to start
# when a profile cannot apply, so a set profile never degrades to no sandbox.
# Telemetry: the isolated GROK_HOME gets a config.toml and the env with every telemetry and update
# switch off: GROK_TELEMETRY_ENABLED=0 ([features] telemetry, the product-analytics master switch),
# GROK_TELEMETRY_MIXPANEL_ENABLED=0 ([telemetry] mixpanel_enabled), GROK_TELEMETRY_TRACE_UPLOAD=0
# ([telemetry] trace_upload), GROK_FEEDBACK_ENABLED=0 ([features] feedback) and
# GROK_DISABLE_AUTOUPDATER=1 ([cli] auto_update). Source: the configuration and environment
# variable reference built into grok 1.0.46 (`strings` of the binary), read 2026-11-11; env vars
# take precedence over config.toml there. Not yet confirmed by a live run under a network monitor.
# The session relay to grok.com (`relay.enabled`) is left as Grok sets it: whether a headless run
# needs it is not verified.
# Network: a run needs https://cli-chat-proxy.grok.com (GROK_CLI_CHAT_PROXY_BASE_URL overrides it).
# preflight tests that connection first: behind a sandbox that blocks the host, Grok 1.0.46 reports
# `Couldn't set model 'grok-4.7': Invalid params: "unknown model id"`, which names the model, not
# the network (seen 2026-11-10).
# Model: grok-4.7 unless --model is given (owner choice, 2026-10-05).
# Bounds: --max-turns (REVIEW_GROK_MAX_TURNS, default 40) and the runner's --timeout. The
# first plan review used 10, 11 and 14 turns and took at most 12 min 36 s per head (2026-10-05).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${here}/lib.sh"

GROK_MODEL_DEFAULT="grok-4.7"
GROK_TOOLS="read_file,grep,list_dir"
GROK_DENIED_TOOLS="Agent,search_tool,use_tool"
GROK_MAX_TURNS="${REVIEW_GROK_MAX_TURNS:-40}"
GROK_PROBE_TIMEOUT=180
GROK_PROXY_URL="${GROK_CLI_CHAT_PROXY_BASE_URL:-https://cli-chat-proxy.grok.com/}"
real_grok_home="${GROK_HOME:-${HOME}/.grok}"

version() { grok --version 2>/dev/null | head -1 | awk '{print $2}'; }

# isolated <command...>: runs the command with HOME and GROK_HOME in a private temp dir, then removes it.
isolated() {
  local tmp="${TMPDIR:-/tmp}" iso rc=0
  iso="$(mktemp -d "${tmp%/}/review-grok-home.XXXXXX")"
  chmod 700 "${iso}"
  mkdir "${iso}/.grok"
  [ -f "${real_grok_home}/auth.json" ] && ln -s "${real_grok_home}/auth.json" "${iso}/.grok/auth.json"
  printf '%s\n' '[cli]' 'auto_update = false' '[features]' 'telemetry = false' 'feedback = false' \
    '[telemetry]' 'mixpanel_enabled = false' 'trace_upload = false' > "${iso}/.grok/config.toml"
  env HOME="${iso}" GROK_HOME="${iso}/.grok" GROK_DISABLE_AUTOUPDATER=1 GROK_MEMORY=0 \
    GROK_TELEMETRY_ENABLED=0 GROK_TELEMETRY_MIXPANEL_ENABLED=0 GROK_TELEMETRY_TRACE_UPLOAD=0 GROK_FEEDBACK_ENABLED=0 \
    GROK_CLAUDE_AGENTS_ENABLED=0 GROK_CLAUDE_HOOKS_ENABLED=0 GROK_CLAUDE_MCPS_ENABLED=0 \
    GROK_CLAUDE_RULES_ENABLED=0 GROK_CLAUDE_SKILLS_ENABLED=0 "$@" || rc=$?
  rm -rf "${iso}"
  return "${rc}"
}

base_args() {  # base_args <cwd> <model>: sets ARGS
  ARGS=(--cwd "$1" -m "$2" --tools "${GROK_TOOLS}" --disallowed-tools "${GROK_DENIED_TOOLS}"
        --disable-web-search --no-subagents --no-plan)
  [ -n "${REVIEW_GROK_SANDBOX:-}" ] && ARGS+=(--sandbox "${REVIEW_GROK_SANDBOX}")
  return 0
}

# check_proxy: one HTTPS request to the Grok chat proxy, so a blocked network is named as such.
# Any HTTP answer passes; only a failed connection (DNS, refused, proxy CONNECT denied, timeout) fails.
check_proxy() {
  local host err
  host="${GROK_PROXY_URL#*://}"; host="${host%%/*}"
  command -v curl >/dev/null 2>&1 || { echo "WARN: curl not on PATH; the connection to ${host} is not tested before the probe" >&2; return 0; }
  err="$(curl -sS -o /dev/null --max-time 10 "${GROK_PROXY_URL}" 2>&1)" && return 0
  echo "FAIL: no connection to ${host}:443 (sandbox or proxy). Allow the host, then run the preflight again. curl: ${err}" >&2
  return 1
}

preflight() {
  local static=0 probe rc=0
  [ "${1:-}" = --static ] && static=1
  command -v grok >/dev/null 2>&1 || { echo "FAIL: grok CLI not on PATH; install it: curl -fsSL https://x.ai/cli/install.sh | bash, then pin the version in scripts/lib.sh" >&2; return 1; }
  check_grok_pin "$(version)" || return 1
  [ -f "${real_grok_home}/auth.json" ] || [ -n "${XAI_API_KEY:-}" ] \
    || { echo "FAIL: grok is not logged in (no ${real_grok_home}/auth.json and no XAI_API_KEY); run: grok login" >&2; return 1; }
  [ "${static}" = 1 ] && return 0
  check_proxy || return 1
  probe="$(mktemp -d "${TMPDIR:-/tmp}/review-grok-probe.XXXXXX")"
  base_args "${probe}" "${GROK_MODEL_DEFAULT}"
  timeout_prefix "${GROK_PROBE_TIMEOUT}"
  isolated "${TIMEOUT_PREFIX[@]}" grok -p "Reply with the word ok." "${ARGS[@]}" --max-turns 3 --output-format streaming-json \
    > "${probe}.ndjson" 2> "${probe}.err" || rc=$?
  if [ "${rc}" != 0 ]; then
    [ "${rc}" = "${TIMEOUT_EXIT}" ] && echo "FAIL: the grok probe turn timed out after ${GROK_PROBE_TIMEOUT} s" >&2
    echo "FAIL: the grok probe turn exited ${rc}; see the error below. A login problem: run grok login. A sandbox problem: unset REVIEW_GROK_SANDBOX or fix the cause it names." >&2
    tail -5 "${probe}.err" >&2
    grep -q 'unknown model id' "${probe}.err" \
      && echo "This error also shows when the Grok proxy cannot be reached: allow ${GROK_PROXY_URL} in the sandbox or proxy, then run the preflight again." >&2
    rm -rf "${probe}" "${probe}.ndjson" "${probe}.err"; return 1
  fi
  python3 - "${probe}.ndjson" "${GROK_TOOLS}" <<'PY' || rc=1
import json, sys
want = set(sys.argv[2].split(","))
seen, end = set(), None
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    event = json.loads(line)
    seen |= set(event.get("tools") or [])
    if event.get("type") == "end":
        end = event
if end is None or end.get("stopReason") != "end_turn":
    print(f"FAIL: the grok probe turn did not end normally (end event: {end})", file=sys.stderr); sys.exit(1)
if seen != want:
    print(f"FAIL: the grok probe reported tools {sorted(seen)}, expected exactly {sorted(want)}; "
          "a tool outside the read-only allowlist would reach the finder, so the run stops here", file=sys.stderr); sys.exit(1)
print(f"grok preflight: tools {sorted(seen)}, model {sorted((end.get('modelUsage') or {}).keys())}", file=sys.stderr)
PY
  rm -rf "${probe}" "${probe}.ndjson" "${probe}.err"
  return "${rc}"
}

run() {
  [ $# -ge 4 ] || { echo "usage: grok.sh run <prompt-file> <out-file> <log-file> <cwd> [--model m] [--effort e] [--timeout s] [--schema f] [--dry-run]" >&2; return 2; }
  local prompt="$1" out="$2" log="$3" cwd="$4" model="${GROK_MODEL_DEFAULT}" effort="" timeout="" schema="" dry=0 result rc=0
  shift 4
  while [ $# -gt 0 ]; do
    case "$1" in
      --model) model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      --schema) schema="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) echo "grok.sh run: unexpected argument: $1" >&2; return 2 ;;
    esac
  done
  case "${GROK_MAX_TURNS}" in *[!0-9]*|""|0) echo "FAIL: REVIEW_GROK_MAX_TURNS=${GROK_MAX_TURNS} is not a positive whole number" >&2; return 2 ;; esac
  base_args "${cwd}" "${model}"
  ARGS+=(--max-turns "${GROK_MAX_TURNS}")
  [ -n "${effort}" ] && ARGS+=(--reasoning-effort "${effort}")
  TIMEOUT_PREFIX=()
  [ -n "${timeout}" ] && timeout_prefix "${timeout}"
  if [ "${dry}" = 1 ]; then echo "dry-run: (isolated HOME${timeout:+, timeout ${timeout}s}) grok --prompt-file ${prompt} ${ARGS[*]}${schema:+ --json-schema <${schema}>} --output-format streaming-json > ${out}"; return 0; fi
  [ -n "${schema}" ] && ARGS+=(--json-schema "$(cat "${schema}")")
  result="$(mktemp "${TMPDIR:-/tmp}/review-grok-result.XXXXXX")"
  isolated ${TIMEOUT_PREFIX[@]+"${TIMEOUT_PREFIX[@]}"} grok --prompt-file "${prompt}" "${ARGS[@]}" --output-format streaming-json > "${result}" 2> "${log}" || rc=$?
  if [ "${rc}" != 0 ]; then
    [ "${rc}" = "${TIMEOUT_EXIT}" ] && echo "FAIL: grok timed out after ${timeout} s" >> "${log}"
    { echo "FAIL: grok exited ${rc}"; grep '"type":"end"' "${result}" || true; } >> "${log}"
    rm -f "${result}"; return 1
  fi
  # The final message is the text after the last tool event: the json result format joins the
  # narration of every turn into one text (first plan review, 2026-10-05). Every tool the stream
  # offers or calls must sit in the allowlist; this checks the real run, not only the preflight.
  # With --schema the out-file is the structuredOutput object of the end event (verified 1.0.46).
  python3 - "${result}" "${out}" "${GROK_TOOLS}" "${schema}" >> "${log}" <<'PY' || rc=1
import json, sys
allowed = set(sys.argv[3].split(","))
final, end, offered, called = [], None, set(), set()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    event = json.loads(line)
    kind = event.get("type")
    offered |= set(event.get("tools") or [])
    if kind == "tool_call":
        called.add(event.get("toolName"))
    if kind in ("tool_call", "tool_call_update"):
        final = []
    elif kind == "text":
        final.append(event.get("data") or "")
    elif kind == "end":
        end = event
text = "".join(final).strip()
meta = {k: (end or {}).get(k) for k in ("sessionId", "requestId", "stopReason", "num_turns", "usage", "modelUsage", "total_cost_usd")}
meta["tools_called"] = sorted(t for t in called if t)
print(json.dumps(meta))
if not offered <= allowed or not called <= allowed:
    print(f"FAIL: grok offered {sorted(offered)} and called {sorted(called)}, outside the allowlist {sorted(allowed)}; the output is discarded"); sys.exit(1)
if end is None or end.get("stopReason") != "end_turn" or not text:
    print(f"FAIL: grok stopReason={(end or {}).get('stopReason')}, final message {'empty' if not text else 'present'}"); sys.exit(1)
if sys.argv[4]:
    structured = end.get("structuredOutput")
    if not isinstance(structured, dict):
        print(f"FAIL: grok ran with a schema but its end event has no structuredOutput object ({type(structured).__name__})"); sys.exit(1)
    text = json.dumps(structured, indent=2)
with open(sys.argv[2], "w") as f:
    f.write(text + "\n")
PY
  rm -f "${result}"
  return "${rc}"
}

case "${1:-}" in
  preflight) shift; preflight "$@" ;;
  version) version ;;
  run) shift; run "$@" ;;
  *) echo "usage: grok.sh preflight [--static] | version | run <prompt-file> <out-file> <log-file> <cwd> [--model m] [--effort e] [--timeout s] [--schema f] [--dry-run]" >&2; exit 2 ;;
esac
