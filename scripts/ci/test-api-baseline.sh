#!/usr/bin/env bash
# Shared companions: scripts/ci/check-api-baseline.sh scripts/ci/fixture-lifecycle.sh
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
# shellcheck source=scripts/ci/fixture-lifecycle.sh
source "$root/scripts/ci/fixture-lifecycle.sh"
mkdir -p "$root/target/tmp"
fixture=$(fixture_create "$root/target/tmp/api-baseline-test.XXXXXXXX")
fixture_complete=false
trap 'fixture_finish "$?" "$fixture" "API baseline fixture retained"' EXIT
cd "$fixture"
mkdir -p 'reviewed files/nested'
printf 'v1\n' > 'reviewed files/nested/change'
printf 'old\n' > 'reviewed files/removed'
cat > generator <<'GEN'
set -eu
[[ "$2" == 'argument with spaces' && -d "$3" && -z "$(ls -A "$3")" ]]
printf '%s\n' "$3" >> candidates
echo 'consumer output'
case "$1" in
    match) cp -R 'reviewed files/.' "$3" ;;
    drift) mkdir "$3/nested"; echo v2 > "$3/nested/change"; echo new > "$3/.added" ;;
    fail) echo partial > "$3/partial"; exit 37 ;;
esac
GEN
check() {
    bash "$root/scripts/ci/check-api-baseline.sh" 'reviewed files' -- bash generator "$1" 'argument with spaces' > stdout 2> stderr
}
check match
[[ $(cat stdout) == 'consumer output' && ! -e $(tail -1 candidates) ]]
status=0
check drift || status=$?
[[ $status == 1 && $(cat stdout) == 'consumer output' && -d $(tail -1 candidates) ]]
for change in '+v2' '-v1' '-old' '+new'; do grep -Fxq -- "$change" stderr; done
grep -Fq '.added' stderr
status=0
check fail || status=$?
[[ $status == 37 && -f $(tail -1 candidates)/partial ]]
if grep -q '^diff --git' stderr; then exit 1; fi
[[ $(sort -u candidates | wc -l) -eq 3 ]]
fixture_complete=true
