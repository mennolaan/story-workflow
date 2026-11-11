#!/usr/bin/env bash
# Shared helpers of /review-grok, sourced by run-grok.sh and grok.sh.
# The scope manifest and its integrity check (check_scope_integrity, check_pin,
# uncommitted_patch) come unchanged from review-panel/scripts/pins.sh: both
# skills review the same prepared scope. This file adds only what Grok needs.
# Bumping SUPPORTED_GROK_VERSIONS is a reviewed change: re-verify the flags and
# events below against the new version and record the date. Grok updates itself
# when it runs interactively; grok.sh turns that off per run.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../review-panel/scripts/pins.sh"

# shellcheck disable=SC2034
SUPPORTED_GROK_VERSIONS="1.0.46"       # Grok Build CLI (`grok --version`); flags --prompt-file --cwd -m --reasoning-effort --tools --disallowed-tools --disable-web-search --no-subagents --no-plan --sandbox --max-turns --json-schema --output-format, the streaming-json events (text, tool_call, tool_call_update, available_commands, end with structuredOutput) and the isolated-HOME login verified on 1.0.46, 2026-10-05

# check_grok_pin <version>: exit 1 unless the version is in SUPPORTED_GROK_VERSIONS.
# REVIEW_GROK_ALLOW_UNPINNED=1 turns a mismatch into a loud warning for a one-off run; never set it in a script.
check_grok_pin() {
  local v
  for v in ${SUPPORTED_GROK_VERSIONS}; do [ "$1" = "${v}" ] && return 0; done
  if [ "${REVIEW_GROK_ALLOW_UNPINNED:-0}" = 1 ]; then
    echo "WARN: grok CLI $1 is not in the verified set (${SUPPORTED_GROK_VERSIONS}); continuing because REVIEW_GROK_ALLOW_UNPINNED=1; re-verify and bump skills/review-grok/scripts/lib.sh of the review-panel plugin" >&2
    return 0
  fi
  echo "FAIL: grok CLI $1 is not in the verified set (${SUPPORTED_GROK_VERSIONS}); re-verify the flags and events named in skills/review-grok/scripts/lib.sh of the review-panel plugin against that version and bump SUPPORTED_GROK_VERSIONS there, or set REVIEW_GROK_ALLOW_UNPINNED=1 for a one-off run" >&2
  return 1
}

# timeout_prefix <seconds>: sets TIMEOUT_PREFIX, a command prefix that kills the command it execs
# with SIGALRM after <seconds> (exit 142). perl alarm survives exec and ships with macOS; macOS
# has no `timeout` binary unless coreutils is installed.
# shellcheck disable=SC2034
TIMEOUT_EXIT=142
timeout_prefix() {
  # shellcheck disable=SC2016,SC2034
  TIMEOUT_PREFIX=(perl -e 'alarm shift @ARGV; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$1")
}

# reviewed_tree <repo>: the directory Grok runs in, on stdout. Call after check_scope_integrity.
# Branch and plan modes: a detached worktree at HEAD_SHA in a private temp dir, so Grok, which has
# no shell and cannot run `git show`, reads the committed tree and never an uncommitted edit that
# another stream left in this shared checkout. When the scope already has one (TREE in scope.env,
# added by prepare-scope.sh for a head that is not checked out), Grok reads that tree and no
# second worktree is added. Uncommitted mode: the repo itself.
reviewed_tree() {
  local repo="$1" tree tmp="${TMPDIR:-/tmp}"
  if [ "${MODE}" = uncommitted ]; then echo "${repo}"; return 0; fi
  if [ -n "${TREE:-}" ]; then echo "${TREE}"; return 0; fi
  tree="$(mktemp -d "${tmp%/}/review-grok-tree.XXXXXX")"
  git -C "${repo}" worktree add --quiet --detach "${tree}" "${HEAD_SHA}" >&2 \
    || { rm -rf "${tree}"; echo "FAIL: could not add a worktree at ${HEAD_SHA:0:12} in ${tree}; see the git error above" >&2; return 1; }
  echo "${tree}"
}

# remove_reviewed_tree <repo> <tree>: drops the worktree that reviewed_tree added; a no-op for the
# repo itself and for the scope's own TREE (prepare-scope.sh --cleanup removes that one). Only this
# worktree: a global `git worktree prune` would also touch the entries of other sessions, and it
# fails loud on an entry it may not delete.
remove_reviewed_tree() {
  local repo="$1" tree="$2"
  if [ -z "${tree}" ] || [ "${tree}" = "${repo}" ] || [ "${tree}" = "${TREE:-}" ]; then return 0; fi
  git -C "${repo}" worktree remove --force "${tree}" 2>/dev/null || {
    rm -rf "${tree}"
    echo "WARN: git worktree remove failed for ${tree}; removed the folder, its entry under .git/worktrees stays until a git worktree prune" >&2
  }
  return 0
}

# check_tree_untouched <repo> <scope-dir> <tree>: after Grok returns, prove it changed nothing.
# Worktree: no tracked or untracked change. Uncommitted mode: the working tree still has the
# digest that the manifest recorded.
check_tree_untouched() {
  local repo="$1" scope="$2" tree="$3" dirty now
  if [ "${tree}" = "${repo}" ]; then
    now="$(uncommitted_patch "${repo}" "${scope}" | shasum -a 256 | cut -d' ' -f1)"
    [ "${now}" = "${PATCH_SHA256}" ] || { echo "FAIL: the working tree changed while Grok ran (patch digest ${now:0:12} != manifest ${PATCH_SHA256:0:12}); Grok or another stream wrote to it, so the findings may not describe the prepared scope" >&2; return 1; }
    return 0
  fi
  dirty="$(git -C "${tree}" status --porcelain)"
  [ -z "${dirty}" ] || { echo "FAIL: Grok changed the reviewed tree ${tree}; read-only was not enforced:"$'\n'"${dirty}" >&2; return 1; }
}
