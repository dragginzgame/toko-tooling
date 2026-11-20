# Toko Tooling Agent Instructions

Read and apply [the Toko Tooling engineering baseline](TOKO-TOOLING.md) first.
Toko Tooling owns that canonical baseline; this file contains only its local
overlay. Consumers adopt the baseline and keep their own `AGENTS.md`.

For changes to Toko Tooling itself, apply the
[engineering contribution guide](docs/adoption/contributing.md).

Before fleet planning or sibling audits, read the
[current fleet plan](docs/fleet/current-plan.md). It records active reconstruction
work so legacy code and plans are not mistaken for current requirements.

For a requested sibling tooling audit, run [snapshot-drift](tasks/snapshot-drift.md)
for integrity and applicable updates, then [tooling-duplication](tasks/tooling-duplication.md)
for actual caller wiring and missed shared capabilities. Keep these audits outside release gates.

By maintainer direction on 2026-11-09, exclude `ic-replica-watch` and
`ic-profiler` from sibling audits for now unless the user explicitly includes
them. This is in addition to the baseline's existing exclusions.

## Validation in Toko Tooling

For meaningful new work, run `make prepare-work` and add the batch's notes to
the selected pending entry. Use `WORK_VERSION_KIND=minor` or `major` when the
compatibility assessment requires it. The helper reuses a pending version and
keeps root `Cargo.toml` package.version aligned; `make check-version` validates the pair without edits.
A push to `origin/main` consumes that version even if its heading still says
`Unreleased`. The helper uses local remote-tracking evidence. When the user says
the version was pushed, treat it as delivered; refresh stale remote evidence
before preparation rather than reuse its heading or ask for another version request.
This is ordinary local preparation, not staging, committing or releasing.

Toko Tooling's own compiler is pinned in `rust-toolchain.toml`. Prepare it explicitly
as described in [local setup](docs/adoption/local-setup.md#toko-toolings-own-compiler)
before installing Cargo tools. The runtime scanner uses that same prepared
compiler. Consumers implement the baseline's Rust 1.100.0 support policy with
their own target, feature and host qualification.

The baseline's [validation and evidence policy](TOKO-TOOLING.md#validation-and-evidence)
owns when to run checks. This overlay identifies the local checks only.

- For affected scripts, run selected consumer/contract fixtures and ShellCheck,
  using `shellcheck -x` for sourced helpers. Inspect fixture dispatch and select
  affected cases; expose narrow selections when oversized fixtures are touched.
- Toko Tooling's source-bundle release gate is `make release-basic`: version consistency,
  regular-file admission, shell lint, dependency pins, documentation links and an
  actual packaged-payload installation/check. All release kinds use this gate;
  publication repeats only the fresh version/archive checks.
  `check-tooling-package` selects fresh installation-only verification; the default
  `scripts/ci/test-tooling-package.sh` retains takeover/refusal/preview regressions
  for CI and focused changes to the package/installer contract.
- GitHub CI owns the full regression suite, including
  `scripts/ci/test-portable-tools.sh`. Run the full suite locally only on
  explicit request. Toko Tooling releases use the source-bundle gate above.
- Documentation/policy-only changes use `make check-doc-links`, instruction
  consistency review and `git diff --check`; they do not require installer/export
  regression suites. Run `make check-version` when maintaining the pending pair.

The common [contribution rules](rules/contributions.md) apply without a local
authority exception. Keep product-specific setup and checks here; do not repeat
the baseline's implementation, PR, checkout or delivery rules.
