# Development

Keep this package small: one annotation, one build command, one export model.
Use napi-rs as the product reference: support native Node-API .node addons and
Dart Wasm bindings with one Dart declaration and JavaScript API model.
Business logic executes in Dart AOT or Dart Wasm. Generated JavaScript loaders
and runtime bindings are allowed; consumers should not initialize them manually.
Preserve new Counter(), argument presence, Dart defaults and shared TypeScript
declarations. Do not substitute factories or explicit presence parameters.
Keep backend ABI and lifecycle code separate from shared semantic IR. Verify
native runtime distribution and each target independently; Dart WasmGC does not
implement napi-rs's WASI/emnapi ABI. Minimize cost using measurements, not a
zero-JS or single-Wasm constraint. Do not add build_runner or a plugin framework.
Preserve unresolved requirements and their evidence. Do not weaken scalar,
presence, identity, or lifetime contracts to make a prototype count as complete.

Run format, analyze, tests (including Node and TypeScript), and pub dry-run for
code, tests, tools, dependency or CI changes. Only pull requests changing ordinary
non-executable doc/**/*.md files may skip expensive test jobs. Static checks,
package dry-run, classifier/gate tests and
git diff --check still run. Every main push uses full CI. Root Markdown files,
mixed or unknown paths, mode/type changes and uncertain history use full CI.
Annotated scalar fixtures currently exercise the source-to-Wasm pipeline.
Handwritten ABI fixtures provide separate, limited evidence for later contracts.
Add native conformance as its implementation lands, including fresh packages,
workers, teardown and cross-backend behavior. Document tested compiler/runtime
versions and experimental SDK coupling for both backends.

# Public content

Issues describe problems and impact only, without implementation or acceptance criteria.
PRs describe changes. Docs explain usage, behavior, limitations and necessary design.
Keep development logs, local constraints and review gates out of public content.
Use the issue forms in `.github/ISSUE_TEMPLATE/` and the PR template in
`.github/PULL_REQUEST_TEMPLATE.md` as the source for contribution prompts.

# Release writing

Use the 0.17.0 entry as the style reference. CHANGELOG.md and GitHub Releases
share one core body; only the version heading and navigation links differ.
Keep both in sync when release notes change.

- Write in English for package users: a short overview, concrete feature
  sections, other improvements and fixes, then upgrade guidance only when needed.
  Preserve consistent heading levels, restrained section icons, fenced-code
  languages and links. Keep the verified version/date consistent with the
  existing release; never invent or reset publication dates.
- Lead with what users can now do and why it helps. Use direct technical titles
  and short Dart plus JavaScript/TypeScript examples where they clarify the
  behavior. Keep essential limitations next to the feature; link to versioned
  guides for detail. Small patches may need only a few bullets.
- Verify every claim and example against the target version's code, tests and
  docs, and compare the full previous-release-to-target range. Group related
  changes by user benefit, not by PR or commit. Do not claim unchanged behavior
  as new, invent APIs or show unsupported examples, add hype, test counts or internal review logs.
- For actual breaking changes, state who is affected and show a small actionable
  migration diff. Do not manufacture migration steps for additive features or
  add empty upgrade sections.
- Editing published notes does not authorize republishing packages, moving tags
  or changing release flags, assets or publication dates.

# Code review

Use the Codex GitHub connector's PR review on the final commit. Its completed
review with no unresolved findings, together with required CI, permits merging
that exact head SHA. A review of an earlier head does not approve a later head.
Independent reviews may supplement it. Do not wait for other review bots' quota.
CodeRabbit is not a review or merge gate; its status and quota do not block work.
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
