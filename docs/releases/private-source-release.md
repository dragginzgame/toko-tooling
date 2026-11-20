# Direct Git releases for private Cargo workspaces

Use this adapter when all product packages share a prepared
`[workspace.package].version`, declare `publish = false` (directly or through
inheritance), and a push to the delivery branch consumes the version. The
release delivers a commit and annotated `vX.Y.Z` tag. It runs the application's
validation target. Cargo publication and registry readback have no role in this
workflow.

Select [the private source adapter](../../make/private-source-release.mk) as a
snapshot entrypoint alongside the usual consumer entrypoint. For example:

```make
.DEFAULT_GOAL := help
TOKO_TOOLING_RELEASE := 1
RELEASE_REMOTE := origin
RELEASE_BRANCH := main
SOURCE_RELEASE_MANIFEST := Cargo.toml
SOURCE_RELEASE_LOCKFILES := Cargo.lock qualification/Cargo.lock
SOURCE_RELEASE_VERIFY := verify

include vendor/toko-tooling/make/consumer.mk
include vendor/toko-tooling/make/private-source-release.mk
```

Keep the existing product `verify` target and any explicit tool preparation
it requires. The adapter supplies the routine release hooks. The manifest
path selects the version owner. List the product lockfile and each additional
lock containing a local product package, using repository-relative paths
without whitespace. Omit the qualification lock when it contains no product
packages. The product lock must cover every workspace member. The adapter uses
Cargo metadata, Git, Perl, awk, jq and Mike Farah yq.

## Prepare and deliver a batch

1. Start from a fetched delivery branch with an existing version and a numbered
   top heading in its root `CHANGELOG.md`. The local `origin/main` tracking ref
   supplies the cutoff for the read-only `make source-release-check`. Refresh
   it after another checkout delivers. Release preflight verifies the live
   branch. A missing release tag does not reopen a delivered version.
2. For a new batch, update the workspace version and refresh the declared
   locks with the application's normal Cargo workflow. Insert
   `## [X.Y.Z] - Unreleased` above the previously delivered section. Preserve
   that section and all older notes verbatim, even if an old heading still says
   `Unreleased`. Run `make source-release-check`. Compatible local edits and
   pushes to a topic branch can extend this draft. The check treats any tracked
   difference or nonignored untracked file as a change when the version is
   already delivered. Run it before the product push.
3. Commit the draft and product changes. From the configured delivery branch,
   run the matching `make release-patch`, `make release-minor`, or
   `make release-major` **before** pushing that branch independently. The
   prepared version must equal that increment from the delivered version.
   The shared runner executes product validation, dates only the pending heading,
   verifies the index and committed content, and pushes branch and tag atomically.
4. After interruption, use `make release-resume VERSION=X.Y.Z` for the saved
   attempt. If another push consumed the prepared version, reconcile the branch
   and journal before starting another release.

The [reference fixture](../../scripts/ci/tests/private-source-release.sh) uses a
local bare remote and exercises draft reuse, changelog preservation, lock
mismatch, rejected push and exact-version recovery.
