#!/usr/bin/env bash
# Copy the plugin's real /story skill and routing hooks into the empty eval
# workspace, with a repo config, so the run uses the shipped rules and script.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p story-workflow/skills/story story-workflow/hooks .claude
cp "${root}/skills/story/SKILL.md" story-workflow/skills/story/
cp "${root}/hooks/story-route.sh" "${root}/hooks/story-route.jq" "${root}/hooks/story-lib.sh" "${root}/hooks/story-groups.sh" story-workflow/hooks/
cp "${root}/skills/story/story.example.json" .claude/story.json
git init -q .
