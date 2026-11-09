#!/usr/bin/env bash
# Held-out check for the review-panel plugin: the profile loader, the prompt
# renderer, prepare-scope.sh, the scope integrity guards, run-heads.sh,
# run-adversarial.sh, check-docket.sh, and the Grok adapter and runner.
# Every case is falsifying: it fails when the branch it names is removed.
# Fixtures are git repos in a temp folder. Fake codex, gh, az and grok binaries
# and a fake companion stand in for the real tools, so no model runs and no
# network call is made. Runs shellcheck on every script when it is installed.
# Usage: tests/review-panel-matrix.sh   (from the plugin root; exit 0 = all cases pass)
# shellcheck disable=SC2015,SC2016 # pass and fail return 0; backticks in single quotes are literal Markdown.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${root}/skills/review-panel/scripts"
G="${root}/skills/review-grok/scripts"
tmp="$(mktemp -d)"
tmp="$(cd "${tmp}" && pwd -P)"
trap 'rm -rf "${tmp}"' EXIT
fake="${tmp}/bin"
mkdir -p "${fake}"
rc=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n%s\n' "$1" "${2:-}" >&2; rc=1; }
has() { grep -qF -- "$2" "$1"; }

# Fake tools. FAKE_* variables steer them per case.
cat >"${fake}/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo "codex-cli ${FAKE_CODEX_VERSION:-0.153.4}"; exit 0; fi
out="" model=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model) model="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "${FAKE_REQUIRE_SOL_MODEL:-0}" != 1 ] || [ "${model}" = gpt-6.1-sol ] || exit 42
cat >/dev/null; [ -n "${out}" ] && echo none >"${out}"; exit 0
EOF
cat >"${fake}/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "pr list" ] && { echo '- #7 `feature/x`: sibling work'; exit 0; }
exit 1
EOF
cat >"${fake}/az" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"${fake}/grok" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo "grok ${FAKE_GROK_VERSION:-1.0.46}"; exit 0; fi
cat "${FAKE_GROK_STREAM}"
EOF
chmod +x "${fake}"/*
companion_dir="${tmp}/companion/1.0.6/scripts"
mkdir -p "${companion_dir}"
cat >"${companion_dir}/codex-companion.mjs" <<'EOF'
import { writeFileSync } from "node:fs";
const a = process.argv.slice(2);
const at = (k) => { const i = a.indexOf(k); return i >= 0 ? a[i + 1] : undefined; };
writeFileSync(process.env.FAKE_FOCUS_OUT, a[a.length - 1]);
const base = process.env.FAKE_BASE_REF !== undefined ? process.env.FAKE_BASE_REF : at("--base");
const target = { mode: at("--scope") };
if (base) target.baseRef = base;
console.log(JSON.stringify({ target, result: { verdict: "approve", findings: [], summary: "ok" }, codex: { status: "completed" } }));
EOF
export PATH="${fake}:${PATH}" REVIEW_PANEL_COMPANION="${companion_dir}/codex-companion.mjs" FAKE_FOCUS_OUT="${tmp}/focus.txt"
export GROK_HOME="${tmp}/grokhome"
mkdir -p "${GROK_HOME}" && echo '{}' >"${GROK_HOME}/auth.json"
unset REVIEW_PANEL_PROFILE REVIEW_PANEL_ALLOW_UNPINNED REVIEW_GROK_ALLOW_UNPINNED REVIEW_GROK_SANDBOX

# mkrepo <dir> [ignore]: main with src/a.txt, a feature branch that changes it, origin/main at main.
mkrepo() {
  local d="$1"
  mkdir -p "${d}/src" && git -C "${d}" init -q -b main
  git -C "${d}" config user.email t@example.com && git -C "${d}" config user.name t
  printf 'one\n' >"${d}/src/a.txt"
  [ "${2:-}" = ignore ] && printf '.claude/.review/\n' >"${d}/.gitignore"
  git -C "${d}" add -A && git -C "${d}" commit -qm base
  git -C "${d}" update-ref refs/remotes/origin/main HEAD
  git -C "${d}" switch -qc feature
  printf 'one\ntwo\n' >"${d}/src/a.txt"
  git -C "${d}" commit -qam change
}
# prep <repo> <args...>: runs prepare-scope.sh in the repo; sets scope (the dir), out and code.
prep() {
  local d="$1"; shift
  out="$(cd "${d}" && "${S}/prepare-scope.sh" "$@" 2>"${tmp}/stderr")"; code=$?
  scope="$(printf '%s' "${out}" | head -1)"
}
# show <repo>: runs profile.sh show; sets out and code.
show() { out="$(cd "$1" && "${S}/profile.sh" show 2>"${tmp}/stderr")"; code=$?; }

# 1. Profile loader.
r="${tmp}/r1"; mkrepo "${r}" ignore
show "${r}"
[ "${code}" = 0 ] && grep -q '^profile: none' <<<"${out}" && grep -q '^name: r1$' <<<"${out}" && grep -q '^base ref: origin/main$' <<<"${out}" && grep -q '^pr host: none$' <<<"${out}" \
  && pass "profile: no folder gives the defaults (name, base origin/main, pr host none)" || fail "profile defaults" "${out}"
git -C "${r}" remote add origin https://github.com/acme/r1.git
show "${r}"
grep -q '^pr host: github$' <<<"${out}" && pass "profile: prHost auto reads a github.com remote" || fail "profile prHost auto" "${out}"
mkdir -p "${r}/.claude/review-profile"
printf '{"name":"acme","baseRef":"origin/dev","prHost":"none","deepHeads":["delivery"],"harnessPaths":["ops/"]}\n' >"${r}/.claude/review-profile/profile.json"
show "${r}"
grep -q '^name: acme$' <<<"${out}" && grep -q '^base ref: origin/dev$' <<<"${out}" && grep -q '^deep heads: delivery$' <<<"${out}" && grep -q 'ops/' <<<"${out}" \
  && pass "profile: profile.json sets name, baseRef, deepHeads and harnessPaths" || fail "profile.json values" "${out}"
printf '{"nmae":"x"}\n' >"${r}/.claude/review-profile/profile.json"
show "${r}"
[ "${code}" != 0 ] && has "${tmp}/stderr" "unknown key 'nmae'" && pass "profile: an unknown key fails loud" || fail "profile unknown key" "$(cat "${tmp}/stderr")"
printf '{"prHost":"gitlab"}\n' >"${r}/.claude/review-profile/profile.json"
show "${r}"
[ "${code}" != 0 ] && has "${tmp}/stderr" "prHost 'gitlab'" && pass "profile: a bad prHost fails loud" || fail "profile bad prHost" "$(cat "${tmp}/stderr")"
printf '{"name":' >"${r}/.claude/review-profile/profile.json"
show "${r}"
[ "${code}" != 0 ] && has "${tmp}/stderr" "not valid JSON" && pass "profile: broken JSON fails loud" || fail "profile broken JSON" "$(cat "${tmp}/stderr")"
printf '{"deepHeads":"delivery"}\n' >"${r}/.claude/review-profile/profile.json"
show "${r}"
[ "${code}" != 0 ] && has "${tmp}/stderr" "list of strings" && pass "profile: a wrong type fails loud" || fail "profile wrong type" "$(cat "${tmp}/stderr")"
rm -rf "${r}/.claude/review-profile"

# 2. prepare-scope.sh.
prep "${r}" origin/main HEAD
[ "${code}" = 0 ] && [ -f "${scope}/scope.env" ] && has "${scope}/files.txt" src/a.txt && ! grep -q HARNESS_CHANGED "${scope}/scope.env" \
  && pass "prepare-scope: a branch scope with no harness file exits 0 (harness_hits returns 0)" || fail "prepare-scope branch" "$(cat "${tmp}/stderr")"
has "${scope}/scope.md" '#7 `feature/x`' && pass "prepare-scope: GitHub sibling pull requests come from gh" || fail "prepare-scope gh siblings" "$(sed -n '/sibling/,+4p' "${scope}/scope.md")"
! has "${tmp}/stderr" "not gitignored" && pass "prepare-scope: no gitignore warning when .claude/.review/ is ignored" || fail "prepare-scope ignore quiet" "$(cat "${tmp}/stderr")"
r2="${tmp}/r2"; mkrepo "${r2}"
prep "${r2}" origin/main HEAD
has "${tmp}/stderr" "not gitignored" && pass "prepare-scope: warns when .claude/.review/ is not ignored" || fail "prepare-scope ignore warn" "$(cat "${tmp}/stderr")"
has "${scope}/scope.md" "Not looked up" && pass "prepare-scope: prHost none skips the sibling lookup and says so" || fail "prepare-scope prHost none" ""
printf 'rule\n' >"${r}/CLAUDE.md" && git -C "${r}" add CLAUDE.md && git -C "${r}" commit -qm rules
prep "${r}" origin/main HEAD
grep -q '^HARNESS_CHANGED=1$' "${scope}/scope.env" && has "${tmp}/stderr" "CLAUDE.md" && pass "prepare-scope: CLAUDE.md in scope sets HARNESS_CHANGED" || fail "prepare-scope harness CLAUDE.md" "$(cat "${tmp}/stderr")"
mkdir -p "${r}/.claude/review-profile" && printf '{"harnessPaths":["ops/"]}\n' >"${r}/.claude/review-profile/profile.json"
mkdir -p "${r}/ops" && printf 'x\n' >"${r}/ops/deploy.sh" && git -C "${r}" add -A && git -C "${r}" commit -qm ops
prep "${r}" HEAD~1 HEAD
grep -q '^HARNESS_CHANGED=1$' "${scope}/scope.env" && has "${tmp}/stderr" "ops/deploy.sh" && pass "prepare-scope: a harnessPaths folder in scope sets HARNESS_CHANGED" || fail "prepare-scope harnessPaths" "$(cat "${tmp}/stderr")"
git -C "${r}" rm -rq .claude/review-profile ops && git -C "${r}" commit -qm clean
printf 'three\n' >>"${r}/src/a.txt"
prep "${r}" --uncommitted
[ "${code}" = 0 ] && grep -q '^MODE=uncommitted$' "${scope}/scope.env" && has "${scope}/files.txt" src/a.txt && pass "prepare-scope: an uncommitted scope" || fail "prepare-scope uncommitted" "$(cat "${tmp}/stderr")"
git -C "${r}" checkout -q -- src/a.txt
printf '# Plan\n' >"${tmp}/plan.md"
prep "${r}" --plan "${tmp}/plan.md"
[ "${code}" = 0 ] && grep -q '^MODE=plan$' "${scope}/scope.env" && pass "prepare-scope: a plan scope" || fail "prepare-scope plan" "$(cat "${tmp}/stderr")"

# 3. Scope integrity (check_scope_integrity through run-heads.sh --dry-run).
heads() { out="$(cd "$1" && FAKE_CODEX_VERSION="${FAKE_CODEX_VERSION:-0.167.0}" "${S}/run-heads.sh" "$2" "${@:3}" 2>"${tmp}/stderr")"; code=$?; }
prep "${r}" origin/main HEAD
heads "${r}" "${scope}" --dry-run
[ "${code}" = 0 ] && pass "integrity: a fresh branch scope passes" || fail "integrity fresh" "$(cat "${tmp}/stderr")"
cp "${scope}/diff.patch" "${tmp}/diff.bak" && printf 'x\n' >>"${scope}/diff.patch"
heads "${r}" "${scope}" --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" "digest" && pass "integrity: a tampered diff.patch is refused" || fail "integrity tampered" "$(cat "${tmp}/stderr")"
cp "${tmp}/diff.bak" "${scope}/diff.patch"
printf 'dirty\n' >>"${r}/src/a.txt"
heads "${r}" "${scope}" --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" "scoped files are modified" && pass "integrity: dirty scoped files are refused in branch mode" || fail "integrity dirty" "$(cat "${tmp}/stderr")"
git -C "${r}" checkout -q -- src/a.txt
git -C "${r}" commit -q --allow-empty -m drift
heads "${r}" "${scope}" --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" "checkout drifted" && pass "integrity: a drifted checkout is refused" || fail "integrity drift" "$(cat "${tmp}/stderr")"
mv "${scope}/scope.env" "${tmp}/scope.env.bak"
heads "${r}" "${scope}" --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" "scope.env missing" && pass "integrity: a missing manifest is refused" || fail "integrity manifest" "$(cat "${tmp}/stderr")"
printf 'four\n' >>"${r}/src/a.txt"
prep "${r}" --uncommitted
printf 'five\n' >>"${r}/src/a.txt"
heads "${r}" "${scope}" --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" "working tree changed" && pass "integrity: an uncommitted scope refuses a changed working tree" || fail "integrity uncommitted" "$(cat "${tmp}/stderr")"
git -C "${r}" checkout -q -- src/a.txt

# 4. Rendering and heads.
mkdir -p "${r}/.claude/review-profile/heads"
printf '{"name":"acme","deepHeads":["delivery","custom"]}\n' >"${r}/.claude/review-profile/profile.json"
printf 'Invariant ALPHA-7: totals are computed once.\n' >"${r}/.claude/review-profile/context.md"
printf 'Durable means written to BUCKET-9.\n' >"${r}/.claude/review-profile/heads/delivery.md"
printf 'HEAD: custom. Look for GAMMA-3.\n' >"${r}/.claude/review-profile/heads/custom.md"
prep "${r}" origin/main HEAD
heads "${r}" "${scope}" --dry-run
p="${scope}/heads/delivery.prompt.md"
[ "${code}" = 0 ] && has "${p}" "acme review panel" && has "${p}" "ALPHA-7" && has "${p}" "BUCKET-9" && has "${p}" "Project detail for this head" && has "${p}" "${scope}" \
  && pass "render: a head carries the profile name, context and head addendum" || fail "render delivery" "$(cat "${tmp}/stderr")"
grep -q '__[A-Z_]*__' "${p}" && fail "render: placeholders left in delivery" "$(grep -o '__[A-Z_]*__' "${p}")" || pass "render: no placeholder is left"
[ -f "${scope}/heads/custom.prompt.md" ] && has "${scope}/heads/custom.prompt.md" "GAMMA-3" && pass "render: deepHeads selects a head that only the profile has" || fail "render custom head" "$(cat "${tmp}/stderr")"
[ ! -f "${scope}/heads/identity.prompt.md" ] && pass "render: deepHeads replaces the default head set" || fail "render deepHeads default" ""
heads "${r}" "${scope}" --heads nosuch --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" "unknown head 'nosuch'" && pass "render: an unknown head fails loud" || fail "render unknown head" "$(cat "${tmp}/stderr")"
printf 'Use __NOPE__ here.\n' >"${r}/.claude/review-profile/heads/custom.md"
heads "${r}" "${scope}" --heads custom --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" "__NOPE__" && pass "render: an unreplaced placeholder fails loud" || fail "render placeholder" "$(cat "${tmp}/stderr")"
prep "${r}" --plan "${tmp}/plan.md"; plan_scope="${scope}"
heads "${r}" "${plan_scope}" --dry-run
[ "${code}" = 0 ] && [ -f "${plan_scope}/heads/conform.prompt.md" ] && [ ! -f "${plan_scope}/heads/identity.prompt.md" ] \
  && pass "render: a plan scope runs planHeads" || fail "render plan heads" "$(cat "${tmp}/stderr")"
[ "${code}" = 0 ] && grep -qF -- '-m gpt-6.1-sol' <<<"${out}" \
  && pass "heads: plan review pins GPT-6.1 Sol" || fail "plan model pin" "${out}"
rm -rf "${r}/.claude/review-profile"
prep "${r}" origin/main HEAD
FAKE_REQUIRE_SOL_MODEL=1 heads "${r}" "${scope}" --heads delivery
[ "${code}" = 0 ] && grep -q $'^delivery\t0\t5\t' "${scope}/heads/status.tsv" && has "${scope}/heads/delivery.prompt.md" "CLAUDE.md and AGENTS.md" \
  && pass "heads: a run with fake codex writes status.tsv; no profile gives the default context" || fail "heads run" "$(cat "${tmp}/stderr")"
heads "${r}" "${scope}" --heads delivery --model gpt-6.1-sol --dry-run
[ "${code}" = 0 ] && grep -qF -- '-m gpt-6.1-sol' <<<"${out}" \
  && pass "heads: explicit GPT-6.1 Sol is accepted" || fail "explicit model pin" "${out}$(cat "${tmp}/stderr")"
for wrong_model in gpt-6-sol gpt-6-astra gpt-6.1-terra ''; do
  heads "${r}" "${scope}" --heads delivery --model "${wrong_model}" --dry-run
  [ "${code}" != 0 ] && has "${tmp}/stderr" 'requires --model gpt-6.1-sol' \
    && pass "heads: a conflicting or empty model '${wrong_model}' is refused" || fail "conflicting model" "${out}$(cat "${tmp}/stderr")"
done
heads "${r}" "${scope}" --heads delivery --model gpt-6-sol --model gpt-6.1-sol --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" 'requires --model gpt-6.1-sol' \
  && pass "heads: a later model flag cannot hide a forbidden override" || fail "duplicate model" "${out}$(cat "${tmp}/stderr")"
heads "${r}" "${scope}" --heads delivery --model
[ "${code}" != 0 ] && has "${tmp}/stderr" 'requires --model gpt-6.1-sol' \
  && pass "heads: a missing model value fails before running Codex" || fail "missing model" "$(cat "${tmp}/stderr")"
heads "${r}" "${scope}" --heads delivery --effort maxx --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" "not a reasoning effort" && pass "heads: an unknown effort is refused" || fail "heads effort" "$(cat "${tmp}/stderr")"
FAKE_CODEX_VERSION=0.153.4 heads "${r}" "${scope}" --heads delivery --dry-run
[ "${code}" != 0 ] && has "${tmp}/stderr" 'verified set (0.167.0)' \
  && pass "heads: the legacy companion pin cannot bypass the exec-only pin" || fail "exec-only version pin" "$(cat "${tmp}/stderr")"

# 5. run-adversarial.sh.
adv() { out="$(cd "$1" && "${S}/run-adversarial.sh" "$2" 2>"${tmp}/stderr")"; code=$?; }
mkdir -p "${r}/.claude/review-profile" && printf 'Invariant ALPHA-7.\n' >"${r}/.claude/review-profile/context.md"
prep "${r}" origin/main HEAD
adv "${r}" "${scope}"
[ "${code}" = 0 ] && grep -q 'verdict: approve; findings: 0' <<<"${out}" && has "${FAKE_FOCUS_OUT}" "ALPHA-7" \
  && pass "adversarial: a matching target passes and the focus carries the profile context" || fail "adversarial ok" "$(cat "${tmp}/stderr")"
FAKE_BASE_REF=0000000 adv "${r}" "${scope}"
[ "${code}" != 0 ] && has "${tmp}/stderr" "findings do not describe the prepared scope" && pass "adversarial: a mismatching engine target is refused" || fail "adversarial mismatch" "$(cat "${tmp}/stderr")"
FAKE_CODEX_VERSION=0.167.0 adv "${r}" "${scope}"
[ "${code}" = 0 ] && pass "adversarial: the deep/plan codex version also runs default mode" || fail "adversarial shared pin" "$(cat "${tmp}/stderr")"
FAKE_CODEX_VERSION=9.9.9 adv "${r}" "${scope}"
[ "${code}" != 0 ] && has "${tmp}/stderr" "codex CLI 9.9.9 is not in the verified set" && pass "adversarial: an unpinned codex is refused" || fail "adversarial pin" "$(cat "${tmp}/stderr")"
mkdir -p "${tmp}/companion/0.0.1/scripts" && cp "${REVIEW_PANEL_COMPANION}" "${tmp}/companion/0.0.1/scripts/"
REVIEW_PANEL_COMPANION="${tmp}/companion/0.0.1/scripts/codex-companion.mjs" adv "${r}" "${scope}"
[ "${code}" != 0 ] && has "${tmp}/stderr" "companion 0.0.1 is not in the verified set" && pass "adversarial: an unpinned companion is refused" || fail "adversarial companion pin" "$(cat "${tmp}/stderr")"
prep "${r}" --plan "${tmp}/plan.md"; plan_scope="${scope}"
adv "${r}" "${plan_scope}"
[ "${code}" != 0 ] && has "${tmp}/stderr" "plan mode is not a git target" && pass "adversarial: a plan scope is refused" || fail "adversarial plan" "$(cat "${tmp}/stderr")"

# 6. check-docket.sh.
head_sha="$(git -C "${r}" rev-parse HEAD)"
docket() { printf '%s\n' "$@" >"${tmp}/docket.md"; out="$(cd "${r}" && "${S}/check-docket.sh" "${tmp}/docket.md" "${head_sha}" 2>"${tmp}/stderr")"; code=$?; }
docket 'Replace `src/a.txt:2-2`:' '```suggestion' 'TWO' '```'
[ "${code}" = 0 ] && grep -q '1 suggestion block(s), 0 defect(s)' <<<"${out}" && pass "docket: an exact anchor passes" || fail "docket ok" "${out}$(cat "${tmp}/stderr")"
docket 'Replace `src/a.txt:5-6`:' '```suggestion' 'X' '```'
[ "${code}" != 0 ] && has "${tmp}/stderr" "outside the file" && pass "docket: an out-of-range anchor fails" || fail "docket range" "$(cat "${tmp}/stderr")"
docket 'No anchor here.' '```suggestion' 'X' '```'
[ "${code}" != 0 ] && has "${tmp}/stderr" "exactly one" && pass "docket: a block without an anchor fails" || fail "docket anchor" "$(cat "${tmp}/stderr")"
docket 'Replace `src/a.txt:2-2`:' '```suggestion' '   TWO' '```'
[ "${code}" != 0 ] && has "${tmp}/stderr" "markdown list" && pass "docket: a list-indented block fails" || fail "docket indent" "$(cat "${tmp}/stderr")"

# 7. Grok adapter and runner.
stream() { printf '%s\n' "$@" >"${tmp}/stream.ndjson"; export FAKE_GROK_STREAM="${tmp}/stream.ndjson"; }
grokrun() { out="$("${G}/grok.sh" run "${tmp}/prompt.md" "${tmp}/grok.out" "${tmp}/grok.log" "${r}" "$@" 2>"${tmp}/stderr")"; code=$?; }
printf 'p\n' >"${tmp}/prompt.md"
"${G}/grok.sh" preflight --static 2>"${tmp}/stderr" && pass "grok: preflight --static passes a pinned, logged-in CLI" || fail "grok preflight" "$(cat "${tmp}/stderr")"
FAKE_GROK_VERSION=0.0.1 "${G}/grok.sh" preflight --static 2>"${tmp}/stderr"; code=$?
[ "${code}" != 0 ] && has "${tmp}/stderr" "grok CLI 0.0.1 is not in the verified set" && pass "grok: an unpinned CLI is refused" || fail "grok pin" "$(cat "${tmp}/stderr")"
stream '{"type":"available_commands","tools":["read_file","grep","run_terminal_cmd"]}' '{"type":"end","stopReason":"end_turn"}'
"${G}/grok.sh" preflight 2>"${tmp}/stderr"; code=$?
[ "${code}" != 0 ] && has "${tmp}/stderr" "expected exactly" && pass "grok: a probe that offers a shell tool is refused" || fail "grok probe tools" "$(cat "${tmp}/stderr")"
stream '{"type":"available_commands","tools":["read_file","grep","list_dir"]}' '{"type":"text","data":"none"}' '{"type":"end","stopReason":"end_turn"}'
grokrun
[ "${code}" = 0 ] && [ "$(cat "${tmp}/grok.out")" = none ] && pass "grok: a clean stream writes the final message" || fail "grok run ok" "$(cat "${tmp}/grok.log")"
stream '{"type":"tool_call","toolName":"write_file"}' '{"type":"text","data":"none"}' '{"type":"end","stopReason":"end_turn"}'
grokrun
[ "${code}" != 0 ] && has "${tmp}/grok.log" "outside the allowlist" && pass "grok: a call outside the allowlist discards the output" || fail "grok allowlist" "$(cat "${tmp}/grok.log")"
stream '{"type":"tool_call","toolName":"read_file"}' '{"type":"end","stopReason":"end_turn"}'
grokrun
[ "${code}" != 0 ] && has "${tmp}/grok.log" "final message empty" && pass "grok: a stream without final text fails" || fail "grok empty" "$(cat "${tmp}/grok.log")"
stream '{"type":"text","data":"x"}' '{"type":"end","stopReason":"end_turn"}'
grokrun --schema "${root}/skills/review-grok/schemas/findings.schema.json"
[ "${code}" != 0 ] && has "${tmp}/grok.log" "no structuredOutput" && pass "grok: a schema run without structuredOutput fails" || fail "grok schema" "$(cat "${tmp}/grok.log")"
schema="${root}/skills/review-grok/schemas/findings.schema.json"
ok_item='{"title":"t","file":"f","line":1,"stance":"delivery","claim":"c","trigger":"t","observed":"o","evidence":"e"}'
vf() { printf '%s' "$1" >"${tmp}/f.json"; python3 "${G}/validate-findings.py" "${schema}" "${tmp}/f.json" >/dev/null 2>"${tmp}/stderr"; code=$?; }
vf "{\"findings\":[${ok_item}]}"; [ "${code}" = 0 ] && pass "grok schema: a valid result passes" || fail "schema valid" "$(cat "${tmp}/stderr")"
vf '{"findings":[{"title":"t"}]}'; [ "${code}" != 0 ] && has "${tmp}/stderr" "missing required key" && pass "grok schema: a missing key fails" || fail "schema missing" ""
vf "{\"findings\":[${ok_item%\}},\"x\":1}]}"; [ "${code}" != 0 ] && has "${tmp}/stderr" "unexpected key" && pass "grok schema: an extra key fails" || fail "schema extra" "$(cat "${tmp}/stderr")"
vf "{\"findings\":[${ok_item/\"line\":1/\"line\":\"1\"}]}"; [ "${code}" != 0 ] && has "${tmp}/stderr" "expected integer" && pass "grok schema: a wrong type fails" || fail "schema type" ""
vf "{\"findings\":[${ok_item/delivery/style}]}"; [ "${code}" != 0 ] && has "${tmp}/stderr" "is not one of" && pass "grok schema: an unknown stance fails" || fail "schema stance" ""
vf '{"findings":['; [ "${code}" != 0 ] && has "${tmp}/stderr" "not readable JSON" && pass "grok schema: broken JSON fails" || fail "schema json" ""
prep "${r}" origin/main HEAD
out="$(cd "${r}" && "${G}/run-grok.sh" "${scope}" --dry-run 2>"${tmp}/stderr")"; code=$?
p="${scope}/grok.prompt.md"
[ "${code}" = 0 ] && has "${p}" "ALPHA-7" && has "${p}" "adversarial finder of the r1 review panel" && has "${p}" "shared checkout ${r}" && has "${p}" "commits on origin/main" \
  && pass "grok runner: the default prompt carries the no-shell note, the base ref and the profile context" || fail "grok runner default" "$(cat "${tmp}/stderr")"
out="$(cd "${r}" && "${G}/run-grok.sh" "${scope}" --deep --heads delivery --dry-run 2>"${tmp}/stderr")"; code=$?
p="${scope}/heads/delivery.grok.prompt.md"
[ "${code}" = 0 ] && has "${p}" "Tool note" && has "${p}" "Repo root: <reviewed tree>" && has "${p}" "ALPHA-7" && ! grep -q '__[A-Z_]*__' "${p}" \
  && pass "grok runner: a deep head prompt puts the reviewed tree in the preamble" || fail "grok runner deep" "$(cat "${tmp}/stderr")"

# 8. Lint.
if command -v shellcheck >/dev/null 2>&1; then
  if lint="$(shellcheck -x "${S}"/*.sh "${G}"/*.sh "${BASH_SOURCE[0]}" 2>&1)"; then pass "shellcheck: every script"; else fail "shellcheck" "${lint}"; fi
else
  echo "skip shellcheck (not installed)"
fi

[ "${rc}" = 0 ] && echo "all cases pass" || echo "some cases failed" >&2
exit "${rc}"
