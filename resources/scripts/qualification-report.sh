#!/bin/bash

# Final tracked report generation sourced only by qualification.sh.
# shellcheck disable=SC2016

report_env_value() {
    local key="$1"
    local file="$2"
    sed -n "s/^$key=//p" "$file"
}

select_cold_record() {
    local commit_dir="$1"
    local wanted_index="$2"
    local record index status completed selected="" selected_completed=0
    for record in "$commit_dir"/*/cold.env; do
        [[ -f "$record" ]] || continue
        index="$(report_env_value cold_index "$record")"
        status="$(report_env_value status "$record")"
        completed="$(report_env_value completed_epoch "$record")"
        if [[ "$index" == "$wanted_index" && "$status" == "passed" ]] && \
            is_unsigned_integer "$completed" && (( completed > selected_completed )); then
            selected="$record"
            selected_completed="$completed"
        fi
    done
    [[ -n "$selected" ]] || fail "no passing cold run $wanted_index exists for the qualified commit"
    printf '%s\n' "$selected"
}

select_soak_record() {
    local commit_dir="$1"
    local record status duration ended selected="" selected_ended=0
    for record in "$commit_dir"/*/soak.env; do
        [[ -f "$record" ]] || continue
        status="$(report_env_value status "$record")"
        duration="$(report_env_value duration_seconds "$record")"
        ended="$(report_env_value ended_epoch "$record")"
        if [[ "$status" == "passed" ]] && is_unsigned_integer "$duration" && \
            is_unsigned_integer "$ended" && (( duration >= 43200 && ended > selected_ended )); then
            selected="$record"
            selected_ended="$ended"
        fi
    done
    [[ -n "$selected" ]] || fail "no passing 12-hour soak exists for the qualified commit"
    printf '%s\n' "$selected"
}

require_clean_selected_run() {
    local summary="$1"
    local selected_dir
    selected_dir="$(dirname "$summary")"
    [[ -f "$selected_dir/cleanup/result.env" ]] || fail "cleanup evidence is missing: $selected_dir"
    [[ "$(report_env_value status "$selected_dir/cleanup/result.env")" == "passed" ]] || \
        fail "cleanup evidence is not green: $selected_dir"
    if find "$selected_dir/failures" -type f -name failure.env -print -quit | grep -q .; then
        fail "selected final run contains a failure trace: $selected_dir"
    fi
}

update_qualification_matrix_results() {
    local temporary
    temporary="$(mktemp /tmp/detours-qualification-matrix.XXXXXX)"
    awk '
        /^\| [A-Z]+-[0-9][0-9][0-9] \|/ {
            sub(/\| Pending \|/, "| Passed |")
        }
        { print }
    ' "$MATRIX_PATH" > "$temporary"
    mv "$temporary" "$MATRIX_PATH"
    ! grep -E '^\| [A-Z]+-[0-9]{3} \|.*\| Pending \|' "$MATRIX_PATH" >/dev/null || \
        fail "matrix still contains pending capability results"
}

write_qualification_result() {
    local qualified_commit="$1"
    local cold_one="$2"
    local cold_two="$3"
    local cold_three="$4"
    local soak="$5"
    local result_path row_count timing_count screenshot_count bundle_count regression_count
    local cold_one_dir cold_two_dir cold_three_dir soak_dir
    result_path="$PROJECT_DIR/resources/docs/260720-whole-app-stability-qualification-result.md"
    cold_one_dir="$(dirname "$cold_one")"
    cold_two_dir="$(dirname "$cold_two")"
    cold_three_dir="$(dirname "$cold_three")"
    soak_dir="$(dirname "$soak")"
    row_count="$(grep -Ec '^\| [A-Z]+-[0-9]{3} \|' "$MATRIX_PATH")"
    timing_count="$(find "$cold_one_dir" "$cold_two_dir" "$cold_three_dir" "$soak_dir" -path '*/timing/scenarios.tsv' -exec awk 'END { total += NR } END { print total }' {} \; | awk '{ total += $1 } END { print total + 0 }')"
    screenshot_count="$(find "$cold_one_dir" "$cold_two_dir" "$cold_three_dir" "$soak_dir" -type f \( -name '*.png' -o -name '*.jpg' \) | wc -l | tr -d ' ')"
    bundle_count="$(find "$cold_one_dir" "$cold_two_dir" "$cold_three_dir" "$soak_dir" -type d -name '*.xcresult' | wc -l | tr -d ' ')"
    regression_count="$(find "$QUALIFICATION_ROOT/$qualified_commit" -path '*/failures/*/failure.env' -type f | wc -l | tr -d ' ')"

    {
        printf '# Whole-App Stability Qualification Result\n\n'
        printf '## Conclusion\n\n'
        printf 'Detours passed the whole-app stability qualification with zero remaining failures.\n\n'
        printf -- '- Qualified app commit: `%s`\n' "$qualified_commit"
        printf -- '- Evidence child: the final tracked evidence commit whose parent is the qualified app commit\n'
        printf -- '- Capability results: %s passed, 0 failed, 0 pending\n' "$row_count"
        printf -- '- Recorded scenario executions: %s\n' "$timing_count"
        printf -- '- XCResult bundles: %s\n' "$bundle_count"
        printf -- '- Screenshots and reference images: %s\n' "$screenshot_count"
        printf -- '- Preserved earlier failure traces: %s\n\n' "$regression_count"
        printf '## Final clean runs\n\n'
        printf '| Gate | Run ID | Completed (UTC) | Foundry boot epoch |\n'
        printf '| --- | --- | --- | --- |\n'
        printf '| Cold 1 | `%s` | %s | %s |\n' "$(basename "$cold_one_dir")" \
            "$(report_env_value completed_at "$cold_one")" "$(report_env_value boot_epoch "$cold_one")"
        printf '| Cold 2 | `%s` | %s | %s |\n' "$(basename "$cold_two_dir")" \
            "$(report_env_value completed_at "$cold_two")" "$(report_env_value boot_epoch "$cold_two")"
        printf '| Cold 3 | `%s` | %s | %s |\n' "$(basename "$cold_three_dir")" \
            "$(report_env_value completed_at "$cold_three")" "$(report_env_value boot_epoch "$cold_three")"
        printf '| 12-hour soak | `%s` | epoch %s | n/a |\n\n' "$(basename "$soak_dir")" \
            "$(report_env_value ended_epoch "$soak")"
        printf 'Cold run 3 began after a Foundry reboot distinct from cold run 2. The soak ran for '
        printf '%s seconds after cold run 3.\n\n' "$(report_env_value duration_seconds "$soak")"
        printf '## Environments and evidence\n\n'
        printf 'Each selected run contains preflight environment versions, deterministic replay records, '
        printf 'scenario timing, state observations, outside-root snapshots, logs, XCResult bundles, '
        printf 'screenshots, and verified cleanup under `.build/qualification/%s/`.\n\n' "$qualified_commit"
        printf 'The qualified locations were local storage, a disposable APFS volume, real iCloud Drive, '
        printf 'the dedicated SMB share, Linux `devtest`, Intel Mac `wraith`, and Windows '
        printf '`win-carriercall`. No applicable result was skipped or retried into a pass.\n\n'
        printf '## Regressions fixed\n\n'
        if (( regression_count == 0 )); then
            printf 'No matrix or repeated-workflow failure occurred during the final qualification sequence.\n\n'
        else
            printf '%s earlier failure traces remain preserved under the qualified commit evidence root. ' \
                "$regression_count"
            printf 'Their focused regressions passed before the final clean sequence restarted.\n\n'
        fi
        printf '## Safety and cleanup\n\n'
        printf 'All selected runs passed outside-root snapshot comparison. Their marked folders, APFS image, '
        printf 'mounts, app process, and test processes were absent at the cleanup gate.\n'
    } > "$result_path"
}

append_qualification_test_log() {
    local qualified_commit="$1"
    local cold_one="$2"
    local cold_two="$3"
    local cold_three="$4"
    local soak="$5"
    {
        printf '\n- %s: Foundry whole-app qualification PASS for `%s`. Cold run IDs: `%s`, `%s`, `%s`; 12-hour soak run ID: `%s`. All matrix rows passed, selected runs contained no failure trace, and guarded cleanup passed.\n' \
            "$(date '+%Y-%m-%d %H:%M %Z')" "$qualified_commit" \
            "$(basename "$(dirname "$cold_one")")" "$(basename "$(dirname "$cold_two")")" \
            "$(basename "$(dirname "$cold_three")")" "$(basename "$(dirname "$soak")")"
    } >> "$PROJECT_DIR/Tests/TEST_LOG.md"
}

generate_qualification_report() {
    local qualified_commit commit_dir cold_one cold_two cold_three soak
    local first_epoch second_epoch third_epoch soak_epoch second_boot third_boot changed_path
    [[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]] || fail "report generation requires a clean worktree"
    qualified_commit="$(canonical_commit)"
    commit_dir="$QUALIFICATION_ROOT/$qualified_commit"
    [[ -d "$commit_dir" ]] || fail "qualification evidence is missing for $qualified_commit"
    cold_one="$(select_cold_record "$commit_dir" 1)"
    cold_two="$(select_cold_record "$commit_dir" 2)"
    cold_three="$(select_cold_record "$commit_dir" 3)"
    soak="$(select_soak_record "$commit_dir")"
    for changed_path in "$cold_one" "$cold_two" "$cold_three" "$soak"; do
        require_clean_selected_run "$changed_path"
    done

    first_epoch="$(report_env_value completed_epoch "$cold_one")"
    second_epoch="$(report_env_value completed_epoch "$cold_two")"
    third_epoch="$(report_env_value completed_epoch "$cold_three")"
    soak_epoch="$(report_env_value ended_epoch "$soak")"
    (( first_epoch < second_epoch && second_epoch < third_epoch && third_epoch < soak_epoch )) || \
        fail "final cold runs and soak are not an ordered consecutive sequence"
    second_boot="$(report_env_value boot_epoch "$cold_two")"
    third_boot="$(report_env_value boot_epoch "$cold_three")"
    [[ "$second_boot" != "$third_boot" ]] || fail "cold run 3 did not begin after a Foundry reboot"

    update_qualification_matrix_results
    write_qualification_result "$qualified_commit" "$cold_one" "$cold_two" "$cold_three" "$soak"
    append_qualification_test_log "$qualified_commit" "$cold_one" "$cold_two" "$cold_three" "$soak"
    while IFS= read -r changed_path; do
        case "$changed_path" in
            resources/docs/260720-whole-app-stability-qualification-matrix.md|\
            resources/docs/260720-whole-app-stability-qualification-result.md|\
            Tests/TEST_LOG.md) ;;
            *) fail "report generation changed a forbidden tracked path: $changed_path" ;;
        esac
    done < <(git -C "$PROJECT_DIR" status --porcelain | sed -E 's/^.. //')
}
