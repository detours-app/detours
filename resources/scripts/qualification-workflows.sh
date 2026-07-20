#!/bin/bash

# Repeated workflow dispatch sourced only by qualification.sh.

run_gui_command() {
    local log_path="$1"
    shift
    local label status_path status_tmp launch_stdout launch_stderr job_state command_status
    local attempt
    path_is_within "$log_path" "$(run_dir)" || fail "GUI command log escapes the run directory"
    status_path="$log_path.status"
    status_tmp="$status_path.tmp"
    launch_stdout="$log_path.launch-stdout"
    launch_stderr="$log_path.launch-stderr"
    for path in "$log_path" "$status_path" "$status_tmp" "$launch_stdout" "$launch_stderr"; do
        [[ ! -e "$path" ]] || fail "GUI command artifact already exists: $path"
    done
    label="com.detours.qualification.$(uuidgen)"
    launchctl submit \
        -l "$label" \
        -o "$launch_stdout" \
        -e "$launch_stderr" \
        -- "$SCRIPT_DIR/qualification-gui-command.sh" "$log_path" "$status_path" "$@"
    job_state=""
    for (( attempt = 1; attempt <= 9000; attempt++ )); do
        if [[ -f "$status_path" ]]; then
            break
        fi
        job_state="$(launchctl print "gui/$(id -u)/$label" 2>&1 || true)"
        [[ -n "$job_state" ]] || fail "GUI qualification job disappeared: $label"
        case "$job_state" in
            *"last exit code"*)
                launchctl remove "$label" 2>/dev/null || true
                fail "GUI qualification wrapper exited without writing status: $label"
                ;;
        esac
        sleep 0.1
    done
    if [[ ! -f "$status_path" ]]; then
        launchctl remove "$label" 2>/dev/null || true
        fail "GUI qualification job timed out: $label"
    fi
    command_status="$(cat "$status_path")"
    [[ "$command_status" =~ ^[0-9]+$ ]] || fail "GUI qualification job wrote an invalid status"
    launchctl remove "$label" 2>/dev/null || true
    if [[ -s "$launch_stdout" ]]; then
        cat "$launch_stdout"
    fi
    if [[ -s "$launch_stderr" ]]; then
        cat "$launch_stderr" >&2
    fi
    cat "$log_path"
    return "$command_status"
}

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
        if [[ "$selected_group" == "activation" ]]; then
            local target_name remote_target
            for target_name in LINUX_TARGET INTEL_MAC_TARGET WINDOWS_TARGET; do
                remote_target="${!target_name}"
                [[ -n "$remote_target" ]] || fail "remote activation target is missing: $target_name"
                run_installed_once \
                    "$selected_group" LOCAL_ROOT 20 \
                    "$log_dir/$selected_group-$target_name" \
                    "$result_dir/$selected_group-$target_name.xcresult" \
                    "$remote_target" "$target_name"
            done
        fi
    done < <(selected_workflow_groups "$group")
}

prepare_installed_test_bundle() {
    local log_path="$1"
    local derived_data status xctestrun
    local -a candidates=()
    derived_data="$(run_dir)/xcode-derived-data"
    [[ ! -e "$derived_data" ]] || fail "installed-test derived data already exists: $derived_data"
    pgrep -x Finder >/dev/null 2>&1 || fail "Finder GUI session is unavailable"
    set +e
    run_gui_command "$log_path.raw" env \
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
        DETOURS_QUALIFICATION_REAL_REMOTE_TARGET_SETTING=detours-qualification-canary-target \
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
    [[ "$(plutil -extract TestConfigurations.0.TestTargets.0.EnvironmentVariables.DETOURS_QUALIFICATION_REAL_REMOTE_TARGET raw "$xctestrun")" == "detours-qualification-canary-target" ]] || \
        fail "UI test scheme did not expand the remote-target setting"
    QUALIFICATION_UI_DERIVED_DATA="$derived_data"
}

stop_installed_app() {
    local attempt
    pkill -x Detours >/dev/null 2>&1 || true
    for (( attempt = 1; attempt <= 50; attempt++ )); do
        pgrep -x Detours >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    fail "Detours did not stop between installed qualification iterations"
}

run_installed_once() {
    local selected_group="$1"
    local root_name="$2"
    local repetitions="$3"
    local log_path="$4"
    local result_bundle="$5"
    local test_filter root_path started_at status iteration iteration_bundle
    local control_root remote_target context_name
    remote_target="${6:-}"
    context_name="${7:-$root_name}"
    test_filter="$(installed_test_filter "$selected_group")"
    root_path="${!root_name}"
    [[ -n "${QUALIFICATION_UI_DERIVED_DATA:-}" && -d "$QUALIFICATION_UI_DERIVED_DATA" ]] || \
        fail "installed-test derived data is unavailable"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$selected_group" "$test_filter" "$context_name" "$repetitions" "$remote_target" >> "$(run_dir)/replay.tsv"
    for (( iteration = 1; iteration <= repetitions; iteration++ )); do
        stop_installed_app
        if (( repetitions == 1 )); then
            iteration_bundle="$result_bundle"
        else
            printf -v iteration_bundle '%s-iteration-%03d.xcresult' "${result_bundle%.xcresult}" "$iteration"
        fi
        [[ ! -e "$iteration_bundle" ]] || fail "result bundle already exists: $iteration_bundle"
        control_root="$HOME/Library/Containers/MAF.DetoursUITests.xctrunner/Data/DetoursQualification/$QUALIFICATION_COMMIT/$QUALIFICATION_RUN_ID/$selected_group-$context_name-$iteration"
        mkdir -p "$control_root"
        printf 'qualification: installed %s %s iteration %d/%d\n' \
            "$selected_group" "$context_name" "$iteration" "$repetitions" | tee -a "$log_path.log"
        started_at="$(date +%s)"
        set +e
        run_gui_command "$log_path-iteration-$iteration.raw.log" env \
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
                "DETOURS_QUALIFICATION_REAL_REMOTE_TARGET_SETTING=$remote_target" \
                -resultBundlePath "$iteration_bundle" 2>&1 | tee -a "$log_path.log"
        status="${PIPESTATUS[0]}"
        set -e
        stop_installed_app
        record_scenario_timing \
            installed "$selected_group" "$context_name-iteration-$iteration" 1 "$started_at" "$status"
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
