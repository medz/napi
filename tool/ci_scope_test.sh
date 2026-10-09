#!/usr/bin/env bash
set -euo pipefail

scope=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci_scope.sh
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/napi-ci-scope-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
real_git=$(command -v git)
count=0
repo_count=0

new_repo() {
  repo_count=$((repo_count + 1))
  repo="$test_dir/repo-$repo_count"
  mkdir -p "$repo"
  cd "$repo"
  git init -q --initial-branch=main
  git config user.name 'CI scope test'
  git config user.email 'ci-scope@example.invalid'
  git config core.fileMode true
  mkdir -p doc/nested lib
  for path in AGENTS.md README.md CHANGELOG.md doc/guide.md doc/nested/guide.md lib/api.dart; do
    printf 'initial\n' > "$path"
  done
  git add .
  git commit -qm initial
  base=$(git rev-parse HEAD)
}

reset_repo() {
  git reset --hard -q "$base"
  git clean -fdq
}

commit() {
  git add -A
  git commit -qm change
  target=$(git rev-parse HEAD)
}

expect() {
  local label=$1 expected=$2
  shift 2
  local actual
  actual=$(bash "$scope" "$@")
  if [[ $actual != "$expected" ]]; then
    printf 'FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  count=$((count + 1))
  printf 'PASS %s\n' "$label"
}

new_repo
for path in AGENTS.md README.md CHANGELOG.md doc/guide.md doc/nested/guide.md; do
  reset_repo
  printf 'updated\n' > "$path"
  commit
  expect "modify $path" true push "$base" "$target"
done
expect 'pull request docs' true pull_request "$base" "$target"

reset_repo
printf 'new\n' > doc/nested/new.md
commit
expect 'add nested docs' true push "$base" "$target"
reset_repo
rm doc/nested/guide.md
commit
expect 'delete nested docs' true push "$base" "$target"

for path in lib/api.dart pubspec.yaml .github/workflows/ci.yml test/api_test.dart tool/build.dart benchmark/bench.dart example/api.dart other.md doc/api.txt; do
  reset_repo
  mkdir -p "$(dirname "$path")"
  printf 'updated\n' > README.md
  printf 'code or unknown path\n' > "$path"
  commit
  expect "mixed docs and $path" false push "$base" "$target"
done

reset_repo
git mv lib/api.dart doc/api.md
commit
expect 'source to docs rename' false push "$base" "$target"
reset_repo
git mv doc/guide.md lib/guide.dart
commit
expect 'docs to source rename' false push "$base" "$target"
reset_repo
git mv doc/guide.md doc/renamed.md
commit
expect 'ordinary docs rename' true push "$base" "$target"

reset_repo
chmod +x README.md
git update-index --chmod=+x README.md
commit
expect 'executable mode' false push "$base" "$target"
reset_repo
rm README.md
ln -s lib/api.dart README.md
commit
expect 'docs symlink' false push "$base" "$target"
reset_repo
git update-index --add --cacheinfo "160000,$base,doc/submodule.md"
git commit -qm submodule
target=$(git rev-parse HEAD)
expect 'docs submodule' false push "$base" "$target"

reset_repo
path=$'doc/space quote\' double" $(touch injected) `touch injected`\nline.md'
printf 'filename is data\n' > "$path"
commit
expect 'spaces quotes shell syntax and newline' true push "$base" "$target"
[[ ! -e injected ]]

expect 'unknown event' false workflow_dispatch "$base" "$target"
expect 'missing arguments' false
expect 'absent base' false push '' "$target"
expect 'zero base' false push 0000000000000000000000000000000000000000 "$target"
expect 'malformed base' false push invalid "$target"
expect 'nonexistent base' false push 1111111111111111111111111111111111111111 "$target"
expect 'zero target' false push "$base" 0000000000000000000000000000000000000000
expect 'nonexistent target' false push "$base" 1111111111111111111111111111111111111111
expect 'mismatched checkout' false push "$base" "$base"
expect 'empty diff' false push "$target" "$target"
git commit --allow-empty -qm empty
previous=$target
target=$(git rev-parse HEAD)
expect 'empty commit diff' false push "$previous" "$target"

git clone -q --depth 1 "file://$repo" "$test_dir/shallow"
cd "$test_dir/shallow"
expect 'missing shallow history' false push "$base" "$target"

new_repo
git checkout -q --orphan unrelated
git rm -rqf .
printf 'unrelated docs\n' > README.md
commit
expect 'nonancestor base' false push "$base" "$target"

new_repo
printf 'source\n' > lib/api.dart
commit
printf 'last commit is docs\n' > README.md
commit
expect 'push includes earlier code commit' false push "$base" "$target"
reset_repo
printf 'first docs\n' > README.md
commit
printf 'second docs\n' > CHANGELOG.md
commit
expect 'push includes only docs commits' true push "$base" "$target"

new_repo
git checkout -qb feature
printf 'source\n' > lib/api.dart
commit
printf 'last PR commit is docs\n' > README.md
commit
git checkout -q main
printf 'base branch docs\n' > CHANGELOG.md
commit
pr_base=$target
git merge -q --no-ff --no-edit feature
target=$(git rev-parse HEAD)
expect 'PR merge includes earlier source commit' false pull_request "$pr_base" "$target"

new_repo
git checkout -qb feature
printf 'PR docs\n' > README.md
commit
git checkout -q main
printf 'base branch docs\n' > CHANGELOG.md
commit
pr_base=$target
git merge -q --no-ff --no-edit feature
target=$(git rev-parse HEAD)
expect 'PR merge includes only PR docs' true pull_request "$pr_base" "$target"

# Substitute only Git's raw diff output to exercise errors impossible to create
# as a normal repository tree. Every other command uses the real Git binary.
mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == diff ]]; then
  cat "$CI_SCOPE_TEST_RAW"
  [[ $CI_SCOPE_TEST_DIFF == success ]]
else
  exec "$CI_SCOPE_TEST_REAL_GIT" "$@"
fi
SH
chmod +x "$test_dir/bin/git"
export CI_SCOPE_TEST_REAL_GIT="$real_git"
export CI_SCOPE_TEST_RAW="$test_dir/raw"
export CI_SCOPE_TEST_DIFF=success
export PATH="$test_dir/bin:$PATH"
old_id=$($real_git rev-parse "$pr_base:README.md")
new_id=$($real_git rev-parse "$target:README.md")
header=":100644 100644 $old_id $new_id M"

printf '%s\0%s\0' "$header" README.md > "$CI_SCOPE_TEST_RAW"
expect 'complete raw record' true pull_request "$pr_base" "$target"
CI_SCOPE_TEST_DIFF=failure
expect 'failed diff with partial valid output' false pull_request "$pr_base" "$target"
CI_SCOPE_TEST_DIFF=success
printf '%s' "$header" > "$CI_SCOPE_TEST_RAW"
expect 'unterminated raw header' false pull_request "$pr_base" "$target"
printf '%s\0' "$header" > "$CI_SCOPE_TEST_RAW"
expect 'missing raw path' false pull_request "$pr_base" "$target"
printf '%s\0%s' "$header" README.md > "$CI_SCOPE_TEST_RAW"
expect 'unterminated raw path' false pull_request "$pr_base" "$target"
printf '%s\0%s\0%s' "$header" README.md trailing > "$CI_SCOPE_TEST_RAW"
expect 'truncated trailing record' false pull_request "$pr_base" "$target"
printf '\0' > "$CI_SCOPE_TEST_RAW"
expect 'empty raw header' false pull_request "$pr_base" "$target"
printf ':100644 100644 %s %s R100\0%s\0' "$old_id" "$new_id" README.md > "$CI_SCOPE_TEST_RAW"
expect 'unexpected raw status' false pull_request "$pr_base" "$target"
printf ':100644 100755 %s %s M\0%s\0' "$old_id" "$new_id" README.md > "$CI_SCOPE_TEST_RAW"
expect 'unexpected raw mode' false pull_request "$pr_base" "$target"
printf ':100644 100644 %s %s M\0%s\0' 0000000000000000000000000000000000000000 "$new_id" README.md > "$CI_SCOPE_TEST_RAW"
expect 'unexpected absent blob' false pull_request "$pr_base" "$target"
: > "$CI_SCOPE_TEST_RAW"
expect 'empty raw output' false pull_request "$pr_base" "$target"

cat > "$test_dir/bin/mktemp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$test_dir/bin/mktemp"
if bash "$scope" pull_request "$pr_base" "$target" > "$test_dir/result"; then
  printf 'FAIL unexpected detector failure must fail the check\n' >&2
  exit 1
fi
[[ $(cat "$test_dir/result") != true ]]
count=$((count + 1))
printf 'PASS unexpected detector failure\n'
printf '%s CI scope cases passed.\n' "$count"
