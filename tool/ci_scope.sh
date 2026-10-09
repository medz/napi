#!/usr/bin/env bash
set -euo pipefail

# Print true only when the entire tested change contains ordinary documentation.
# Missing history or unexpected Git output must keep the full CI workload.
full() {
  printf 'false\n'
  exit 0
}

[[ $# == 3 ]] || full
event=$1
base=$2
target=$3
case "$event" in push|pull_request) ;; *) full ;; esac

zero=0000000000000000000000000000000000000000
[[ $base =~ ^[0-9a-f]{40}$ && $target =~ ^[0-9a-f]{40}$ ]] || full
[[ $base != "$zero" && $target != "$zero" ]] || full
git cat-file -e "$base^{commit}" 2>/dev/null || full
git cat-file -e "$target^{commit}" 2>/dev/null || full
head=$(git rev-parse --verify HEAD 2>/dev/null) || full
[[ $head == "$target" ]] || full
git merge-base --is-ancestor "$base" "$target" 2>/dev/null || full

diff_file=$(mktemp "${TMPDIR:-/tmp}/napi-ci-scope.XXXXXX")
trap 'rm -f "$diff_file"' EXIT
if ! git diff --raw --no-abbrev --no-renames --no-ext-diff --no-textconv -z \
  "$base" "$target" -- > "$diff_file"; then
  full
fi

changed=false
header_pattern='^:([0-7]{6}) ([0-7]{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([AMD])$'
while true; do
  header=''
  if ! IFS= read -r -d '' header; then
    [[ -z $header ]] || full
    break
  fi
  [[ $header =~ $header_pattern ]] || full
  old_mode=${BASH_REMATCH[1]}
  new_mode=${BASH_REMATCH[2]}
  old_id=${BASH_REMATCH[3]}
  new_id=${BASH_REMATCH[4]}
  status=${BASH_REMATCH[5]}
  IFS= read -r -d '' path || full
  case "$old_mode:$new_mode:$status" in
    000000:100644:A) [[ $old_id == "$zero" && $new_id != "$zero" ]] || full ;;
    100644:000000:D) [[ $old_id != "$zero" && $new_id == "$zero" ]] || full ;;
    100644:100644:M) [[ $old_id != "$zero" && $new_id != "$zero" ]] || full ;;
    *) full ;;
  esac
  case "$path" in
    AGENTS.md|README.md|CHANGELOG.md|doc/*.md) ;;
    *) full ;;
  esac
  changed=true
done < "$diff_file"

printf '%s\n' "$changed"
