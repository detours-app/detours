#!/bin/bash
# lint-ignore: max-lines -- one workflow dispatch surface: every runner here shares the same
# run-directory, control-root, heartbeat, result-bundle and cleanup contract, and splitting it
# would put that shared state behind a seam the halves would call across on every run.

# Repeated workflow dispatch sourced only by qualification.sh.

run_gui_command() {
    local log_path="$1"
    shift
    local label status_path status_tmp launch_stdout launch_stderr job_state command_status
    local attempt exited_without_status_at active_job_file
    local last_progress_epoch now_epoch supervision_started_epoch
    local result_bundle diagnostic_failure diagnostic_prompt
    local streamed_log_lines current_log_lines
    assert_prompt_guard_healthy
    path_is_within "$log_path" "$(run_dir)" || fail "GUI command log escapes the run directory"
    status_path="$log_path.status"
    status_tmp="$status_path.tmp"
    launch_stdout="$log_path.launch-stdout"
    launch_stderr="$log_path.launch-stderr"
    for path in "$log_path" "$status_path" "$status_tmp" "$launch_stdout" "$launch_stderr"; do
        [[ ! -e "$path" ]] || fail "GUI command artifact already exists: $path"
    done
    label="com.detours.qualification.$(uuidgen)"
    result_bundle="${QUALIFICATION_GUI_RESULT_BUNDLE:-}"
    streamed_log_lines=0
    last_progress_epoch="$(date +%s)"
    if [[ -n "$result_bundle" ]]; then
        path_is_within "$result_bundle" "$(run_dir)" || \
            fail "installed result bundle escapes the run directory"
    fi
    active_job_file="$(run_dir)/active-gui-job"
    [[ ! -e "$active_job_file" ]] || fail "another GUI qualification job is already recorded"
    printf '%s\n' "$label" > "$active_job_file"
    trap 'launchctl remove "$label" 2>/dev/null || true; rm -f -- "$active_job_file"; exit 130' HUP INT TERM
    exited_without_status_at=0
    supervision_started_epoch="$(date +%s)"
    last_progress_epoch="$supervision_started_epoch"
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
        assert_prompt_guard_healthy
        if [[ -f "$log_path" ]]; then
            current_log_lines="$(wc -l < "$log_path" | tr -d '[:space:]')"
            if [[ "$current_log_lines" =~ ^[0-9]+$ ]] \
                && (( current_log_lines > streamed_log_lines )); then
                sed -n "$((streamed_log_lines + 1)),${current_log_lines}p" "$log_path"
                streamed_log_lines="$current_log_lines"
            fi
        fi
        diagnostic_failure=""
        diagnostic_prompt=""
        if [[ -d "$result_bundle/Staging" ]]; then
            diagnostic_failure="$(find "$result_bundle/Staging" \
                -type f -name StandardOutputAndStandardError.txt -exec \
                grep -hEm1 ':[0-9]+: error:|Test Case .* failed' {} + 2>/dev/null | head -1 || true)"
            diagnostic_prompt="$(find "$result_bundle/Staging" \
                -type f -name StandardOutputAndStandardError.txt -exec \
                grep -hEm1 "Application 'com.apple.UserNotificationCenter'" \
                {} + 2>/dev/null | head -1 || true)"
        fi
        if [[ -n "$diagnostic_prompt" ]]; then
            printf '%s\n' "$diagnostic_prompt" >&2
            launchctl remove "$label" 2>/dev/null || true
            rm -f -- "$active_job_file"
            trap - HUP INT TERM
            fail "installed run reported a macOS consent prompt"
        fi
        if [[ -n "$diagnostic_failure" ]]; then
            printf '%s\n' "$diagnostic_failure" >&2
            launchctl remove "$label" 2>/dev/null || true
            rm -f -- "$active_job_file"
            trap - HUP INT TERM
            fail "installed run reported a test failure"
        fi
        if [[ -f "$status_path" ]]; then
            break
        fi
        now_epoch="$(date +%s)"
        if (( now_epoch - last_progress_epoch >= 60 )); then
            # xcodebuild owns per-test progress; this only proves the run is not silent.
            printf 'qualification-progress phase=running elapsed=%ss\n' \
                "$(( now_epoch - supervision_started_epoch ))"
            last_progress_epoch="$now_epoch"
        fi
        if [[ -n "${QUALIFICATION_BLOCKING_DEADLINE_EPOCH:-}" ]] \
            && (( $(date +%s) >= QUALIFICATION_BLOCKING_DEADLINE_EPOCH )); then
            launchctl remove "$label" 2>/dev/null || true
            rm -f -- "$active_job_file"
            trap - HUP INT TERM
            fail "GUI qualification job exceeded the blocking layer deadline: $label"
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
    tail -n "+$((streamed_log_lines + 1))" "$log_path"
    return "$command_status"
}

verify_in_process_heartbeats() {
    local heartbeat_path="$1"
    local group="$2"
    local repetitions="$3"
    local seed="$4"
    local iteration expected_count actual_count expected_line
    expected_count=0
    for (( iteration = 1; iteration <= repetitions; iteration++ )); do
        if (( iteration == 1 || iteration % 3 == 0 || iteration == repetitions )); then
            expected_line="qualification-progress group=$group completed=$iteration total=$repetitions seed=$seed"
            [[ "$(grep -Fxc "$expected_line" "$heartbeat_path" || true)" == "1" ]] || \
                fail "in-process heartbeat is missing or duplicated: $expected_line"
            ((expected_count += 1))
        fi
    done
    actual_count="$(wc -l < "$heartbeat_path" | tr -d '[:space:]')"
    [[ "$actual_count" == "$expected_count" ]] || \
        fail "in-process heartbeat file has $actual_count lines instead of $expected_count"
}

run_in_process() {
    local group="$1"
    validate_group "$group"
    assert_prompt_guard_healthy
    local fixture_file selected_group method log_dir started_at status
    local active_deadline_file deadline_epoch heartbeat_path status_path stream_pid path
    local heartbeat_count current_heartbeat_count last_progress_epoch now_epoch
    local heartbeat_timed_out stream_status
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
        printf '%s\t%s\t%s\n' \
            "$selected_group" "$method" "$QUALIFICATION_IN_PROCESS_REPETITIONS" >> "$(run_dir)/replay.tsv"
        started_at="$(date +%s)"
        deadline_epoch=$((started_at + 600))
        active_deadline_file="$(run_dir)/active-deadline"
        heartbeat_path="$log_dir/$selected_group.heartbeat.log"
        status_path="$log_dir/$selected_group.status"
        path_is_within "$active_deadline_file" "$(run_dir)" || \
            fail "active deadline record escapes the run directory"
        for path in "$heartbeat_path" "$status_path" "$log_dir/$selected_group.log"; do
            [[ ! -e "$path" ]] || fail "in-process workflow artifact already exists: $path"
        done
        : > "$heartbeat_path"
        set +e
        (
            DETOURS_QUALIFICATION_REPETITIONS="$QUALIFICATION_IN_PROCESS_REPETITIONS" \
                DETOURS_QUALIFICATION_SEED="$QUALIFICATION_SEED" \
                DETOURS_QUALIFICATION_HEARTBEAT_FILE="$heartbeat_path" \
                QUALIFICATION_ACTIVE_DEADLINE_FILE="$active_deadline_file" \
                "$SCRIPT_DIR/qualification-deadline.sh" "$deadline_epoch" \
                    swift test --filter "QualificationWorkflowTests/$method"
            printf '%s\n' "$?" > "$status_path"
        ) 2>&1 | tee "$log_dir/$selected_group.log" &
        stream_pid=$!
        heartbeat_count=0
        last_progress_epoch="$started_at"
        heartbeat_timed_out=0
        while kill -0 "$stream_pid" 2>/dev/null; do
            current_heartbeat_count="$(wc -l < "$heartbeat_path" | tr -d '[:space:]')"
            if (( current_heartbeat_count > heartbeat_count )); then
                sed -n "$((heartbeat_count + 1)),${current_heartbeat_count}p" "$heartbeat_path"
                heartbeat_count="$current_heartbeat_count"
                last_progress_epoch="$(date +%s)"
            fi
            now_epoch="$(date +%s)"
            if (( now_epoch - last_progress_epoch >= 30 )); then
                printf 'qualification: in-process %s produced no progress for 30 seconds\n' \
                    "$selected_group" >&2
                run_cancel
                heartbeat_timed_out=1
                break
            fi
            sleep 0.2
        done
        wait "$stream_pid"
        stream_status="$?"
        set -e
        current_heartbeat_count="$(wc -l < "$heartbeat_path" | tr -d '[:space:]')"
        if (( current_heartbeat_count > heartbeat_count )); then
            sed -n "$((heartbeat_count + 1)),${current_heartbeat_count}p" "$heartbeat_path"
            heartbeat_count="$current_heartbeat_count"
        fi
        (( stream_status == 0 )) || fail "in-process output stream failed"
        if (( heartbeat_timed_out == 1 )); then
            status=93
        else
            [[ -f "$status_path" ]] || fail "in-process workflow status is missing"
            IFS= read -r status < "$status_path"
            [[ "$status" =~ ^[0-9]+$ ]] || fail "in-process workflow status is invalid"
        fi
        assert_prompt_guard_healthy
        record_scenario_timing \
            in-process "$selected_group" all-roots "$QUALIFICATION_IN_PROCESS_REPETITIONS" "$started_at" "$status"
        (( status == 0 )) || return "$status"
        verify_in_process_heartbeats \
            "$heartbeat_path" "$selected_group" "$QUALIFICATION_IN_PROCESS_REPETITIONS" "$QUALIFICATION_SEED"
    done < <(selected_workflow_groups "$group")
}

run_installed() {
    local group="$1"
    validate_group "$group"
    assert_prompt_guard_healthy
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
    local test_filter="${4:-}"
    local fixture_file log_dir result_dir remote_target
    assert_prompt_guard_healthy
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
        LOCAL_ROOT)
            run_installed_once \
                "$group" "$context_name" "$repetitions" \
                "$log_dir/$group-$context_name" \
                "$result_dir/$group-$context_name.xcresult" \
                "" "$context_name" "$test_filter"
            ;;
        LINUX_TARGET|INTEL_MAC_TARGET|WINDOWS_TARGET)
            remote_target="${!context_name}"
            [[ -n "$remote_target" ]] || fail "remote smoke target is missing: $context_name"
            run_installed_once \
                "$group" LOCAL_ROOT "$repetitions" \
                "$log_dir/$group-$context_name" \
                "$result_dir/$group-$context_name.xcresult" \
                "$remote_target" "$context_name" "$test_filter"
            ;;
    esac
}

prepare_installed_test_bundle() {
    local log_path="$1"
    local derived_data ready_file status xctestrun
    local -a candidates=()
    derived_data="$(run_dir)/xcode-derived-data"
    ready_file="$(run_dir)/xcode-derived-data.ready"
    if [[ -d "$derived_data" ]]; then
        [[ -f "$ready_file" ]] || \
            fail "installed-test derived data exists without a readiness record: $derived_data"
        IFS= read -r xctestrun < "$ready_file"
        path_is_within "$xctestrun" "$derived_data" || \
            fail "installed-test readiness record escapes derived data"
        [[ -f "$xctestrun" ]] || fail "installed-test readiness bundle is missing: $xctestrun"
        [[ ! -e "$log_path" ]] || fail "installed-test reuse log already exists: $log_path"
        printf 'reused=%s\n' "$xctestrun" > "$log_path"
        QUALIFICATION_UI_DERIVED_DATA="$derived_data"
        return
    fi
    [[ ! -e "$derived_data" ]] || fail "installed-test derived data already exists: $derived_data"
    pgrep -x Finder >/dev/null 2>&1 || fail "Finder GUI session is unavailable"
    require_command jq
    require_command xcrun
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
        DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT_SETTING=detours-qualification-canary-context \
        DETOURS_QUALIFICATION_REPETITIONS_SETTING=1
    status="$?"
    set -e
    cp "$log_path.raw" "$log_path"
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
    printf '%s\n' "$xctestrun" > "$ready_file"
    QUALIFICATION_UI_DERIVED_DATA="$derived_data"
}

verify_quiet_xcode_command() {
    local command_log="$1"
    local artifact
    [[ -e "$command_log" ]] || fail "Xcode command artifact is missing: $command_log"
    for artifact in "$command_log.launch-stdout" "$command_log.launch-stderr"; do
        [[ -e "$artifact" ]] || fail "Xcode command artifact is missing: $artifact"
        [[ ! -s "$artifact" ]] || fail "Xcode command transport emitted unexpected output: $artifact"
    done
}

verify_installed_result_bundle() {
    local result_bundle="$1"
    local expected_count="${2:-1}"
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
    if [[ "$expected_count" == "any" ]]; then
        # A whole-target run has no fixed logical count; every test still has to pass,
        # and a skip is reported rather than hidden behind a green run.
        (( total > 0 )) || fail "installed run executed no tests"
        [[ "$passed" == "$total" ]] || \
            fail "installed run passed $passed of $total logical tests"
        [[ "$skipped" == "0" ]] || \
            printf 'qualification: installed run skipped %s tests\n' "$skipped"
    else
        [[ "$total" == "$expected_count" ]] || \
            fail "installed workflow ran $total logical tests instead of $expected_count"
        [[ "$passed" == "$expected_count" ]] || \
            fail "installed workflow passed $passed logical tests instead of $expected_count"
        [[ "$skipped" == "0" ]] || fail "installed iteration recorded $skipped skipped tests"
    fi
    [[ "$failed" == "0" ]] || fail "installed iteration recorded $failed failed tests"
    [[ "$expected" == "0" ]] || fail "installed iteration recorded $expected expected failures"
    [[ "$result" == "Passed" ]] || fail "installed iteration result is not Passed: $result"

    device_passed="$(jq '[.devicesAndConfigurations[].passedTests] | add // 0' "$summary_path")"
    device_failed="$(jq '[.devicesAndConfigurations[].failedTests] | add // 0' "$summary_path")"
    device_skipped="$(jq '[.devicesAndConfigurations[].skippedTests] | add // 0' "$summary_path")"
    if [[ "$expected_count" == "any" ]]; then
        [[ "$device_passed" == "$passed" ]] || \
            fail "installed run passed $device_passed device tests against $passed logical tests"
    else
        [[ "$device_passed" == "$expected_count" ]] || \
            fail "installed workflow passed $device_passed logical tests instead of $expected_count"
        [[ "$device_skipped" == "0" ]] || fail "installed workflow recorded $device_skipped skipped repetitions"
    fi
    [[ "$device_failed" == "0" ]] || fail "installed workflow recorded $device_failed failed repetitions"
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
    test_filter="${8:-$(installed_test_filter "$selected_group")}"
    root_path="${!root_name}"
    [[ -n "${QUALIFICATION_UI_DERIVED_DATA:-}" && -d "$QUALIFICATION_UI_DERIVED_DATA" ]] || \
        fail "installed-test derived data is unavailable"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$selected_group" "$test_filter" "$context_name" "$repetitions" "$remote_target" >> "$(run_dir)/replay.tsv"
    stop_installed_app
    [[ ! -e "$result_bundle" ]] || fail "result bundle already exists: $result_bundle"
    command_output="$log_path.output.log"
    [[ ! -e "$command_output" ]] || fail "installed-test command output already exists: $command_output"
    control_root="$LOCAL_ROOT/.control-$selected_group-$context_name"
    mkdir -p "$control_root"
    printf 'qualification: installed %s %s repetitions 1-%d\n' \
        "$selected_group" "$context_name" "$repetitions" | tee -a "$log_path.log"
    started_at="$(date +%s)"
    set +e
    QUALIFICATION_GUI_RESULT_BUNDLE="$result_bundle" \
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
            -resultBundlePath "$result_bundle" 2>&1 | tee "$command_output"
    status="${PIPESTATUS[0]}"
    set -e
    cat "$command_output" >> "$log_path.log"
    stop_installed_app
    if (( status == 0 )); then
        verify_quiet_xcode_command "$log_path.raw.log"
        verify_installed_result_bundle "$result_bundle"
        # Repetition markers are written by the group's own workflow test, which owns the
        # repetition loop. A substituted --test-filter selects a different regression that
        # never writes them, so demanding markers there fails a run whose test passed.
        # The result bundle still proves the selected test ran and passed.
        if [[ "$test_filter" == "$(installed_test_filter "$selected_group")" ]]; then
            verify_workflow_repetition_markers "$selected_group" "$control_root" "$repetitions"
        else
            printf 'qualification: %s repetition markers not checked; --test-filter selected %s instead of the group workflow test\n' \
                "$selected_group" "$test_filter" | tee -a "$log_path.log"
        fi
    fi
    record_scenario_timing \
        installed "$selected_group" "$context_name" "$repetitions" "$started_at" "$status"
    (( status == 0 )) || return "$status"
}

run_installed_all() {
    local log_path="$1"
    local result_bundle="$2"
    local fixture_file control_root command_output started_at status
    assert_prompt_guard_healthy
    fixture_file="$(run_dir)/fixtures.env"
    [[ -f "$fixture_file" ]] || fail "fixture record is missing: $fixture_file"
    set -a
    # shellcheck disable=SC1090
    source "$fixture_file"
    set +a
    prepare_installed_test_bundle "$(dirname "$log_path")/build-for-testing.log"
    [[ -n "${QUALIFICATION_UI_DERIVED_DATA:-}" && -d "$QUALIFICATION_UI_DERIVED_DATA" ]] || \
        fail "installed-test derived data is unavailable"
    [[ -n "${LOCAL_ROOT:-}" ]] || fail "local fixture root is unavailable"
    [[ ! -e "$result_bundle" ]] || fail "result bundle already exists: $result_bundle"
    command_output="$log_path.output.log"
    [[ ! -e "$command_output" ]] || fail "installed-test command output already exists: $command_output"
    control_root="$LOCAL_ROOT/.control-installed-all"
    mkdir -p "$control_root"
    stop_installed_app
    printf 'qualification: installed every UI test once\n' | tee -a "$log_path.log"
    started_at="$(date +%s)"
    set +e
    QUALIFICATION_GUI_RESULT_BUNDLE="$result_bundle" \
        QUALIFICATION_BLOCKING_DEADLINE_EPOCH="${QUALIFICATION_BLOCKING_DEADLINE_EPOCH:-$(( $(date +%s) + QUALIFICATION_INSTALLED_ALL_DEADLINE ))}" \
        run_gui_command "$log_path.raw.log" env \
            HOME="$HOME" \
            PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            DEVELOPER_DIR="$(xcode-select -p)" \
            xcodebuild test-without-building -quiet \
            -project "$PROJECT_DIR/Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj" \
            -scheme DetoursUITests \
            -destination 'platform=macOS,arch=arm64' \
            -derivedDataPath "$QUALIFICATION_UI_DERIVED_DATA" \
            -only-testing:DetoursUITests \
            "DETOURS_QUALIFICATION_APP_PATH_SETTING=$PROJECT_DIR/build/Detours.app" \
            "DETOURS_QUALIFICATION_UI_ROOT_SETTING=$LOCAL_ROOT" \
            "DETOURS_QUALIFICATION_UI_CONTROL_ROOT_SETTING=$control_root" \
            "DETOURS_QUALIFICATION_REAL_REMOTE_TARGET_SETTING=$QUALIFICATION_LINUX_TARGET" \
            "DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT_SETTING=LINUX_TARGET" \
            "DETOURS_QUALIFICATION_REPETITIONS_SETTING=1" \
            -resultBundlePath "$result_bundle" 2>&1 | tee "$command_output"
    status="${PIPESTATUS[0]}"
    set -e
    cat "$command_output" >> "$log_path.log"
    stop_installed_app
    if (( status == 0 )); then
        verify_quiet_xcode_command "$log_path.raw.log"
        verify_installed_result_bundle "$result_bundle" any
    fi
    record_scenario_timing installed all INSTALLED_ALL 1 "$started_at" "$status"
    (( status == 0 )) || return "$status"
}

run_installed_qualification_batch() {
    local log_path="$1"
    local result_bundle="$2"
    local control_root command_output started_at status selected_group test_filter
    local -a only_testing=()
    [[ -n "${QUALIFICATION_UI_DERIVED_DATA:-}" && -d "$QUALIFICATION_UI_DERIVED_DATA" ]] || \
        fail "installed-test derived data is unavailable"
    [[ ! -e "$result_bundle" ]] || fail "result bundle already exists: $result_bundle"
    command_output="$log_path.output.log"
    [[ ! -e "$command_output" ]] || fail "installed-test command output already exists: $command_output"
    control_root="$LOCAL_ROOT/.control-blocking-all"
    mkdir -p "$control_root"
    while IFS= read -r selected_group; do
        test_filter="$(installed_test_filter "$selected_group")"
        only_testing+=("-only-testing:DetoursUITests/$test_filter")
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$selected_group" "$test_filter" "BLOCKING_ALL" "1" "$QUALIFICATION_LINUX_TARGET" \
            >> "$(run_dir)/replay.tsv"
    done < <(workflow_groups)
    stop_installed_app
    printf 'qualification: installed workflow batch activation-refresh-transfer-mutation-connection-archive-session-opening\n' \
        | tee -a "$log_path.log"
    started_at="$(date +%s)"
    set +e
    QUALIFICATION_GUI_RESULT_BUNDLE="$result_bundle" \
        run_gui_command "$log_path.raw.log" env \
            HOME="$HOME" \
            PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            DEVELOPER_DIR="$(xcode-select -p)" \
            xcodebuild test-without-building -quiet \
            -project "$PROJECT_DIR/Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj" \
            -scheme DetoursUITests \
            -destination 'platform=macOS,arch=arm64' \
            -derivedDataPath "$QUALIFICATION_UI_DERIVED_DATA" \
            "${only_testing[@]}" \
            "DETOURS_QUALIFICATION_APP_PATH_SETTING=$PROJECT_DIR/build/Detours.app" \
            "DETOURS_QUALIFICATION_UI_ROOT_SETTING=$LOCAL_ROOT" \
            "DETOURS_QUALIFICATION_UI_CONTROL_ROOT_SETTING=$control_root" \
            "DETOURS_QUALIFICATION_REAL_REMOTE_TARGET_SETTING=$QUALIFICATION_LINUX_TARGET" \
            "DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT_SETTING=LINUX_TARGET" \
            "DETOURS_QUALIFICATION_REPETITIONS_SETTING=1" \
            -resultBundlePath "$result_bundle" 2>&1 | tee "$command_output"
    status="${PIPESTATUS[0]}"
    set -e
    cat "$command_output" >> "$log_path.log"
    stop_installed_app
    if (( status == 0 )); then
        verify_quiet_xcode_command "$log_path.raw.log"
        verify_installed_result_bundle "$result_bundle" 8
        while IFS= read -r selected_group; do
            verify_workflow_repetition_markers "$selected_group" "$control_root" 1
        done < <(workflow_groups)
    fi
    record_scenario_timing installed all BLOCKING_ALL 8 "$started_at" "$status"
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
        connection) ;;
        *) printf 'LOCAL_ROOT\n' ;;
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
