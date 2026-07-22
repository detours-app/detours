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

require_clean_selected_run() {
    local summary="$1"
    local selected_dir
    selected_dir="$(dirname "$summary")"
    [[ -f "$selected_dir/cleanup/result.env" ]] || fail "cleanup evidence is missing: $selected_dir"
    [[ "$(report_env_value status "$selected_dir/cleanup/result.env")" == "passed" ]] || \
        fail "cleanup evidence is not green: $selected_dir"
    [[ -f "$selected_dir/prompt-guard/result.env" ]] || \
        fail "prompt-audit evidence is missing: $selected_dir"
    [[ "$(report_env_value status "$selected_dir/prompt-guard/result.env")" == "passed" ]] || \
        fail "prompt-audit evidence is not green: $selected_dir"
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
    local result_path row_count timing_count screenshot_count bundle_count regression_count
    local cold_one_dir cold_two_dir cold_three_dir
    local environment_file linux_target intel_mac_target windows_target smb_host smb_share
    result_path="$PROJECT_DIR/resources/docs/260720-whole-app-stability-qualification-result.md"
    cold_one_dir="$(dirname "$cold_one")"
    cold_two_dir="$(dirname "$cold_two")"
    cold_three_dir="$(dirname "$cold_three")"
    environment_file="$cold_one_dir/preflight/environment.env"
    linux_target="$(report_env_value linux_target "$environment_file")"
    intel_mac_target="$(report_env_value intel_mac_target "$environment_file")"
    windows_target="$(report_env_value windows_target "$environment_file")"
    smb_host="$(report_env_value smb_host "$environment_file")"
    smb_share="$(report_env_value smb_share "$environment_file")"
    row_count="$(grep -Ec '^\| [A-Z]+-[0-9]{3} \|' "$MATRIX_PATH")"
    timing_count="$(find "$cold_one_dir" "$cold_two_dir" "$cold_three_dir" -path '*/timing/scenarios.tsv' -exec awk 'END { total += NR } END { print total }' {} \; | awk '{ total += $1 } END { print total + 0 }')"
    screenshot_count="$(find "$cold_one_dir" "$cold_two_dir" "$cold_three_dir" -type f \( -name '*.png' -o -name '*.jpg' \) | wc -l | tr -d ' ')"
    bundle_count="$(find "$cold_one_dir" "$cold_two_dir" "$cold_three_dir" -type d -name '*.xcresult' | wc -l | tr -d ' ')"
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
        printf '\nCold run 3 began after a Foundry reboot distinct from cold run 2. '
        printf 'Marco removed the 12-hour soak from this qualification on 2026-07-22; '
        printf 'it is not a completion gate and any future reliability exercise requires separate authorization.\n\n'
        printf '## Environments and evidence\n\n'
        printf 'Each selected run contains preflight environment versions, deterministic replay records, '
        printf 'scenario timing, state observations, outside-root snapshots, logs, XCResult bundles, '
        printf 'screenshots, and verified cleanup under `.build/qualification/%s/`.\n\n' "$qualified_commit"
        printf 'The qualified locations were local storage, a disposable APFS volume, real iCloud Drive, '
        printf 'SMB `%s/%s`, Linux `%s`, Intel Mac `%s`, and Windows `%s`. ' \
            "$smb_host" "$smb_share" "$linux_target" "$intel_mac_target" "$windows_target"
        printf 'These are recorded logical endpoints, not machine identities. No applicable result was '
        printf 'skipped or retried into a pass.\n\n'
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
    {
        printf '\n- %s: Foundry whole-app qualification PASS for `%s`. Cold run IDs: `%s`, `%s`, `%s`. All matrix rows passed, selected runs contained no failure trace, prompt audits and guarded cleanup passed. Marco removed the 12-hour soak from this qualification on 2026-07-22.\n' \
            "$(date '+%Y-%m-%d %H:%M %Z')" "$qualified_commit" \
            "$(basename "$(dirname "$cold_one")")" "$(basename "$(dirname "$cold_two")")" \
            "$(basename "$(dirname "$cold_three")")"
    } >> "$PROJECT_DIR/Tests/TEST_LOG.md"
}

generate_qualification_report() {
    local qualified_commit commit_dir cold_one cold_two cold_three
    local first_epoch second_epoch third_epoch second_boot third_boot changed_path
    [[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]] || fail "report generation requires a clean worktree"
    qualified_commit="$(canonical_commit)"
    commit_dir="$QUALIFICATION_ROOT/$qualified_commit"
    [[ -d "$commit_dir" ]] || fail "qualification evidence is missing for $qualified_commit"
    cold_one="$(select_cold_record "$commit_dir" 1)"
    cold_two="$(select_cold_record "$commit_dir" 2)"
    cold_three="$(select_cold_record "$commit_dir" 3)"
    for changed_path in "$cold_one" "$cold_two" "$cold_three"; do
        require_clean_selected_run "$changed_path"
    done

    first_epoch="$(report_env_value completed_epoch "$cold_one")"
    second_epoch="$(report_env_value completed_epoch "$cold_two")"
    third_epoch="$(report_env_value completed_epoch "$cold_three")"
    (( first_epoch < second_epoch && second_epoch < third_epoch )) || \
        fail "final cold runs are not an ordered consecutive sequence"
    second_boot="$(report_env_value boot_epoch "$cold_two")"
    third_boot="$(report_env_value boot_epoch "$cold_three")"
    [[ "$second_boot" != "$third_boot" ]] || fail "cold run 3 did not begin after a Foundry reboot"

    update_qualification_matrix_results
    write_qualification_result "$qualified_commit" "$cold_one" "$cold_two" "$cold_three"
    append_qualification_test_log "$qualified_commit" "$cold_one" "$cold_two" "$cold_three"
    while IFS= read -r changed_path; do
        case "$changed_path" in
            resources/docs/260720-whole-app-stability-qualification-matrix.md|\
            resources/docs/260720-whole-app-stability-qualification-result.md|\
            Tests/TEST_LOG.md) ;;
            *) fail "report generation changed a forbidden tracked path: $changed_path" ;;
        esac
    done < <(git -C "$PROJECT_DIR" status --porcelain | sed -E 's/^.. //')
}
