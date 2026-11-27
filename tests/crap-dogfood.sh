#!/usr/bin/env bash
# CRAP on this repo itself: run the Python suites under the standard-library
# line tracer (tests/linecov/sitecustomize.py, Python 3.12+), then score every
# function with hooks/crap.py --all. A demonstration on real code and real
# coverage, not a pass/fail gate. Usage: tests/crap-dogfood.sh [--format json]
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mktemp -d "${TMPDIR:-/tmp}/crap-dogfood.XXXXXX")"
for suite in tests/story-review.test.py plugins/review-panel/tests/configure-prs.test.py tests/eval-suite.test.py; do
  (cd "${repo}" && PYTHONPATH="${repo}/tests/linecov" LINECOV_ROOT="${repo}" LINECOV_DIR="${out}" \
    python3 "${suite}" >/dev/null 2>&1) || echo "note: ${suite} did not pass; its coverage still counts" >&2
done
args=()
for f in "${out}"/*.lcov; do [ -f "${f}" ] && args+=(--coverage "${f}"); done
[ "${#args[@]}" -gt 0 ] || { echo "crap-dogfood: no coverage was written (Python 3.12+ needed)" >&2; exit 1; }
cd "${repo}"
python3 hooks/crap.py --base HEAD --all "${args[@]}" --format "${2:-markdown}"
rm -rf "${out}"
