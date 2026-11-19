#!/usr/bin/env bash
# Shared companions: scripts/ci/check-release-source.sh scripts/ci/finalize-release-changelog.awk scripts/ci/compare-stable-versions.pl
set -euo pipefail
tools="${BASH_SOURCE[0]%/*}"
fail() { echo "private source release: $*" >&2; exit 1; }
[[ $# == 1 ]] || fail 'expected a hook name'
op="$1"
[[ "${RELEASE_DELIVERY:-direct}" == direct && -z ${RELEASE_GROUP:-} ]] || fail 'requires ungrouped direct delivery'
owner="${SOURCE_RELEASE_MANIFEST:?select the product Cargo.toml}"
[[ "$owner" == Cargo.toml || "$owner" == */Cargo.toml ]] || fail 'select a Cargo.toml'
tracked_input() {
    [[ -f "$1" && ! -L "$1" ]] || fail "expected a regular release input: $1"
    git --literal-pathspecs ls-files --error-unmatch -- "$1" >/dev/null || fail "untracked release input: $1"
}
tracked_input "$owner"
version=$(yq -p toml -o json -r '.workspace.package.version' "./$owner")
cutoff="refs/remotes/${RELEASE_REMOTE:?}/${RELEASE_BRANCH:?}"
delivered_version() {
    git show "$cutoff:$owner" | yq -p toml -o json -r '.workspace.package.version'
}
remote_branch() {
    local destination observed
    destination=$(git remote get-url --push "$RELEASE_REMOTE") || return
    observed=$(git ls-remote --exit-code --refs -- "$destination" "refs/heads/$RELEASE_BRANCH") || return
    printf '%s\n' "${observed%%[[:space:]]*}"
}
case "$op" in
    release-version) printf '%s\n' "$version"; exit ;;
    release-base-version) delivered_version; exit ;;
esac

# Check only the local workspace packages in each lock. Registry namesakes
# and separately versioned qualification packages have independent owners.
check_locks() {
    local metadata packages lock
    local -a locks
    read -r -a locks <<< "${SOURCE_RELEASE_LOCKFILES:?select affected Cargo.lock files}"
    metadata=$(cargo metadata --locked --no-deps --format-version 1 --manifest-path "$owner")
    packages=$(jq -ce --arg v "$version" '
        .workspace_members as $ids | [.packages[] | select(.id as $id | $ids | index($id))]
        | select(length > 0 and all(.[]; .publish == [] and .version == $v)) | map(.name)' <<< "$metadata") ||
        fail 'every product workspace member must be private and match the owner version'
    local primary="${owner%Cargo.toml}Cargo.lock" primary_seen=false
    for lock in "${locks[@]}"; do
        tracked_input "$lock"
        if [[ "$lock" == "$primary" ]]; then primary_seen=true; fi
        yq -p toml -o json '.' "./$lock" | jq -e --argjson names "$packages" --arg v "$version" \
            --arg lock "$lock" --arg primary "$primary" '
            [.package[] | select(.source == null and (.name as $n | $names | index($n)))]
            | length > 0 and all(.[]; .version == $v)
              and ($lock != $primary or (map(.name) | sort) == ($names | sort))' >/dev/null ||
            fail "align product versions in $lock with $version"
    done
    [[ "$primary_seen" == true ]] || fail "include product lockfile $primary"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/private-source-release.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
if [[ "$op" == check || "$op" == release-preflight ]]; then
    previous=$(delivered_version) || fail "fetch the delivery branch for $cutoff"
    git show "$cutoff:CHANGELOG.md" > "$tmp/delivered"
    check_locks
    tracked_input CHANGELOG.md
    order=$(perl "$tools/compare-stable-versions.pl" "$version" "$previous")
    if [[ "$order" == 0 ]]; then
        if [[ "$op" == check ]] && git diff --quiet "$cutoff" -- &&
            [[ -z "$(git ls-files --others --exclude-standard)" ]]; then exit 0; fi
        fail "$version already reached $cutoff; prepare the next version and preserve the delivered notes"
    fi
    [[ "$order" == 1 ]] || fail "$version must exceed delivered version $previous"
    # Recheck the actual push destination before authorizing release effects.
    if [[ "$op" == release-preflight ]]; then
        observed=$(remote_branch)
        [[ "$observed" == "$(git rev-parse "$cutoff")" ]] || fail "refresh stale $cutoff before release"
        [[ "$previous" == "${RELEASE_PREVIOUS:?}" ]] || fail 'cutoff changed since release selection'
    fi
    if [[ "$op" == check ]]; then
        cp CHANGELOG.md "$tmp/draft"
    else
        git show "${RELEASE_SOURCE:?}:CHANGELOG.md" > "$tmp/draft"
    fi
    # Compare history from the first delivered heading, including its original suffix.
    perl -0777 -e '
        my ($candidate,$previous,$delivered,$current)=@ARGV;
        sub notes { open my $f,"<",$_[0] or die "$_[0]: $!"; return scalar <$f> }
        my $old=notes($delivered); my $new=notes($current);
        $old =~ s/\A.*?(?=^## )//ms;
        $old =~ /^## \[\Q$previous\E\](?: - (?:Unreleased|\d{4}-\d{2}-\d{2}))?\r?$/m && $-[0] == 0
            or die "delivered version and notes disagree\n";
        $new =~ s/\A(?:(?!^## ).)*^## \[\Q$candidate\E\](?: - Unreleased)?\r?\n//ms
            or die "prepare the pending heading for $candidate\n";
        $new =~ s/\A.*?(?=^## )//ms;
        $new eq $old or die "preserve the delivered changelog beneath the new draft\n";
    ' "$version" "$previous" "$tmp/delivered" "${tmp}/draft"
fi
[[ "$op" != check ]] || exit 0
[[ "$version" == "${RELEASE_VERSION:?}" ]] || fail "prepared owner version $version differs from requested $RELEASE_VERSION"
git show "${RELEASE_SOURCE:?}:CHANGELOG.md" > "$tmp/source"
awk -v version="$version" -v previous="${RELEASE_PREVIOUS:?}" -v date="${RELEASE_DATE:?}" \
    -f "$tools/finalize-release-changelog.awk" "$tmp/source" > "$tmp/final"
case "$op" in
    release-preflight|release-prepare-version)
        bash "$tools/check-release-source.sh" --allow CHANGELOG.md
        git diff --cached --quiet HEAD -- || fail 'unexpected staged metadata'
        cmp -s CHANGELOG.md "$tmp/source" || cmp CHANGELOG.md "$tmp/final"
        if [[ "$op" == release-prepare-version ]]; then
            # A hard interruption must not leave an untracked release input.
            replacement=$(mktemp "$(git rev-parse --git-path release-state)/private-notes.XXXXXX")
            trap 'rm -rf -- "$tmp"; rm -f -- "$replacement"' EXIT
            cp -p CHANGELOG.md "$replacement"
            cat "$tmp/final" > "$replacement"
            perl -e 'rename $ARGV[0], $ARGV[1] or die "atomic changelog replacement: $!\n"' "$replacement" CHANGELOG.md
        fi
        ;;
    release-prepared-check|release-commit-check)
        bash "$tools/check-release-source.sh" --allow CHANGELOG.md
        cmp CHANGELOG.md "$tmp/final"
        if [[ "$op" == release-commit-check ]]; then
            git show :CHANGELOG.md | cmp - "$tmp/final"
            git diff --cached --exit-code "$RELEASE_SOURCE" -- . ':(exclude)CHANGELOG.md'
        fi
        ;;
    release-committed-check|release-tagged-check|release-push-check)
        git diff --exit-code "$RELEASE_SOURCE" "${RELEASE_COMMIT:?}" -- . ':(exclude)CHANGELOG.md'
        git show "$RELEASE_COMMIT:CHANGELOG.md" | cmp - "$tmp/final"
        if [[ "$op" == release-push-check ]]; then
            observed=$(remote_branch)
            # Resume may observe the release already delivered. Otherwise the
            # branch must still be at the previous version, even without a tag.
            if ! git merge-base --is-ancestor "$RELEASE_COMMIT" "$observed"; then
                remote_version=$(git show "$observed:$owner" | yq -p toml -o json -r '.workspace.package.version') ||
                    fail 'cannot read the delivery branch; fetch and reconcile before resuming'
                [[ "$remote_version" == "$RELEASE_PREVIOUS" ]] ||
                    fail "delivery branch already reached $remote_version; reconcile the saved release"
            fi
        fi
        ;;
    *) fail "unknown hook $op" ;;
esac
