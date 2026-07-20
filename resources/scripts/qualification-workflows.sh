#!/bin/bash

# Repeated workflow dispatch sourced only by qualification.sh.

run_in_process() {
    local group="$1"
    validate_group "$group"
    local fixture_file selected_group method log_dir started_at status
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
        started_at="$(date +%s)"
        set +e
        DETOURS_QUALIFICATION_REPETITIONS=100 DETOURS_QUALIFICATION_SEED="$QUALIFICATION_SEED" \
            swift test --filter "QualificationWorkflowTests/$method" 2>&1 | tee "$log_dir/$selected_group.log"
        status="${PIPESTATUS[0]}"
        set -e
        record_scenario_timing in-process "$selected_group" all-roots 100 "$started_at" "$status"
        (( status == 0 )) || return "$status"
    done < <(selected_workflow_groups "$group")
}

run_installed() {
    local group="$1"
    validate_group "$group"
    local fixture_file selected_group root_name log_dir result_dir
    fixture_file="$(run_dir)/fixtures.env"
    [[ -f "$fixture_file" ]] || fail "fixture record is missing: $fixture_file"
    set -a
    # shellcheck disable=SC1090
    source "$fixture_file"
    set +a
    log_dir="$(run_dir)/workflows/installed"
    result_dir="$(run_dir)/results/installed"
    mkdir -p "$log_dir" "$result_dir"
    prepare_installed_test_bundle "$log_dir/build-for-testing.log"
    while IFS= read -r selected_group; do
        for root_name in LOCAL_ROOT APFS_ROOT ICLOUD_ROOT SMB_ROOT; do
            run_installed_once \
                "$selected_group" "$root_name" 20 \
                "$log_dir/$selected_group-$root_name" \
                "$result_dir/$selected_group-$root_name.xcresult"
        done
    done < <(selected_workflow_groups "$group")
}

prepare_installed_test_bundle() {
    local log_path="$1"
    local derived_data finder_pid status xctestrun
    local -a candidates=()
    derived_data="$(run_dir)/xcode-derived-data"
    [[ ! -e "$derived_data" ]] || fail "installed-test derived data already exists: $derived_data"
    finder_pid="$(pgrep -x Finder | head -1 || true)"
    [[ "$finder_pid" =~ ^[0-9]+$ ]] || fail "Finder GUI session is unavailable"
    set +e
    launchctl bsexec "$finder_pid" env \
        HOME="$HOME" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        DEVELOPER_DIR="$(xcode-select -p)" \
        xcodebuild build-for-testing \
        -project "$PROJECT_DIR/Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj" \
        -scheme DetoursUITests \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$derived_data" \
        DETOURS_QUALIFICATION_APP_PATH_SETTING=/detours-qualification-canary/app \
        DETOURS_QUALIFICATION_UI_ROOT_SETTING=/detours-qualification-canary/fixture \
        DETOURS_QUALIFICATION_UI_CONTROL_ROOT_SETTING=/detours-qualification-canary/control \
        2>&1 | tee "$log_path"
    status="${PIPESTATUS[0]}"
    set -e
    (( status == 0 )) || return "$status"
    while IFS= read -r candidate; do
        candidates+=("$candidate")
    done < <(find "$derived_data/Build/Products" -maxdepth 1 -type f -name '*.xctestrun' -print)
    (( ${#candidates[@]} == 1 )) || \
        fail "expected one installed-test xctestrun, found ${#candidates[@]}"
    xctestrun="${candidates[0]}"
    [[ "$(plutil -extract TestConfigurations.0.TestTargets.0.EnvironmentVariables.DETOURS_UI_TEST_APP_PATH raw "$xctestrun")" == "/detours-qualification-canary/app" ]] || \
        fail "UI test scheme did not expand the app-path setting"
    [[ "$(plutil -extract TestConfigurations.0.TestTargets.0.EnvironmentVariables.DETOURS_QUALIFICATION_UI_ROOT raw "$xctestrun")" == "/detours-qualification-canary/fixture" ]] || \
        fail "UI test scheme did not expand the fixture-root setting"
    [[ "$(plutil -extract TestConfigurations.0.TestTargets.0.EnvironmentVariables.DETOURS_QUALIFICATION_UI_CONTROL_ROOT raw "$xctestrun")" == "/detours-qualification-canary/control" ]] || \
        fail "UI test scheme did not expand the control-root setting"
    QUALIFICATION_UI_DERIVED_DATA="$derived_data"
    QUALIFICATION_FINDER_PID="$finder_pid"
}

run_installed_once() {
    local selected_group="$1"
    local root_name="$2"
    local repetitions="$3"
    local log_path="$4"
    local result_bundle="$5"
    local test_filter root_path started_at status iteration iteration_bundle
    local control_root
    test_filter="$(installed_test_filter "$selected_group")"
    root_path="${!root_name}"
    [[ -n "${QUALIFICATION_UI_DERIVED_DATA:-}" && -d "$QUALIFICATION_UI_DERIVED_DATA" ]] || \
        fail "installed-test derived data is unavailable"
    [[ "${QUALIFICATION_FINDER_PID:-}" =~ ^[0-9]+$ ]] || fail "Finder GUI session is unavailable"
    printf '%s\t%s\t%s\t%s\n' \
        "$selected_group" "$test_filter" "$root_name" "$repetitions" >> "$(run_dir)/replay.tsv"
    for (( iteration = 1; iteration <= repetitions; iteration++ )); do
        if (( repetitions == 1 )); then
            iteration_bundle="$result_bundle"
        else
            printf -v iteration_bundle '%s-iteration-%03d.xcresult' "${result_bundle%.xcresult}" "$iteration"
        fi
        [[ ! -e "$iteration_bundle" ]] || fail "result bundle already exists: $iteration_bundle"
        control_root="$HOME/Library/Containers/MAF.DetoursUITests.xctrunner/Data/DetoursQualification/$QUALIFICATION_COMMIT/$QUALIFICATION_RUN_ID/$selected_group-$root_name-$iteration"
        mkdir -p "$control_root"
        printf 'qualification: installed %s %s iteration %d/%d\n' \
            "$selected_group" "$root_name" "$iteration" "$repetitions" | tee -a "$log_path.log"
        started_at="$(date +%s)"
        set +e
        launchctl bsexec "$QUALIFICATION_FINDER_PID" env \
                HOME="$HOME" \
                PATH=/usr/bin:/bin:/usr/sbin:/sbin \
                DEVELOPER_DIR="$(xcode-select -p)" \
                xcodebuild test \
                -project "$PROJECT_DIR/Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj" \
                -scheme DetoursUITests \
                -destination 'platform=macOS,arch=arm64' \
                -derivedDataPath "$QUALIFICATION_UI_DERIVED_DATA" \
                -only-testing:"DetoursUITests/$test_filter" \
                "DETOURS_QUALIFICATION_APP_PATH_SETTING=$PROJECT_DIR/build/Detours.app" \
                "DETOURS_QUALIFICATION_UI_ROOT_SETTING=$root_path" \
                "DETOURS_QUALIFICATION_UI_CONTROL_ROOT_SETTING=$control_root" \
                -resultBundlePath "$iteration_bundle" 2>&1 | tee -a "$log_path.log"
        status="${PIPESTATUS[0]}"
        set -e
        record_scenario_timing \
            installed "$selected_group" "$root_name-iteration-$iteration" 1 "$started_at" "$status"
        (( status == 0 )) || return "$status"
    done
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
        activation) printf 'QualificationActivationUITests/testPaneAndTabStateSurvivesReturnFromFinder\n' ;;
        refresh) printf 'FolderExpansionUITests/testSelectionAndFocusPreservedAfterMenuRefresh\n' ;;
        transfer) printf 'RefreshAuthorityUITests/testF5CopyActivatesDestinationPaneAndSelectsCopy\n' ;;
        mutation) printf 'NewFolderUITests/testNewFolderSelectsNewFolderNotExisting\n' ;;
        connection) printf 'RemoteQuickOpenUITests/testDelayedRealConnectionLoadsPaneCapturedBeforeFocusSwitch\n' ;;
        archive) printf 'ArchivePasswordUITests/testCreationControlsFollowSelectedFormat\n' ;;
        session) printf 'WindowPaneGeometryUITests/testPaneDividerDragPersistsAcrossRelaunch\n' ;;
        opening) printf 'RemoteQuickOpenUITests/testEnterAndCommandOpenDispatchAllSelectedFiles\n' ;;
    esac
}
