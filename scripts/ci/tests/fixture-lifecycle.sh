#!/usr/bin/env bash
# Shared companions: scripts/ci/fixture-lifecycle.sh
set -euo pipefail
ROOT="${BASH_SOURCE[0]}"
[[ "$ROOT" == /* ]] || ROOT="$PWD/$ROOT"
ROOT="$(CDPATH='' cd -P -- "${ROOT%/*}/../../.." && printf '%s/.' "$PWD")"
ROOT="${ROOT%/.}"
# shellcheck source=scripts/ci/fixture-lifecycle.sh
source "$ROOT/scripts/ci/fixture-lifecycle.sh"
[[ $# -le 1 ]] || exit 2
selection="${1:-all}"
case "$selection" in all|allocation|completion|log-replay) ;; *) exit 2 ;; esac
fixture="$(fixture_create "${TMPDIR:-/tmp}/fixture-lifecycle.XXXXXX")"
fixture_complete=false
trap 'fixture_finish "$?" "$fixture" "Lifecycle fixture retained"' EXIT

test_allocation() {
    mkdir "$fixture/physical root"
    ln -s "$fixture/physical root" "$fixture/alias"
    allocated="$(CDPATH=/ fixture_create "$fixture/alias/child.XXXXXX")"
    [[ "$allocated" == "$fixture/physical root/child."* && -d "$allocated" ]] || exit 1
    (
        cd "$fixture/physical root"
        relative="$(fixture_create 'relative.XXXXXX')"
        [[ "$relative" == "$PWD/relative."* && -d "$relative" ]] || exit 1
        rm -r "$relative"
    )
    status=0
    fixture_create > "$fixture/no-input" 2>&1 || status=$?
    [[ "$status" == 2 && ! -s "$fixture/no-input" ]] || exit 1
    for invalid in '' '--help' "$fixture/line"$'\n'"break.XXXXXX" "$fixture/line"$'\r'"break.XXXXXX"; do
        status=0
        fixture_create "$invalid" > "$fixture/invalid" 2>&1 || status=$?
        [[ "$status" == 2 && ! -s "$fixture/invalid" ]] || exit 1
    done
    # A safe alias must not hide a forbidden physical parent. Retain any allocation;
    # never normalize the path by deleting the offending byte.
    mkdir "$fixture/physical"$'\n'"parent"
    ln -s "$fixture/physical"$'\n'"parent" "$fixture/bad-alias"
    status=0
    fixture_create "$fixture/bad-alias/child.XXXXXX" > "$fixture/physical-output" 2> "$fixture/physical-error" || status=$?
    [[ "$status" == 2 && ! -s "$fixture/physical-output" ]] || exit 1
    set -- "$fixture/bad-alias"/child.*
    [[ $# == 1 && -d "$1" ]] || exit 1
    grep -F 'allocation retained:' "$fixture/physical-error" >/dev/null
    # A failing allocator cannot trigger normalization or lose its exact status.
    status=0
    (
        # shellcheck disable=SC2329 # Called indirectly by fixture_create.
        mktemp() { printf 'allocator-detail\n' >&2; return 49; }
        # shellcheck disable=SC2329 # Called indirectly by fixture_create.
        cd() { printf 'normalization-dispatched\n' >&2; return 51; }
        fixture_create "$fixture/unused.XXXXXX"
    ) > "$fixture/allocate-failure" 2>&1 || status=$?
    [[ "$status" == 49 ]] || exit 1
    grep -Fx 'allocator-detail' "$fixture/allocate-failure" >/dev/null
    ! grep -F 'normalization-dispatched' "$fixture/allocate-failure" >/dev/null || exit 1
    # Allocation succeeded but normalization failed: bytes/path remain caller-owned.
    retained="$(mktemp -d "$fixture/retained.XXXXXX")"
    printf 'original evidence\n' > "$retained/evidence"
    status=0
    (
        # shellcheck disable=SC2329 # Called indirectly by fixture_create.
        mktemp() { printf '%s\n' "$retained"; }
        # shellcheck disable=SC2329 # Called indirectly by fixture_create.
        cd() { return 37; }
        fixture_create "$fixture/unused.XXXXXX"
    ) > "$fixture/normalize-failure" 2>&1 || status=$?
    [[ "$status" == 37 && -d "$retained" ]] || exit 1
    grep -Fx "Fixture allocation retained: $retained" "$fixture/normalize-failure" >/dev/null
    grep -Fx 'original evidence' "$retained/evidence" >/dev/null
    # The selected directory stays anchored after the caller changes cwd.
    (
        cd /
        [[ -d "$allocated" ]] || exit 1
    )
}

test_completion() {
    for complete in false true; do
        for original in 0 1 37 49 137 255; do
            expected="$original"
            [[ "$complete" == true || "$original" != 0 ]] || expected=1
            actual=0
            fixture_completion_status "$original" "$complete" || actual=$?
            [[ "$actual" == "$expected" ]] || exit 1
        done
    done
    for invalid in '' -1 256 512 01 invalid 999999999999999999999; do
        actual=0
        fixture_completion_status "$invalid" true || actual=$?
        [[ "$actual" == 2 ]] || exit 1
    done
    actual=0
    fixture_completion_status || actual=$?
    [[ "$actual" == 2 ]] || exit 1
    # Execute the EXIT contract with no cleanup, including function-level nounset.
    cat > "$fixture/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
source "$COMPLETION_SOURCE/scripts/ci/fixture-lifecycle.sh"
complete=false
status=0
trap 'status=$?; fixture_completion_status "$status" "$complete" || status=$?; exit "$status"' EXIT
printf 'retained live evidence\n' > "$COMPLETION_EVIDENCE"
case "$1" in
    success) complete=true ;;
    incomplete) exit 0 ;;
    failed) exit 49 ;;
    completed-failed) complete=true; exit 37 ;;
    nounset) incomplete_function() { printf '%s\n' "$MISSING_COMPLETION_VARIABLE"; }; incomplete_function ;;
esac
RUNNER
    unset MISSING_COMPLETION_VARIABLE
    export COMPLETION_SOURCE="$ROOT" COMPLETION_EVIDENCE="$fixture/evidence"
    for scenario in success incomplete failed completed-failed nounset; do
        expected=1
        case "$scenario" in success) expected=0 ;; failed) expected=49 ;; completed-failed) expected=37 ;; esac
        status=0
        "$BASH" "$fixture/runner.sh" "$scenario" > "$fixture/$scenario.log" 2>&1 || status=$?
        [[ "$status" == "$expected" ]] || exit 1
        grep -Fx 'retained live evidence' "$COMPLETION_EVIDENCE" >/dev/null
    done
}

test_log_replay() {
    mkdir "$fixture/directory" "$fixture/bin"
    first="$fixture/first log"
    last="$fixture/last"$'\n'"log"
    printf 'first without newline' > "$first"
    printf 'last\n' > "$last"
    cat "$first" "$last" > "$fixture/expected"
    fixture_replay_logs "$fixture/missing" "$first" "$fixture/directory" "$last" \
        > "$fixture/stdout" 2> "$fixture/stderr"
    [[ ! -s "$fixture/stdout" ]] || exit 1
    cmp "$fixture/expected" "$fixture/stderr"
    fixture_replay_logs > "$fixture/empty-out" 2> "$fixture/empty-err"
    [[ ! -s "$fixture/empty-out" && ! -s "$fixture/empty-err" ]] || exit 1

    # A failed reader must not mask a caller's saved status or stop later readback.
    real_cat="$(command -v cat)"
    export REPLAY_REAL_CAT="$real_cat" REPLAY_FAILED_LOG="$first"
    printf '#!%s\n' "$BASH" > "$fixture/bin/cat"
    cat >> "$fixture/bin/cat" <<'CAT'
if [[ "$2" == "$REPLAY_FAILED_LOG" ]]; then
    printf 'partial diagnostic\n'
    exit 43
fi
exec "$REPLAY_REAL_CAT" "$@"
CAT
    chmod +x "$fixture/bin/cat"
    printf 'partial diagnostic\n' > "$fixture/failed-expected"
    cat "$last" >> "$fixture/failed-expected"
    PATH="$fixture/bin:$PATH" fixture_replay_logs "$first" "$last" \
        > "$fixture/failed-out" 2> "$fixture/failed-err"
    [[ ! -s "$fixture/failed-out" ]] || exit 1
    cmp "$fixture/failed-expected" "$fixture/failed-err"
    status=0
    (
        saved=0
        export PATH="$fixture/bin:$PATH"
        trap 'saved=$?; fixture_replay_logs "$REPLAY_FAILED_LOG"; exit "$saved"' EXIT
        exit 49
    ) > "$fixture/trap-out" 2> "$fixture/trap-err" || status=$?
    [[ "$status" == 49 && ! -s "$fixture/trap-out" ]] || exit 1
    printf 'partial diagnostic\n' > "$fixture/trap-expected"
    cmp "$fixture/trap-expected" "$fixture/trap-err"
    (exec 2>&-; fixture_replay_logs "$first")
    [[ -f "$first" && -f "$last" && -d "$fixture/directory" ]] || exit 1
}

if [[ "$selection" == all || "$selection" == allocation ]]; then test_allocation; fi
if [[ "$selection" == all || "$selection" == completion ]]; then test_completion; fi
if [[ "$selection" == all || "$selection" == log-replay ]]; then test_log_replay; fi
fixture_complete=true
echo "Lifecycle fixture passed ($selection)"
