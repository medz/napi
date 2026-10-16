# Development

Keep this package small: one annotation, one build command, one export model.
Business logic must execute in Dart Wasm with real named Wasm exports.
Consumers import functions directly from .wasm or an npm entry pointing to it.
The final executable artifact is one module.wasm. Statically link build-time
runtime modules before publication. Ship no JavaScript files, JS runtime npm
dependencies, dynamic JS source, or additional executable sidecars. TypeScript
declarations, package metadata, and licenses may accompany the Wasm file.
Document any engine-provided Wasm builtins or approved Node built-in imports.
Do not replace that API with manual initialization or a JavaScript entrypoint.
Do not add a native addon backend, build_runner, or a plugin framework.
Preserve unresolved requirements and their evidence. Do not weaken scalar,
presence, identity, or lifetime contracts to make a prototype count as complete.

Run format, analyze, tests (including Node and TypeScript), and pub dry-run for
code, tests, tools, dependency or CI changes. Ordinary non-executable Markdown
changes limited to AGENTS.md, README.md, CHANGELOG.md and doc/**/*.md use
git diff --check. Mixed or unknown paths and uncertain history use full CI.
Annotated scalar fixtures exercise the source-to-Wasm pipeline. Handwritten
ABI fixtures provide separate, limited evidence for later binding contracts.
Document tested compiler/runtime versions; the Dart Wasm interop is experimental.

# Code review

Use the Codex GitHub connector's PR review on the final commit. Its completed
review with no unresolved findings, together with required CI, permits merging
that exact head SHA. A review of an earlier head does not approve a later head.
Independent reviews may supplement it. Do not wait for other review bots' quota.
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

Merge the Codex-reviewed final commit by its exact SHA after required
checks pass, without publishing each PR. Publish a planned milestone only after
final release review, CI and package validation; verify the public package with a
fresh consumer before announcing it. Publish at most four versions per
Asia/Shanghai calendar day; count public registry versions and release evidence
before every upload. The cap is a limit, not a target. A recovered registry quota
is not a release trigger and a registry limit does not block development.
Preserve unpublished tags and
release evidence; do not rewrite published history or retry uploads in a loop.
