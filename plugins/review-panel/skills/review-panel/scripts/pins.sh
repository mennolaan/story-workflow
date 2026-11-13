#!/usr/bin/env bash
# Runtime pins of the review panel, sourced by run-adversarial.sh and
# run-heads.sh. Bumping either is a reviewed change: re-verify the facts the
# runners rely on and record the date here. Companion (run-adversarial.sh):
# argument parser in codex-companion.mjs; --base wins over --scope working-tree
# in scripts/lib/git.mjs resolveReviewTarget; it runs one read-only turn over
# `codex app-server` (lib/app-server.mjs), never `codex exec`; --json payload
# shape result/target. Codex CLI (run-heads.sh): `codex exec` flags --sandbox
# -C --color -m -c -o. Both verified 2026-08-19.
# REVIEW_PANEL_ALLOW_UNPINNED=1 turns a mismatch into a loud warning for a
# one-off run; never set it in a script.
# shellcheck disable=SC2034
SUPPORTED_COMPANION_VERSIONS="1.0.6"   # codex plugin companion; verified 2026-08-19
# shellcheck disable=SC2034
# Default mode (companion over `codex app-server`). 0.167.0 is in this list so
# one codex binary on PATH serves both modes; it was run live through the
# companion 1.0.6 path on 2026-11-09 (scoped review of story-workflow 0.4.1).
SUPPORTED_CODEX_VERSIONS="0.153.4 0.167.0"     # codex CLI (`codex --version`); exec flags -s/--sandbox, -C, --color, -m, -c, -o re-verified against `codex exec --help` on 0.153.4, 2026-09-10
# Separate exec-only pin: the companion's app-server compatibility above is
# not implied. Local `codex exec --help` checked on 0.167.0, 2026-11-08:
# --sandbox read-only, -C, --color never, -m, -c, -o and stdin '-'. Runner
# integration uses fake Codex fixtures; no paid GPT-6.1 Sol call was made.
# shellcheck disable=SC2034
SUPPORTED_HEAD_CODEX_VERSIONS="0.167.0"

# check_pin <label> <actual> <supported-list>: exit 1 on a mismatch unless REVIEW_PANEL_ALLOW_UNPINNED=1
check_pin() {
  local label="$1" actual="$2" supported="$3" v
  for v in ${supported}; do [ "${actual}" = "${v}" ] && return 0; done
  if [ "${REVIEW_PANEL_ALLOW_UNPINNED:-0}" = 1 ]; then
    echo "WARN: ${label} ${actual} is not in the verified set (${supported}); continuing because REVIEW_PANEL_ALLOW_UNPINNED=1; re-verify and bump scripts/pins.sh" >&2
    return 0
  fi
  echo "FAIL: ${label} ${actual} is not in the verified set (${supported}); re-verify the runner's assumptions against that version and bump skills/review-panel/scripts/pins.sh of the review-panel plugin, or set REVIEW_PANEL_ALLOW_UNPINNED=1 for a one-off run" >&2
  return 1
}

# uncommitted_patch <repo> <scope-dir>: the working tree against HEAD, untracked files included,
# the scope dir itself excluded (it may sit untracked inside the repo), on stdout. prepare-scope.sh
# writes it as diff.patch; check_scope_integrity recomputes it so the engine never reviews a tree
# the manifest digest has not seen.
uncommitted_pathspec() {   # uncommitted_pathspec <repo> <scope-dir>: sets UNC_SPEC (git pathspec array)
  local rel
  rel="$(python3 -c 'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' "$2" "$1")"   # realpath: git resolves /var -> /private/var, pwd does not
  case "${rel}" in ..*) UNC_SPEC=(-- .) ;; *) UNC_SPEC=(-- . ":(exclude)${rel}") ;; esac
}
uncommitted_patch() {
  local repo="$1" f
  uncommitted_pathspec "$1" "$2"
  ( cd "${repo}" && git diff HEAD "${UNC_SPEC[@]}"
    cd "${repo}" && git ls-files --others --exclude-standard "${UNC_SPEC[@]}" | while IFS= read -r f; do git diff --no-index -- /dev/null "${f}" || true; done )
}

# bounded <seconds> <out-file> <err-file> <command...>: runs the command in its own process group with
# stdin closed and stdout and stderr in the two files, and kills the whole group after <seconds>.
# Exit: the command's exit code, 124 on a timeout, 127 when it cannot start. A plain `$(az ...)`
# cannot be bounded with `|| true`: a hung az (or a child it left behind) keeps the pipe open.
bounded() {
  python3 - "$@" <<'BOUNDED'
import os, signal, subprocess, sys
secs, out, err, argv = float(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
with open(out, "wb") as o, open(err, "wb") as e:
    try:
        p = subprocess.Popen(argv, stdout=o, stderr=e, stdin=subprocess.DEVNULL, start_new_session=True)
    except OSError as exc:
        e.write(f"{exc}\n".encode()); sys.exit(127)
    try:
        sys.exit(p.wait(timeout=secs))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait(); sys.exit(124)
BOUNDED
}

# check_scope_integrity <scope-dir> <repo>: manifest present and complete, diff.patch digest matches,
# the reviewed checkout at the scope head (TREE when the scope has one, else the repo), scoped files
# clean in that checkout in branch mode, working tree unchanged since preparation in uncommitted mode.
# Sets MODE BASE_SHA HEAD_SHA PLAN PR PR_STATUS PR_DRAFT PR_TARGET TREE HARNESS_CHANGED, and
# REVIEWED (the checkout the finders read: TREE, else the repo).
check_scope_integrity() {
  local scope="$1" repo="$2" f want have dirty now
  for f in scope.env scope.md diff.patch files.txt facts.md; do
    [ -f "${scope}/${f}" ] || { echo "FAIL: ${scope}/${f} missing; run prepare-scope.sh again (a scope without its manifest is not reviewable)" >&2; return 1; }
  done
  MODE="" REPO="" BASE_SHA="" HEAD_SHA="" PATCH_SHA256="" PLAN="" PR="" PR_STATUS="" PR_DRAFT="" PR_TARGET="" TREE="" HARNESS_CHANGED=""
  # shellcheck disable=SC1091
  . "${scope}/scope.env"
  [ -n "${MODE}" ] && [ -n "${HEAD_SHA}" ] && [ -n "${BASE_SHA}" ] && [ -n "${PATCH_SHA256}" ] \
    || { echo "FAIL: scope.env incomplete (MODE/BASE_SHA/HEAD_SHA/PATCH_SHA256)" >&2; return 1; }
  [ "${REPO}" = "${repo}" ] || { echo "FAIL: scope was prepared in ${REPO}, this checkout is ${repo}" >&2; return 1; }
  want="${PATCH_SHA256}"; have="$(shasum -a 256 "${scope}/diff.patch" | cut -d' ' -f1)"
  [ "${want}" = "${have}" ] || { echo "FAIL: diff.patch digest ${have:0:12} != manifest ${want:0:12}; the scope was altered after preparation" >&2; return 1; }
  REVIEWED="${repo}"
  if [ -n "${TREE}" ]; then
    # The head is not checked out in the repo: prepare-scope.sh added a detached worktree at
    # HEAD_SHA, and the finders read that tree. The repo checkout may sit on any branch.
    [ -d "${TREE}" ] || { echo "FAIL: the reviewed tree ${TREE} of this scope is gone; re-run prepare-scope.sh" >&2; return 1; }
    REVIEWED="${TREE}"
  fi
  [ "$(git -C "${REVIEWED}" rev-parse HEAD)" = "${HEAD_SHA}" ] \
    || { echo "FAIL: checkout drifted: HEAD $(git -C "${REVIEWED}" rev-parse --short HEAD) of ${REVIEWED} != scope head ${HEAD_SHA:0:12}; re-run prepare-scope.sh or check out the scope head" >&2; return 1; }
  if [ "${MODE}" = branch ]; then
    local scoped=()
    while IFS= read -r f; do [ -n "${f}" ] && scoped+=("${f}"); done < "${scope}/files.txt"
    dirty="$(cd "${REVIEWED}" && git status --porcelain --untracked-files=no -- "${scoped[@]}" 2>/dev/null)"
    [ -z "${dirty}" ] || { echo "FAIL: scoped files are modified in the worktree ${REVIEWED} (branch mode reviews the committed tree):"$'\n'"${dirty}" >&2; return 1; }
  fi
  if [ "${MODE}" = uncommitted ]; then
    now="$(uncommitted_patch "${repo}" "${scope}" | shasum -a 256 | cut -d' ' -f1)"
    [ "${now}" = "${want}" ] || { echo "FAIL: the working tree changed since the scope was prepared (patch digest ${now:0:12} != manifest ${want:0:12}); the engine would review bytes the judge's diff.patch never saw. Re-run prepare-scope.sh --uncommitted" >&2; return 1; }
  fi
  [ "${HARNESS_CHANGED}" = 1 ] \
    && echo "WARN: the candidate changes the review harness; the prompts and runners come from this checkout, read those hunks first" >&2
  return 0
}

# write_finder_env <scope-dir> <finder> <version> <depth> <turns>: records the finder run in
# <scope>/finder.env (shell-quoted KEY=value lines). check-docket.sh --scope copies it into
# verdict.json, so the record of a PR review names what found, at which depth, in how many turns.
write_finder_env() {
  { printf 'FINDER=%q\n' "$2"; printf 'FINDER_VERSION=%q\n' "$3"; printf 'DEPTH=%q\n' "$4"; printf 'TURNS=%q\n' "$5"; } > "$1/finder.env"
}
