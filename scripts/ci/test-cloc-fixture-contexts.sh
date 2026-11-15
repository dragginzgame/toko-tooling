#!/usr/bin/env bash
# Shared companions: scripts/ci/fixture-lifecycle.sh
set -euo pipefail
# Independent fixture admission, with all enclosing consumer selectors present.
ROOT="$0"
[[ "$ROOT" == /* ]] || ROOT="$PWD/$ROOT"
ROOT="$(cd -P "${ROOT%/*}/../.." && printf '%s/.' "$PWD")"
ROOT="${ROOT%/.}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/cloc-fixture-contexts.XXXXXX")"
fixture="$(CDPATH="" cd -P -- "$fixture" && printf '%s/.' "$PWD")"
fixture="${fixture%/.}"
# shellcheck source=scripts/ci/fixture-lifecycle.sh
source "$ROOT/scripts/ci/fixture-lifecycle.sh"
fixture_complete=false
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
finish() {
    local status=$?
    if [[ "$status" != 0 ]]; then
        fixture_replay_logs "$fixture/test-cloc.sh.log" "$fixture/test-cloc-siblings.sh.log" \
            "$fixture/siblings-trailing-slash.log" "$fixture/siblings-directory-alias.log"
    fi
    fixture_finish "$status" "$fixture" "Failed LOC context fixture retained"
}
trap finish EXIT
mkdir -p "$fixture/enclosing/.cargo" "$fixture/enclosing/scratch" "$fixture/output"
git init -q "$fixture/enclosing"
printf '[workspace]\nmembers = []\nresolver = "2"\n' > "$fixture/enclosing/Cargo.toml"
printf '[build]\ntarget-dir = "ancestor-output"\n' > "$fixture/enclosing/.cargo/config.toml"
for script in test-cloc.sh test-cloc-siblings.sh; do
    TMPDIR="$fixture/enclosing/scratch" CARGO_TARGET_DIR="$fixture/output" \
        bash "$ROOT/scripts/ci/$script" > "$fixture/$script.log" 2>&1
done
ln -s "$fixture/enclosing/scratch" "$fixture/scratch-alias"
for context in trailing-slash directory-alias; do
    selected_tmp="$fixture/enclosing/scratch/"
    if [[ "$context" == directory-alias ]]; then selected_tmp="$fixture/scratch-alias/"; fi
    TMPDIR="$selected_tmp" CARGO_TARGET_DIR="$fixture/output" \
        bash "$ROOT/scripts/ci/test-cloc-siblings.sh" > "$fixture/siblings-$context.log" 2>&1
done
echo 'LOC fixtures passed with enclosing Git/Cargo configuration, inherited outputs and physical/aliased TMPDIR roots'
fixture_complete=true
