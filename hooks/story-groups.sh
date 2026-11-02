#!/usr/bin/env bash
# The independence test of /story, as a command. Reads the claims table of a plan
# and prints which tasks run in the story-branch session first (foundation), which
# run in parallel tracks, and which wait for the merge (integrate).
# Procedure: skills/story/SKILL.md ("Parallel tracks").
#
# Usage:
#   story-groups.sh <plan file>
#       Reads the first table under "## Order of work" whose header starts with
#       | Task | Wave | Depends | Files |, with an optional fifth column Track.
#       Wave is F (foundation), T (track) or I (integrate). Depends is "-" or
#       task ids. Files is "-" or paths relative to the repo root: a file, a
#       folder (trailing /), or path#region when two tasks share one file and
#       each owns a named region. Track is the label of the track that the plan
#       puts a T task in; T tasks with one label share a session. Without a
#       label a T task gets its own track, named t<n>, so labels of the form
#       t<digits> are reserved.
#       Prints, one per line:
#         FOUNDATION <task>...      run first, in the story-branch session
#         TRACK <name> <task>...    one session per track, tasks in table order
#         INTEGRATE <task>...       run after the tracks are merged
#         JOIN <a> <b> depends|file <path>   why two tasks share a track
#         REFUSE <a> <b> tracks <x> <y> depends|file <path>   two labels merged
#         MOVE <task> INTEGRATE shared|depends <path or task>
#         MODE parallel tracks=<n> cap=<m> start=<k> queue=<q>
#         MODE sequential tracks=<n> reason=<why>
#       Exit 0 when the plan's waves and labels hold, 2 when the test moved a
#       task or merged two labels (the output is the safe grouping).
#   story-groups.sh --scope <plan file> <task,task,...> <base> [<head>]
#       Lists the files changed between base and head (default HEAD) that no
#       claim of the named tasks covers (OUTSIDE) or that match a shared glob
#       (SHARED). Exit 1 when there is any, else prints SCOPE ok.
#
# Config (the file of story_config_file in story-lib.sh):
#   parallel.max     cap on parallel tracks. Default 1 (off).
#   parallel.shared  globs of shared or generated files. A track candidate that
#                    claims one moves to INTEGRATE. Matched with shell case rules,
#                    where * also matches /.
# Exit 1 with the reason on a bad plan: no table, a duplicate task, an unknown
# dependency, an unknown wave, a T task without files, a reserved label, a
# dependency that points forward in the same group, or a foundation task that
# depends on a track or integrate task. Bash 3.2 compatible (the macOS /bin/bash).
set -uo pipefail
# A claim such as consultant/[id]/page.tsx must stay a word, not a glob.
set -f

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=story-lib.sh
. "${here}/story-lib.sh"

die() { printf 'story-groups: %s\n' "$1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is not on PATH. Install it (brew install jq)."

cfg="$(story_config_file)"
max=1
shared=""
if [ -f "${cfg}" ]; then
  max="$(jq -r '.parallel.max // 1' "${cfg}" 2>/dev/null)" || die "cannot read ${cfg} with jq."
  shared="$(jq -r '(.parallel.shared // [])[]' "${cfg}" 2>/dev/null)" || die "cannot read parallel.shared in ${cfg}."
fi
[[ "${max}" =~ ^[0-9]+$ ]] || die "parallel.max in ${cfg} is '${max}', not a whole number."

# rows <plan>: task<TAB>wave<TAB>depends<TAB>files<TAB>track, from the claims table.
rows() {
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^## / { in_sec = ($0 ~ /^## Order of work/); intable = 0; next }
    in_sec && !intable && /^\|/ {
      h = tolower($0); gsub(/[ \t`]/, "", h)
      if (h ~ /^\|task\|wave\|depends\|files\|/) { intable = 1; skip = 1; seen = 1; hastrack = (h ~ /^\|task\|wave\|depends\|files\|track\|/); next }
    }
    in_sec && intable {
      if ($0 !~ /^\|/) { intable = 0; next }
      if (skip && $0 ~ /^\|[ \t:|-]+$/) { skip = 0; next }
      n = split($0, c, "|")
      t = trim(c[2]); w = trim(c[3]); d = trim(c[4]); f = trim(c[5]); l = hastrack ? trim(c[6]) : ""
      gsub(/`/, "", t); gsub(/`/, "", w); gsub(/`/, "", d); gsub(/`/, "", f); gsub(/[`\t ]/, "", l)
      if (l == "-") l = ""
      gsub(/#/, "", t); gsub(/[ \t]+/, "", t)
      gsub(/[ \t]+/, "", d); gsub(/#/, "", d)
      gsub(/[ \t]+/, "", f)
      printf "%s\t%s\t%s\t%s\t%s\n", t, toupper(w), d, f, l
    }
    END { if (!seen) exit 3 }
  ' "$1"
}

# claim_path <claim>: the path of a claim, without region, glob tail or slash.
claim_path() {
  local p="${1%%#*}"
  p="${p%/\*\*}"; p="${p%/\*}"; p="${p%/}"
  case "${p}" in *[\*\?]*) p="${p%%[\*\?]*}"; p="${p%/*}" ;; esac
  printf '%s' "${p}"
}
claim_region() { case "$1" in *"#"*) printf '%s' "${1#*#}" ;; esac; }

# overlap <claimA> <claimB>: exit 0 when the claims touch the same file.
overlap() {
  local pa pb ra rb
  pa="$(claim_path "$1")"; pb="$(claim_path "$2")"
  ra="$(claim_region "$1")"; rb="$(claim_region "$2")"
  [ -n "${pa}" ] && [ -n "${pb}" ] || return 1
  if [ "${pa}" = "${pb}" ]; then
    [ -n "${ra}" ] && [ -n "${rb}" ] && [ "${ra}" != "${rb}" ] && return 1
    return 0
  fi
  case "${pb}" in "${pa}"/*) return 0 ;; esac
  case "${pa}" in "${pb}"/*) return 0 ;; esac
  return 1
}

# is_shared <path>: exit 0 when the path matches a shared glob.
is_shared() {
  local g gp p="$1"
  [ -n "${shared}" ] || return 1
  while IFS= read -r g; do
    [ -n "${g}" ] || continue
    # shellcheck disable=SC2254 # the glob is data on purpose
    case "${p}" in ${g}) return 0 ;; esac
    # shellcheck disable=SC2254
    case "${p}/" in ${g}) return 0 ;; esac
    gp="${g%%[\*\?]*}"
    if [ -n "${gp}" ]; then
      case "${gp}" in "${p}"/*|"${p}") return 0 ;; esac
    fi
  done <<<"${shared}"
  return 1
}

# plan_claims <plan> <task list, comma separated>: the claims of those tasks.
plan_claims() {
  local plan="$1" want=",$2," t w d f c
  while IFS=$'\t' read -r t w d f _; do
    case "${want}" in *",${t},"*) ;; *) continue ;; esac
    [ "${f}" = "-" ] && continue
    for c in ${f//,/ }; do printf '%s\n' "${c}"; done
  done < <(rows "${plan}")
}

if [ "${1:-}" = "--scope" ]; then
  plan="${2:-}"; tasks="${3:-}"; base="${4:-}"; head="${5:-HEAD}"
  [ -f "${plan}" ] && [ -n "${tasks}" ] && [ -n "${base}" ] || die "usage: story-groups.sh --scope <plan file> <task,task,...> <base> [<head>]"
  claims="$(plan_claims "${plan}" "${tasks//#/}")"
  [ -n "${claims}" ] || die "the plan has no claim for tasks ${tasks}."
  files="$(git diff --name-only "${base}..${head}" 2>&1)" || die "git diff ${base}..${head} failed: ${files}"
  bad=0
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    if is_shared "${file}"; then printf 'SHARED %s\n' "${file}"; bad=1; continue; fi
    cov=0
    while IFS= read -r c; do
      p="$(claim_path "${c}")"
      [ -n "${p}" ] || continue
      case "${file}" in "${p}"|"${p}"/*) cov=1; break ;; esac
    done <<<"${claims}"
    [ "${cov}" -eq 1 ] || { printf 'OUTSIDE %s\n' "${file}"; bad=1; }
  done <<<"${files}"
  [ "${bad}" -eq 0 ] && printf 'SCOPE ok\n'
  exit "${bad}"
fi

plan="${1:-}"
[ -f "${plan}" ] || die "usage: story-groups.sh <plan file>. No such file: '${plan}'."
tsv="$(rows "${plan}")"; rc=$?
[ "${rc}" -eq 0 ] || die "${plan} has no claims table. Add the table '| Task | Wave | Depends | Files |' under '## Order of work'."
[ -n "${tsv}" ] || die "the claims table in ${plan} has no row."

n=0
T=(); W=(); D=(); F=(); L=()
while IFS=$'\t' read -r t w d f l; do
  [ -n "${t}" ] || die "a row of the claims table has no task id."
  [[ "${t}" =~ ^[A-Za-z0-9._-]+$ ]] || die "task id '${t}' holds characters outside A-Z a-z 0-9 . _ -."
  i=0
  while [ "${i}" -lt "${n}" ]; do [ "${T[$i]}" = "${t}" ] && die "task ${t} appears twice in the claims table."; i=$((i + 1)); done
  case "${w}" in F|T|I) ;; *) die "task ${t} has wave '${w}'. Use F (foundation), T (track) or I (integrate)." ;; esac
  [ -n "${d}" ] || d="-"
  [ -n "${f}" ] || die "task ${t} has an empty Files cell. Write - when it touches no file."
  if [ "${w}" = T ] && [ "${f}" = "-" ]; then die "task ${t} is wave T and claims no file. A track task must name its files."; fi
  [[ "${l}" =~ ^[A-Za-z0-9._-]*$ ]] || die "task ${t} has track label '${l}'. Use A-Z a-z 0-9 . _ - only."
  [ "${w}" = T ] || l=""
  [[ "${l}" =~ ^t[0-9]+$ ]] && die "task ${t} has track label '${l}'. Labels t<digits> name the tracks without a label. Pick another label."
  T[n]="${t}"; W[n]="${w}"; D[n]="${d}"; F[n]="${f}"; L[n]="${l}"
  n=$((n + 1))
done <<<"${tsv}"

idx() { local k=0; while [ "${k}" -lt "${n}" ]; do [ "${T[$k]}" = "$1" ] && { printf '%s' "${k}"; return 0; }; k=$((k + 1)); done; return 1; }
deps_of() { [ "${D[$1]}" = "-" ] || printf '%s\n' "${D[$1]//,/ }" | tr ' ' '\n'; }

i=0
while [ "${i}" -lt "${n}" ]; do
  for d in $(deps_of "${i}"); do
    idx "${d}" >/dev/null || die "task ${T[$i]} depends on ${d}, which is not in the claims table."
    [ "${d}" != "${T[$i]}" ] || die "task ${T[$i]} depends on itself."
  done
  i=$((i + 1))
done

out_move=""
out_join=""
refused=0
# Shared files move a track candidate to INTEGRATE.
i=0
while [ "${i}" -lt "${n}" ]; do
  if [ "${W[$i]}" = T ]; then
    for c in ${F[$i]//,/ }; do
      p="$(claim_path "${c}")"
      if is_shared "${p}"; then
        W[i]=I; refused=1
        out_move="${out_move}MOVE ${T[$i]} INTEGRATE shared ${p}"$'\n'
        break
      fi
    done
  fi
  i=$((i + 1))
done
# A track candidate that depends on an integrate task moves too, until nothing changes.
changed=1
while [ "${changed}" -eq 1 ]; do
  changed=0
  i=0
  while [ "${i}" -lt "${n}" ]; do
    if [ "${W[$i]}" = T ]; then
      for d in $(deps_of "${i}"); do
        j="$(idx "${d}")"
        if [ "${W[$j]}" = I ]; then
          W[i]=I; changed=1; refused=1
          out_move="${out_move}MOVE ${T[$i]} INTEGRATE depends ${d}"$'\n'
          break
        fi
      done
    fi
    i=$((i + 1))
  done
done
# A foundation task depends on foundation tasks only.
i=0
while [ "${i}" -lt "${n}" ]; do
  if [ "${W[$i]}" = F ]; then
    for d in $(deps_of "${i}"); do
      j="$(idx "${d}")"
      [ "${W[$j]}" = F ] || die "foundation task ${T[$i]} depends on ${d}, which is not a foundation task. Move ${T[$i]} to wave T or I, or ${d} to wave F."
    done
  fi
  i=$((i + 1))
done

# Union-find over the track candidates.
UF=()
i=0; while [ "${i}" -lt "${n}" ]; do UF[i]=$i; i=$((i + 1)); done
find() { local x=$1; while [ "${UF[$x]}" -ne "$x" ]; do x=${UF[$x]}; done; printf '%s' "${x}"; }
i=0
while [ "${i}" -lt "${n}" ]; do
  j=$((i + 1))
  while [ "${j}" -lt "${n}" ]; do
    if [ "${W[$i]}" = T ] && [ "${W[$j]}" = T ]; then
      why=""
      if [ -n "${L[$i]}" ] && [ "${L[$i]}" = "${L[$j]}" ]; then
        ri="$(find "${i}")"; rj="$(find "${j}")"
        [ "${ri}" = "${rj}" ] || UF[rj]=${ri}
      fi
      for d in $(deps_of "${i}"); do [ "${d}" = "${T[$j]}" ] && why="depends"; done
      for d in $(deps_of "${j}"); do [ "${d}" = "${T[$i]}" ] && why="depends"; done
      if [ -z "${why}" ]; then
        for ca in ${F[$i]//,/ }; do
          for cb in ${F[$j]//,/ }; do
            if overlap "${ca}" "${cb}"; then why="file $(claim_path "${ca}")"; break 2; fi
          done
        done
      fi
      if [ -n "${why}" ]; then
        ri="$(find "${i}")"; rj="$(find "${j}")"
        [ "${ri}" = "${rj}" ] || UF[rj]=${ri}
        if [ -n "${L[$i]}" ] && [ -n "${L[$j]}" ] && [ "${L[$i]}" != "${L[$j]}" ]; then
          refused=1
          out_join="${out_join}REFUSE ${T[$i]} ${T[$j]} tracks ${L[$i]} ${L[$j]} ${why}"$'\n'
        elif [ "${L[$i]}" != "${L[$j]}" ] || [ -z "${L[$i]}" ]; then
          out_join="${out_join}JOIN ${T[$i]} ${T[$j]} ${why}"$'\n'
        fi
      fi
    fi
    j=$((j + 1))
  done
  i=$((i + 1))
done

# Group ids: 0 foundation, 1.. tracks in order of first task, 9999 integrate.
nt=0
ROOT=(); GID=()
i=0
while [ "${i}" -lt "${n}" ]; do
  case "${W[$i]}" in
    F) GID[i]=0 ;;
    I) GID[i]=9999 ;;
    T)
      r="$(find "${i}")"
      k=0; found=""
      while [ "${k}" -lt "${nt}" ]; do [ "${ROOT[$k]}" = "${r}" ] && found=$((k + 1)); k=$((k + 1)); done
      if [ -z "${found}" ]; then ROOT[nt]=${r}; nt=$((nt + 1)); found=${nt}; fi
      GID[i]=${found}
      ;;
  esac
  i=$((i + 1))
done

# A dependency inside one group points to an earlier row.
i=0
while [ "${i}" -lt "${n}" ]; do
  for d in $(deps_of "${i}"); do
    j="$(idx "${d}")"
    if [ "${GID[$i]}" = "${GID[$j]}" ] && [ "${j}" -gt "${i}" ]; then
      die "task ${T[$i]} depends on ${d}, which comes later in the table. List ${d} first."
    fi
  done
  i=$((i + 1))
done

list() { local g="$1" k=0 s=""; while [ "${k}" -lt "${n}" ]; do [ "${GID[$k]}" = "${g}" ] && s="${s} ${T[$k]}"; k=$((k + 1)); done; printf '%s' "${s}"; }
fnd="$(list 0)"; [ -n "${fnd}" ] && printf 'FOUNDATION%s\n' "${fnd}"
# name <group>: the labels of a track joined by +, or t<group> without a label.
name() {
  local g="$1" k=0 s=""
  while [ "${k}" -lt "${n}" ]; do
    if [ "${GID[$k]}" = "${g}" ] && [ -n "${L[$k]}" ]; then
      case "+${s}+" in *"+${L[$k]}+"*) ;; *) s="${s:+${s}+}${L[$k]}" ;; esac
    fi
    k=$((k + 1))
  done
  printf '%s' "${s:-t${g}}"
}
k=1; while [ "${k}" -le "${nt}" ]; do printf 'TRACK %s%s\n' "$(name "${k}")" "$(list "${k}")"; k=$((k + 1)); done
ing="$(list 9999)"; [ -n "${ing}" ] && printf 'INTEGRATE%s\n' "${ing}"
printf '%s%s' "${out_move}" "${out_join}"
if [ "${nt}" -lt 2 ]; then
  printf 'MODE sequential tracks=%s reason=fewer-than-2-tracks\n' "${nt}"
elif [ "${max}" -lt 2 ]; then
  printf 'MODE sequential tracks=%s reason=parallel.max=%s\n' "${nt}" "${max}"
else
  start=${nt}; [ "${start}" -gt "${max}" ] && start=${max}
  printf 'MODE parallel tracks=%s cap=%s start=%s queue=%s\n' "${nt}" "${max}" "${start}" "$((nt - start))"
fi
[ "${refused}" -eq 0 ] || exit 2
exit 0
