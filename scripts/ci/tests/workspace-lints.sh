#!/usr/bin/env bash
# Shared companions: scripts/dev/audit-workspace-lints.pl scripts/ci/fixture-lifecycle.sh
set -euo pipefail
root="${BASH_SOURCE[0]}"
[[ "$root" == /* ]] || root="$PWD/$root"
root="$(CDPATH='' cd -P -- "${root%/*}/../../.." && printf '%s/.' "$PWD")"
root="${root%/.}"
# shellcheck source=scripts/ci/fixture-lifecycle.sh
source "$root/scripts/ci/fixture-lifecycle.sh"
mkdir -p "$root/target"
repo="$(fixture_create "$root/target/lint-audit.XXXXXX")"
fixture_complete=false
trap 'fixture_finish "$?" "$repo" "Workspace lint fixture retained"' EXIT
git -C "$repo" init -q
mkdir -p "$repo"/{product/src,qualification/member/src,vendor/third,generated,history}
for workspace in "$repo" "$repo/qualification"; do
    member=product
    if [[ "$workspace" == "$repo/qualification" ]]; then member=member; fi
    {
        printf '[workspace]\nmembers = ["%s"]\nresolver = "3"\n' "$member"
        sed -n '/^\[lints.cargo\]/,$p' "$root/Cargo.toml" | sed 's/^\[lints\./[workspace.lints./'
    } > "$workspace/Cargo.toml"
    printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2024"\n[lints]\nworkspace = true\n' "$member" > "$workspace/$member/Cargo.toml"
    touch "$workspace/$member/src/lib.rs"
done
for dir in vendor/third generated history; do echo 'invalid toml' > "$repo/$dir/Cargo.toml"; done
git -C "$repo" add Cargo.toml qualification product
audit=(perl "$root/scripts/dev/audit-workspace-lints.pl" --exclude history "$repo")
sed '/^empty_line_after_doc_comments =/d' "$repo/qualification/Cargo.toml" > "$repo/changed"
mv "$repo/changed" "$repo/qualification/Cargo.toml"
status=0
"${audit[@]}" > "$repo/report" || status=$?
[[ "$status" == 1 ]]
grep -Fx 'qualification/Cargo.toml: workspace.lints.clippy.empty_line_after_doc_comments: expected allow, found missing' "$repo/report"
grep -Fx 'Cargo manifests audited: 4. Lint discrepancies: 1.' "$repo/report"
echo 'empty_line_after_doc_comments = "allow"' >> "$repo/qualification/Cargo.toml"
"${audit[@]}"
# An independent single-package workspace can own its lints directly.
mkdir -p "$repo/qualification/standalone/src"
{
    printf '[package]\nname = "standalone"\nversion = "0.1.0"\nedition = "2024"\n[workspace]\n'
    sed -n '/^\[lints.cargo\]/,$p' "$root/Cargo.toml"
} > "$repo/qualification/standalone/Cargo.toml"
touch "$repo/qualification/standalone/src/lib.rs"
"${audit[@]}"
sed 's/unsafe_code = "forbid"/unsafe_code = "warn"/; s/priority = -1/priority = -2/' \
    "$repo/qualification/standalone/Cargo.toml" > "$repo/changed"
mv "$repo/changed" "$repo/qualification/standalone/Cargo.toml"
status=0
"${audit[@]}" > "$repo/report" || status=$?
[[ "$status" == 1 ]]
grep -Fx 'qualification/standalone/Cargo.toml: lints.rust.unsafe_code: expected at least deny, found warn' "$repo/report"
grep -Fx 'qualification/standalone/Cargo.toml: lints.clippy.correctness: priority -2 must exceed all priority -2' "$repo/report"
fixture_complete=true
