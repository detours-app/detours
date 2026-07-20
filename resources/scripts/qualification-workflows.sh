#!/bin/bash

# Repeated workflow dispatch sourced only by qualification.sh.

run_in_process() {
    local group="$1"
    validate_group "$group"
    local fixture_file selected_group method log_dir
    fixture_file="$(run_dir)/fixtures.env"
    [[ -f "$fixture_file" ]] || fail "fixture record is missing: $fixture_file"
    set -a
    # shellcheck disable=SC1090
    source "$fixture_file"
    set +a
    log_dir="$(run_dir)/workflows/in-process"
    mkdir -p "$log_dir"
    while IFS= read -r selected_group; do
        method="$(in_process_method "$selected_group")"
        printf '%s\t%s\t100\n' "$selected_group" "$method" >> "$(run_dir)/replay.tsv"
        DETOURS_QUALIFICATION_REPETITIONS=100 DETOURS_QUALIFICATION_SEED="$QUALIFICATION_SEED" \
            swift test --filter "QualificationWorkflowTests/$method" 2>&1 | tee "$log_dir/$selected_group.log"
    done < <(selected_workflow_groups "$group")
}

run_installed() {
    local group="$1"
    validate_group "$group"
    local fixture_file selected_group root_name log_dir
    fixture_file="$(run_dir)/fixtures.env"
    [[ -f "$fixture_file" ]] || fail "fixture record is missing: $fixture_file"
    set -a
    # shellcheck disable=SC1090
    source "$fixture_file"
    set +a
    log_dir="$(run_dir)/workflows/installed"
    mkdir -p "$log_dir"
    while IFS= read -r selected_group; do
        for root_name in LOCAL_ROOT APFS_ROOT ICLOUD_ROOT SMB_ROOT; do
            run_installed_once "$selected_group" "$root_name" 20 "$log_dir/$selected_group-$root_name"
        done
    done < <(selected_workflow_groups "$group")
}

run_installed_once() {
    local selected_group="$1"
    local root_name="$2"
    local repetitions="$3"
    local evidence_prefix="$4"
    local test_filter root_path result_bundle
    test_filter="$(installed_test_filter "$selected_group")"
    root_path="${!root_name}"
    result_bundle="$evidence_prefix.xcresult"
    [[ ! -e "$result_bundle" ]] || fail "result bundle already exists: $result_bundle"
    printf '%s\t%s\t%s\t%s\n' \
        "$selected_group" "$test_filter" "$root_name" "$repetitions" >> "$(run_dir)/replay.tsv"
    DETOURS_UI_TEST_APP_PATH="$PROJECT_DIR/build/Detours.app" \
    DETOURS_QUALIFICATION_UI_ROOT="$root_path" \
        xcodebuild test \
            -project "$PROJECT_DIR/Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj" \
            -scheme DetoursUITests \
            -destination 'platform=macOS,arch=arm64' \
            -only-testing:"DetoursUITests/$test_filter" \
            -test-iterations "$repetitions" \
            -resultBundlePath "$result_bundle" 2>&1 | tee "$evidence_prefix.log"
}

selected_workflow_groups() {
    local requested="$1"
    if [[ "$requested" != "all" ]]; then
        printf '%s\n' "$requested"
        return
    fi
    while IFS= read -r candidate; do
        printf '%s %s\n' "$(printf '%s:%s' "$QUALIFICATION_SEED" "$candidate" | shasum -a 256 | cut -d' ' -f1)" "$candidate"
    done < <(workflow_groups) | sort | cut -d' ' -f2
}

in_process_method() {
    case "$1" in
        activation) printf 'testActivationWorkflow\n' ;;
        refresh) printf 'testRefreshWorkflow\n' ;;
        transfer) printf 'testTransferWorkflow\n' ;;
        mutation) printf 'testMutationWorkflow\n' ;;
        connection) printf 'testConnectionWorkflow\n' ;;
        archive) printf 'testArchiveWorkflow\n' ;;
        session) printf 'testSessionWorkflow\n' ;;
        opening) printf 'testOpeningWorkflow\n' ;;
    esac
}

installed_test_filter() {
    case "$1" in
        activation) printf 'FolderExpansionUITests/testActivePanePreservedOnRelaunch\n' ;;
        refresh) printf 'FolderExpansionUITests/testSelectionAndFocusPreservedAfterMenuRefresh\n' ;;
        transfer) printf 'RefreshAuthorityUITests/testF5CopyActivatesDestinationPaneAndSelectsCopy\n' ;;
        mutation) printf 'NewFolderUITests/testNewFolderSelectsNewFolderNotExisting\n' ;;
        connection) printf 'RemoteQuickOpenUITests/testDelayedRealConnectionLoadsPaneCapturedBeforeFocusSwitch\n' ;;
        archive) printf 'ArchivePasswordUITests/testCreationControlsFollowSelectedFormat\n' ;;
        session) printf 'WindowPaneGeometryUITests/testPaneDividerDragPersistsAcrossRelaunch\n' ;;
        opening) printf 'RemoteQuickOpenUITests/testEnterAndCommandOpenDispatchAllSelectedFiles\n' ;;
    esac
}
