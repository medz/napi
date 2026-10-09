# Development

Keep this package small: one annotation, one build command, one export model.
Business logic must execute in Dart Wasm with real named Wasm exports.
Consumers import functions directly from .wasm or an npm entry pointing to it.
Do not replace that API with manual initialization or a JavaScript entrypoint.
Do not add a native addon backend, build_runner, or a plugin framework.

Run format, analyze, tests (including Node and TypeScript), and pub dry-run.
Document tested compiler/runtime versions; the Dart Wasm interop is experimental.

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
