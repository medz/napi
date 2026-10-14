# Development

This branch replaces the experimental direct-Wasm binding implementation with
one Dart package and a staged binding compiler. Business logic executes in Dart
Wasm. Generate Node/Bun ESM facades and TypeScript declarations; a successful
import means the API is ready. Use public Dart interop and the untouched SDK
loader. No native addon, browser distribution, build_runner or plugin framework.

Read doc/architecture.md for stage boundaries and adapter contracts. Only the
frontend imports analyzer. IR, lowering plans and emitted source are distinct.
Runtime never imports compiler/build modules. Unimplemented capabilities fail
explicitly; do not create no-op engines or pretend fixtures are complete features.
The current runnable scope is the explicitly selected scalar function fixture.
Annotation discovery, full conversion engines and production packaging are later
issues. Do not restore the legacy implementation or a compatibility layer.

Run format, analyze, unit tests, the Node/Bun/TypeScript fixture runner, CI-scope
tests and pub dry-run for code, tests, tools, dependencies or CI changes. See
README.md for commands. Ordinary non-executable Markdown changes limited to
AGENTS.md, README.md, CHANGELOG.md and doc/**/*.md use git diff --check in CI.
Mixed or uncertain changes use full CI. Record exact tested versions; Dart Wasm
interop is experimental. Historical released-version contracts are preserved in
CHANGELOG.md, doc/history/0.14.0 and benchmark/history, not current guarantees.

# Code review

Use an independent Codex reviewer or review thread on the final commit. Do not
wait for a cloud review bot's quota when independent review is available.
Report correctness defects at every priority, including P2. Check generated
code and fresh-consumer behavior, not only the generator source. Pay attention
to reference and buffer lifetimes, errors, nullable values, integer precision,
UTF-16 strings, typed-array ownership, and output-directory safety.

# Release planning

Issues and PRs are development units; releases are complete user-facing
milestones that may include several PRs.
Keep version changes and the cumulative changelog in a release-preparation PR.
Documentation, CI, tests, benchmarks, examples and non-urgent fixes normally wait
for that milestone. Ship an urgent patch only for a concrete user-impacting
failure, security defect or compatibility break.

Merge the independently reviewed final commit by its exact SHA after required
checks pass, without publishing each PR. Publish a planned milestone only after
final release review, CI and package validation; verify the public package with a
fresh consumer before announcing it. A recovered registry quota is not a release trigger and a registry
limit does not block independent development. Preserve unpublished tags and
release evidence; do not rewrite published history or retry uploads in a loop.
