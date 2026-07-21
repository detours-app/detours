#!/bin/bash

# Repeated workflow dispatch sourced only by qualification.sh.

run_gui_command() {
    local log_path="$1"
    shift
    local label status_path status_tmp launch_stdout launch_stderr job_state command_status
    local attempt exited_without_status_at active_job_file
    path_is_within "$log_path" "$(run_dir)" || fail "GUI command log escapes the run directory"
    status_path="$log_path.status"
    status_tmp="$status_path.tmp"
    launch_stdout="$log_path.launch-stdout"
    launch_stderr="$log_path.launch-stderr"
    for path in "$log_path" "$status_path" "$status_tmp" "$launch_stdout" "$launch_stderr"; do
        [[ ! -e "$path" ]] || fail "GUI command artifact already exists: $path"
    done
    label="com.detours.qualification.$(uuidgen)"
    active_job_file="$(run_dir)/active-gui-job"
    [[ ! -e "$active_job_file" ]] || fail "another GUI qualification job is already recorded"
    printf '%s\n' "$label" > "$active_job_file"
    trap 'launchctl remove "$label" 2>/dev/null || true; rm -f -- "$active_job_file"; exit 130' HUP INT TERM
    exited_without_status_at=0
    if ! launchctl submit \
        -l "$label" \
        -o "$launch_stdout" \
        -e "$launch_stderr" \
        -- "$SCRIPT_DIR/qualification-gui-command.sh" "$log_path" "$status_path" "$@"; then
        rm -f -- "$active_job_file"
        trap - HUP INT TERM
        fail "GUI qualification job could not be submitted: $label"
    fi
    job_state=""
    for (( attempt = 1; attempt <= 9000; attempt++ )); do
        if [[ -f "$status_path" ]]; then
            break
        fi
        if ! job_state="$(launchctl print "gui/$(id -u)/$label" 2>&1)"; then
            rm -f -- "$active_job_file"
            fail "GUI qualification job disappeared: $label"
        fi
        [[ -n "$job_state" ]] || {
            rm -f -- "$active_job_file"
            fail "GUI qualification job disappeared: $label"
        }
        if [[ "$job_state" =~ last\ exit\ code\ =\ -?[0-9]+ ]] \
            || [[ "$job_state" =~ last\ terminating\ signal\ =\ [0-9]+ ]]; then
            if (( exited_without_status_at == 0 )); then
                exited_without_status_at="$attempt"
            elif (( attempt - exited_without_status_at >= 10 )); then
                launchctl remove "$label" 2>/dev/null || true
                rm -f -- "$active_job_file"
                fail "GUI qualification wrapper exited without writing status: $label"
            fi
        fi
        sleep 0.1
    done
    if [[ ! -f "$status_path" ]]; then
        launchctl remove "$label" 2>/dev/null || true
        rm -f -- "$active_job_file"
        fail "GUI qualification job timed out: $label"
    fi
    command_status="$(cat "$status_path")"
    if [[ ! "$command_status" =~ ^[0-9]+$ ]]; then
        launchctl remove "$label" 2>/dev/null || true
        rm -f -- "$active_job_file"
        trap - HUP INT TERM
        fail "GUI qualification job wrote an invalid status"
    fi
    launchctl remove "$label" 2>/dev/null || true
    rm -f -- "$active_job_file"
    trap - HUP INT TERM
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
    verify_smb_fixture_session_access 0
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
    if [[ -n "${SMB_ROOT:-}" ]]; then
        verify_smb_fixture_session_access
    fi
    log_dir="$(run_dir)/workflows/installed"
    result_dir="$(run_dir)/results/installed"
    mkdir -p "$log_dir" "$result_dir"
    prepare_installed_test_bundle "$log_dir/build-for-testing.log"
    while IFS= read -r selected_group; do
        while IFS= read -r root_name; do
            run_installed_once \
                "$selected_group" "$root_name" 20 \
                "$log_dir/$selected_group-$root_name" \
                "$result_dir/$selected_group-$root_name.xcresult"
        done < <(installed_root_contexts "$selected_group")
        if installed_group_uses_remote_targets "$selected_group"; then
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

run_installed_smoke() {
    local group="$1"
    local context_name="$2"
    local repetitions="$3"
    local fixture_file log_dir result_dir remote_target
    fixture_file="$(run_dir)/fixtures.env"
    [[ -f "$fixture_file" ]] || fail "fixture record is missing: $fixture_file"
    set -a
    # shellcheck disable=SC1090
    source "$fixture_file"
    set +a
    if [[ -n "${SMB_ROOT:-}" ]]; then
        verify_smb_fixture_session_access
    fi
    installed_contexts "$group" | grep -Fx "$context_name" >/dev/null || \
        fail "$context_name is not an applicable installed context for $group"
    log_dir="$(run_dir)/workflows/installed-smoke"
    result_dir="$(run_dir)/results/installed-smoke"
    mkdir -p "$log_dir" "$result_dir"
    prepare_installed_test_bundle "$log_dir/build-for-testing.log"
    case "$context_name" in
        LOCAL_ROOT|APFS_ROOT|ICLOUD_ROOT|SMB_ROOT)
            run_installed_once \
                "$group" "$context_name" "$repetitions" \
                "$log_dir/$group-$context_name" \
                "$result_dir/$group-$context_name.xcresult"
            ;;
        LINUX_TARGET|INTEL_MAC_TARGET|WINDOWS_TARGET)
            remote_target="${!context_name}"
            [[ -n "$remote_target" ]] || fail "remote smoke target is missing: $context_name"
            run_installed_once \
                "$group" LOCAL_ROOT "$repetitions" \
                "$log_dir/$group-$context_name" \
                "$result_dir/$group-$context_name.xcresult" \
                "$remote_target" "$context_name"
            ;;
    esac
}

prepare_installed_test_bundle() {
    local log_path="$1"
    local derived_data status xctestrun
    local -a candidates=()
    derived_data="$(run_dir)/xcode-derived-data"
    [[ ! -e "$derived_data" ]] || fail "installed-test derived data already exists: $derived_data"
    pgrep -x Finder >/dev/null 2>&1 || fail "Finder GUI session is unavailable"
    require_command jq
    require_command xcrun
    set +e
    run_gui_command "$log_path.raw" env \
        HOME="$HOME" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        DEVELOPER_DIR="$(xcode-select -p)" \
        xcodebuild build-for-testing -quiet \
        -project "$PROJECT_DIR/Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj" \
        -scheme DetoursUITests \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$derived_data" \
        DETOURS_QUALIFICATION_APP_PATH_SETTING=/detours-qualification-canary/app \
        DETOURS_QUALIFICATION_UI_ROOT_SETTING=/detours-qualification-canary/fixture \
        DETOURS_QUALIFICATION_UI_CONTROL_ROOT_SETTING=/detours-qualification-canary/control \
        DETOURS_QUALIFICATION_REAL_REMOTE_TARGET_SETTING=detours-qualification-canary-target \
        DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT_SETTING=detours-qualification-canary-context \
        DETOURS_QUALIFICATION_REPETITIONS_SETTING=1 \
        > "$log_path" 2>&1
    status="$?"
    set -e
    cat "$log_path"
    (( status == 0 )) || return "$status"
    verify_quiet_xcode_command "$log_path.raw"
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
    [[ "$(plutil -extract TestConfigurations.0.TestTargets.0.EnvironmentVariables.DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT raw "$xctestrun")" == "detours-qualification-canary-context" ]] || \
        fail "UI test scheme did not expand the remote-context setting"
    [[ "$(plutil -extract TestConfigurations.0.TestTargets.0.EnvironmentVariables.DETOURS_QUALIFICATION_REPETITIONS raw "$xctestrun")" == "1" ]] || \
        fail "UI test scheme did not expand the repetition setting"
    QUALIFICATION_UI_DERIVED_DATA="$derived_data"
}

verify_quiet_xcode_command() {
    local command_log="$1"
    local artifact
    for artifact in "$command_log" "$command_log.launch-stdout" "$command_log.launch-stderr"; do
        [[ -e "$artifact" ]] || fail "Xcode command artifact is missing: $artifact"
        [[ ! -s "$artifact" ]] || fail "successful quiet Xcode command emitted unexpected output: $artifact"
    done
}

verify_installed_result_bundle() {
    local result_bundle="$1"
    local summary_path total passed failed skipped expected result
    local device_passed device_failed device_skipped
    [[ -d "$result_bundle" ]] || fail "installed-test result bundle is missing: $result_bundle"
    summary_path="${result_bundle%.xcresult}-summary.json"
    [[ ! -e "$summary_path" ]] || fail "installed-test result summary already exists: $summary_path"
    xcrun xcresulttool get test-results summary --compact --path "$result_bundle" > "$summary_path"
    jq -e . "$summary_path" >/dev/null || fail "installed-test result summary is invalid JSON"
    total="$(jq -r '.totalTestCount // empty' "$summary_path")"
    passed="$(jq -r '.passedTests // empty' "$summary_path")"
    failed="$(jq -r '.failedTests // empty' "$summary_path")"
    skipped="$(jq -r '.skippedTests // empty' "$summary_path")"
    expected="$(jq -r '.expectedFailures // empty' "$summary_path")"
    result="$(jq -r '.result // empty' "$summary_path")"
    [[ "$total" == "1" ]] || fail "installed workflow ran $total logical tests instead of exactly one"
    [[ "$passed" == "1" ]] || fail "installed workflow passed $passed logical tests instead of exactly one"
    [[ "$failed" == "0" ]] || fail "installed iteration recorded $failed failed tests"
    [[ "$skipped" == "0" ]] || fail "installed iteration recorded $skipped skipped tests"
    [[ "$expected" == "0" ]] || fail "installed iteration recorded $expected expected failures"
    [[ "$result" == "Passed" ]] || fail "installed iteration result is not Passed: $result"

    device_passed="$(jq '[.devicesAndConfigurations[].passedTests] | add // 0' "$summary_path")"
    device_failed="$(jq '[.devicesAndConfigurations[].failedTests] | add // 0' "$summary_path")"
    device_skipped="$(jq '[.devicesAndConfigurations[].skippedTests] | add // 0' "$summary_path")"
    [[ "$device_passed" == "1" ]] || \
        fail "installed workflow passed $device_passed logical tests instead of exactly one"
    [[ "$device_failed" == "0" ]] || fail "installed workflow recorded $device_failed failed repetitions"
    [[ "$device_skipped" == "0" ]] || fail "installed workflow recorded $device_skipped skipped repetitions"
}

verify_workflow_repetition_markers() {
    local group="$1"
    local control_root="$2"
    local expected_count="$3"
    local actual_count iteration marker recorded_iteration recorded_total
    actual_count="$(find "$control_root" -maxdepth 1 -type f \
        -name ".detours-qualification-$group-repetition-*.json" | wc -l | tr -d '[:space:]')"
    [[ "$actual_count" == "$expected_count" ]] || \
        fail "$group workflow recorded $actual_count completed repetitions instead of $expected_count"
    for (( iteration = 1; iteration <= expected_count; iteration++ )); do
        printf -v marker '%s/.detours-qualification-%s-repetition-%03d.json' \
            "$control_root" "$group" "$iteration"
        [[ -f "$marker" ]] || fail "$group repetition marker is missing: $marker"
        recorded_iteration="$(plutil -extract iteration raw -o - "$marker")"
        recorded_total="$(plutil -extract total raw -o - "$marker")"
        [[ "$recorded_iteration" == "$iteration" ]] || \
            fail "$group repetition marker has the wrong iteration: $marker"
        [[ "$recorded_total" == "$expected_count" ]] || \
            fail "$group repetition marker has the wrong total: $marker"
    done
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
    local test_filter root_path started_at status command_output
    local control_root remote_target context_name
    remote_target="${6:-}"
    context_name="${7:-$root_name}"
    test_filter="$(installed_test_filter "$selected_group")"
    root_path="${!root_name}"
    [[ -n "${QUALIFICATION_UI_DERIVED_DATA:-}" && -d "$QUALIFICATION_UI_DERIVED_DATA" ]] || \
        fail "installed-test derived data is unavailable"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$selected_group" "$test_filter" "$context_name" "$repetitions" "$remote_target" >> "$(run_dir)/replay.tsv"
    stop_installed_app
    [[ ! -e "$result_bundle" ]] || fail "result bundle already exists: $result_bundle"
    command_output="$log_path.output.log"
    [[ ! -e "$command_output" ]] || fail "installed-test command output already exists: $command_output"
    control_root="$HOME/Library/Containers/MAF.DetoursUITests.xctrunner/Data/DetoursQualification/$QUALIFICATION_COMMIT/$QUALIFICATION_RUN_ID/$selected_group-$context_name"
    mkdir -p "$control_root"
    printf 'qualification: installed %s %s repetitions 1-%d\n' \
        "$selected_group" "$context_name" "$repetitions" | tee -a "$log_path.log"
    started_at="$(date +%s)"
    set +e
    run_gui_command "$log_path.raw.log" env \
            HOME="$HOME" \
            PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            DEVELOPER_DIR="$(xcode-select -p)" \
            xcodebuild test-without-building -quiet \
            -project "$PROJECT_DIR/Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj" \
            -scheme DetoursUITests \
            -destination 'platform=macOS,arch=arm64' \
            -derivedDataPath "$QUALIFICATION_UI_DERIVED_DATA" \
            -only-testing:"DetoursUITests/$test_filter" \
            "DETOURS_QUALIFICATION_APP_PATH_SETTING=$PROJECT_DIR/build/Detours.app" \
            "DETOURS_QUALIFICATION_UI_ROOT_SETTING=$root_path" \
            "DETOURS_QUALIFICATION_UI_CONTROL_ROOT_SETTING=$control_root" \
            "DETOURS_QUALIFICATION_REAL_REMOTE_TARGET_SETTING=$remote_target" \
            "DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT_SETTING=$context_name" \
            "DETOURS_QUALIFICATION_REPETITIONS_SETTING=$repetitions" \
            -resultBundlePath "$result_bundle" > "$command_output" 2>&1
    status="$?"
    set -e
    tee -a "$log_path.log" < "$command_output"
    stop_installed_app
    if (( status == 0 )); then
        verify_quiet_xcode_command "$log_path.raw.log"
        verify_installed_result_bundle "$result_bundle"
        verify_workflow_repetition_markers "$selected_group" "$control_root" "$repetitions"
    fi
    record_scenario_timing \
        installed "$selected_group" "$context_name" "$repetitions" "$started_at" "$status"
    (( status == 0 )) || return "$status"
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

installed_root_contexts() {
    case "$1" in
        connection) printf 'SMB_ROOT\n' ;;
        session) printf 'LOCAL_ROOT\n' ;;
        *) printf '%s\n' LOCAL_ROOT APFS_ROOT ICLOUD_ROOT SMB_ROOT ;;
    esac
}

installed_group_uses_remote_targets() {
    case "$1" in
        activation|refresh|connection) return 0 ;;
        *) return 1 ;;
    esac
}

installed_contexts() {
    local group="$1"
    installed_root_contexts "$group"
    if installed_group_uses_remote_targets "$group"; then
        printf '%s\n' LINUX_TARGET INTEL_MAC_TARGET WINDOWS_TARGET
    fi
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
        refresh) printf 'QualificationRefreshUITests/testRefreshStateRemainsCoherentAcrossExternalChanges\n' ;;
        transfer) printf 'RefreshAuthorityCopyUITests/testF5CopyActivatesDestinationPaneAndSelectsCopy\n' ;;
        mutation) printf 'NewFolderUITests/testNewFolderSelectsNewFolderNotExisting\n' ;;
        connection) printf 'QualificationConnectionUITests/testConnectionLoadsCapturedPaneWithoutDisturbingOtherPane\n' ;;
        archive) printf 'ArchivePasswordUITests/testCreationControlsFollowSelectedFormat\n' ;;
        session) printf 'WindowPaneGeometryUITests/testPaneDividerDragPersistsAcrossRelaunch\n' ;;
        opening) printf 'MultiFileOpenUITests/testEnterAndCommandOpenDispatchAllSelectedFiles\n' ;;
    esac
}
