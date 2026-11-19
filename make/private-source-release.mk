# Opt-in hooks for a prepared private Cargo workspace and direct Git delivery.
# Shared companions: scripts/ci/private-source-release.sh make/release.mk
_private_source_root := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))..)
ifndef SHARED_RELEASE_TARGETS
include $(_private_source_root)/make/release.mk
endif
ifneq ($(strip $(RELEASE_GROUP) $(RELEASE_GROUPS) $(RELEASE_PUBLISH_TARGET) $(CARGO_PUBLISH_PACKAGES)),)
$(error Private source delivery requires an ungrouped workspace without a publication roster or target)
endif
_private_source_default_goal := $(.DEFAULT_GOAL)
override RELEASE_VERSION_MODE := pending
export RELEASE_VERSION_MODE
export SOURCE_RELEASE_MANIFEST SOURCE_RELEASE_LOCKFILES
export RELEASE_REMOTE RELEASE_BRANCH
.PHONY: source-release-check release-base-version $(SHARED_RELEASE_TARGETS)
source-release-check:
	@bash "$(_private_source_root)/scripts/ci/private-source-release.sh" check
release-version release-base-version release-preflight release-prepare-version release-prepared-check release-commit-check release-committed-check release-tagged-check release-push-check:
	@bash "$(_private_source_root)/scripts/ci/private-source-release.sh" "$@"
release-files:
	@printf 'CHANGELOG.md\0'
release-verify:
	@test -n "$(strip $(SOURCE_RELEASE_VERIFY))" || { echo 'Set SOURCE_RELEASE_VERIFY to a product validation target' >&2; exit 1; }
	$(_toko_recursive_prefix)@$(_toko_recursive_make) --no-print-directory $(SOURCE_RELEASE_VERIFY)

.DEFAULT_GOAL := $(_private_source_default_goal)
