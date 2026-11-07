#!/usr/bin/env bash
# Evidence and scoped Codex review for a bound story session. Python uses only
# the standard library. See skills/story/review.md for the protocol and CLI.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"
command -v python3 >/dev/null 2>&1 || { echo 'story-review: Python 3 is required for acceptance evidence and handoff review.' >&2; exit 1; }
exec python3 "${here}/story-review.py" --plans "$(story_plans_dir)" --config "$(story_config_file)" "$@"
