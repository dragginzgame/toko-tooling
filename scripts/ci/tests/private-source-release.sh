#!/usr/bin/env bash
# Shared companions: make/private-source-release.mk scripts/ci/fixture-lifecycle.sh scripts/ci/prepare-script-fixture.sh
set -euo pipefail
root="${BASH_SOURCE[0]}"
[[ "$root" == /* ]] || root="$PWD/$root"
root="$(CDPATH='' cd -P -- "${root%/*}/../../.." && printf '%s/.' "$PWD")"
root="${root%/.}"
# shellcheck source=scripts/ci/fixture-lifecycle.sh
source "$root/scripts/ci/fixture-lifecycle.sh"
mkdir -p "$root/target"
fixture=$(fixture_create "$root/target/private-source.XXXXXX")
fixture_complete=false
trap 'fixture_finish "$?" "$fixture" "Private release fixture retained"' EXIT
unset MAKEFLAGS MFLAGS MAKEOVERRIDES GNUMAKEFLAGS MAKEFILES
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=file
export GIT_AUTHOR_NAME=Fixture GIT_COMMITTER_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_EMAIL=fixture@example.invalid
git init -q --bare "$fixture/remote"
git init -q -b main "$fixture/app"
cd "$fixture/app"
git remote add origin "$fixture/remote"
mkdir -p vendor/toko-tooling
bash "$root/scripts/ci/prepare-script-fixture.sh" "$root" "$PWD/vendor/toko-tooling" make/private-source-release.mk
mkdir -p product/src qualification "$fixture/bin"
cat > Cargo.toml <<'TOML'
[workspace]
members = ["product"]
resolver = "3"
[workspace.package]
version = "1.2.3"
TOML
cat > product/Cargo.toml <<'TOML'
[package]
name = "private-app"
version.workspace = true
edition = "2024"
publish = false
TOML
touch product/src/lib.rs
cargo generate-lockfile
cp Cargo.lock qualification/Cargo.lock
cat > CHANGELOG.md <<'NOTES'
# Changelog

## [1.2.3] - Unreleased

- Delivered without a tag.
NOTES
cat > Makefile <<'MAKE'
SOURCE_RELEASE_MANIFEST := Cargo.toml
SOURCE_RELEASE_LOCKFILES := Cargo.lock qualification/Cargo.lock
RELEASE_BRANCH := main
SOURCE_RELEASE_VERIFY := verify-product
include vendor/toko-tooling/make/private-source-release.mk
.PHONY: verify-product
verify-product:
	@echo validated >> .git/verified
MAKE
git add .
git commit -qm initial
git push -qu origin main
delivered=$(git rev-parse HEAD)
export REAL_CARGO
REAL_CARGO=$(command -v cargo)
cat > "$fixture/bin/cargo" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == metadata && "$2" == --locked && "$3" == --no-deps ]] || exit 91
exec "$REAL_CARGO" "$@"
STUB
# Any unexpected registry transfer or Cargo publication fails the fixture.
cat > "$fixture/bin/curl" <<'STUB'
#!/bin/sh
exit 92
STUB
chmod +x "$fixture/bin/cargo" "$fixture/bin/curl"
export PATH="$fixture/bin:$PATH"
make source-release-check
echo '// Next batch' >> product/src/lib.rs
if make source-release-check > "$fixture/refusal" 2>&1; then exit 1; fi
grep -F 'already reached refs/remotes/origin/main' "$fixture/refusal"
git checkout -qb topic
sed 's/1\.2\.3/1.2.4/' Cargo.toml > updated && mv updated Cargo.toml
sed 's/1\.2\.3/1.2.4/' Cargo.lock > updated && mv updated Cargo.lock
{ printf '# Changelog\n\n## [1.2.4] - Unreleased\n\n- New batch.\n\n'; sed -n '/^## /,$p' CHANGELOG.md; } > updated
mv updated CHANGELOG.md
if make source-release-check > "$fixture/refusal" 2>&1; then exit 1; fi
grep -F 'align product versions in qualification/Cargo.lock' "$fixture/refusal"
cp Cargo.lock qualification/Cargo.lock
echo '- Rewritten historical note.' >> CHANGELOG.md
if make source-release-check > "$fixture/refusal" 2>&1; then exit 1; fi
grep -F 'preserve the delivered changelog' "$fixture/refusal"
sed '$d' CHANGELOG.md > updated && mv updated CHANGELOG.md
make source-release-check
git add .
git commit -qm 'Prepare private version'
git push -q origin topic
echo '// Continued draft' >> product/src/lib.rs
make source-release-check
git commit -qam 'Extend draft'
git checkout -q main
git merge -q --ff-only topic
if make release-minor > "$fixture/refusal" 2>&1; then exit 1; fi
grep -F 'differs from requested 1.3.0' "$fixture/refusal"
[[ ! -e .git/verified ]]
cat > "$fixture/remote/hooks/pre-receive" <<'HOOK'
#!/bin/sh
exit 1
HOOK
chmod +x "$fixture/remote/hooks/pre-receive"
if make release-patch > "$fixture/first" 2>&1; then exit 1; fi
candidate=$(git rev-parse HEAD)
tag=$(git rev-parse refs/tags/v1.2.4)
[[ $(git cat-file -t "$tag") == tag && $(git rev-parse 'v1.2.4^{commit}') == "$candidate" ]]
[[ $(git --git-dir="$fixture/remote" rev-parse main) == "$delivered" ]]
if git --git-dir="$fixture/remote" show-ref --verify --quiet refs/tags/v1.2.4; then exit 1; fi
mv "$fixture/remote/hooks/pre-receive" "$fixture/rejected-hook"
make release-resume VERSION=1.2.4
[[ $(git --git-dir="$fixture/remote" rev-parse main) == "$candidate" ]]
[[ $(git --git-dir="$fixture/remote" rev-parse refs/tags/v1.2.4) == "$tag" ]]
[[ $(cat .git/verified) == validated ]]
git show "$delivered:CHANGELOG.md" | sed -n '/^## /,$p' > "$fixture/history"
sed -n '/^## \[1.2.3\]/,$p' CHANGELOG.md | cmp - "$fixture/history"
grep -E '^## \[1\.2\.4\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' CHANGELOG.md
# A separate push can consume the next prepared version during interruption.
sed 's/1\.2\.4/1.2.5/' Cargo.toml > updated && mv updated Cargo.toml
sed 's/1\.2\.4/1.2.5/' Cargo.lock > updated && mv updated Cargo.lock
cp Cargo.lock qualification/Cargo.lock
{ printf '# Changelog\n\n## [1.2.5]\n\n- Another batch.\n\n'; sed -n '/^## /,$p' CHANGELOG.md; } > updated
mv updated CHANGELOG.md
git add .
git commit -qm 'Prepare another draft'
draft=$(git rev-parse HEAD)
mv "$fixture/rejected-hook" "$fixture/remote/hooks/pre-receive"
if make release-patch > "$fixture/interrupted" 2>&1; then exit 1; fi
mv "$fixture/remote/hooks/pre-receive" "$fixture/rejected-hook"
git push -q origin "$draft:refs/heads/main"
if make release-resume VERSION=1.2.5 > "$fixture/refusal" 2>&1; then exit 1; fi
grep -F 'delivery branch already reached 1.2.5' "$fixture/refusal"
[[ $(git --git-dir="$fixture/remote" rev-parse main) == "$draft" ]]
if git --git-dir="$fixture/remote" show-ref --verify --quiet refs/tags/v1.2.5; then exit 1; fi
fixture_complete=true
