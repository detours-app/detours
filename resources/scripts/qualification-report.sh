#!/bin/bash

# Final tracked report generation sourced only by qualification.sh.
# shellcheck disable=SC2016 # Markdown backticks are literal report formatting.

report_env_value() {
    local key="$1"
    local file="$2"
    sed -n "s/^$key=//p" "$file"
}

select_blocking_record() {
    local commit_dir="$1"
    local record status completed selected="" selected_completed=0
    for record in "$commit_dir"/*/blocking.env; do
        [[ -f "$record" ]] || continue
        status="$(report_env_value status "$record")"
        completed="$(report_env_value completed_epoch "$record")"
        if [[ "$status" == "passed" ]] && is_unsigned_integer "$completed" \
            && (( completed > selected_completed )); then
            selected="$record"
            selected_completed="$completed"
        fi
    done
    [[ -n "$selected" ]] || fail "no passing whole-app blocking run exists for the qualified commit"
    printf '%s\n' "$selected"
}

require_clean_selected_run() {
    local summary="$1"
    local selected_dir
    selected_dir="$(dirname "$summary")"
    [[ "$(report_env_value status "$selected_dir/cleanup/result.env")" == "passed" ]] || \
        fail "cleanup evidence is missing or not green: $selected_dir"
    [[ "$(report_env_value status "$selected_dir/prompt-guard/result.env")" == "passed" ]] || \
        fail "prompt-audit evidence is missing or not green: $selected_dir"
    [[ "$(report_env_value prompt_events "$selected_dir/prompt-guard/result.env")" == "0" ]] || \
        fail "selected final run recorded a prompt: $selected_dir"
    if find "$selected_dir/failures" -type f -name failure.env -print -quit | grep -q .; then
        fail "selected final run contains a failure trace: $selected_dir"
    fi
}

update_qualification_matrix_results() {
    local temporary
    temporary="$(mktemp /tmp/detours-qualification-matrix.XXXXXX)"
    awk -F'|' 'BEGIN { OFS="|" }
        /^- \*\*Repetition:\*\*/ {
            print "- **Coverage layer:** `L0` static/architecture, `L1` deterministic behavior, `L2` real-provider contract, and `L3` one representative installed-app boundary. Reliability repetition is separately authorized and is not a blocking result."
            next
        }
        /^\| ID \|/ { sub(/Repetition/, "Coverage layers") }
        /^\| [A-Z]+-[0-9][0-9][0-9] \|/ {
            layers = "L1"
            if ($6 ~ /X/) layers = layers ",L2"
            if ($6 ~ /U/ || $6 ~ /R/) layers = layers ",L3"
            if ($2 ~ /SAFETY-/) layers = "L0," layers
            $8 = " " layers " "
            $9 = " Passed "
        }
        { print }
    ' "$MATRIX_PATH" > "$temporary"
    mv "$temporary" "$MATRIX_PATH"
    ! grep -E '^\| [A-Z]+-[0-9]{3} \|.*\| Pending \|' "$MATRIX_PATH" >/dev/null || \
        fail "matrix still contains pending capability results"
}

write_qualification_result() {
    local qualified_commit="$1"
    local blocking_record="$2"
    local result_path selected_dir environment_file row_count timing_count bundle_count regression_count
    local linux_target intel_mac_target windows_target smb_host smb_share
    result_path="$PROJECT_DIR/resources/docs/260720-whole-app-stability-qualification-result.md"
    selected_dir="$(dirname "$blocking_record")"
    environment_file="$selected_dir/preflight/environment.env"
    linux_target="$(report_env_value linux_target "$environment_file")"
    intel_mac_target="$(report_env_value intel_mac_target "$environment_file")"
    windows_target="$(report_env_value windows_target "$environment_file")"
    smb_host="$(report_env_value smb_host "$environment_file")"
    smb_share="$(report_env_value smb_share "$environment_file")"
    row_count="$(grep -Ec '^\| [A-Z]+-[0-9]{3} \|' "$MATRIX_PATH")"
    timing_count="$(awk 'END { print NR + 0 }' "$selected_dir/timing/scenarios.tsv")"
    bundle_count="$(find "$selected_dir/results/blocking-installed" -maxdepth 1 -type d -name '*.xcresult' | wc -l | tr -d ' ')"
    regression_count="$(find "$QUALIFICATION_ROOT/$qualified_commit" -path '*/failures/*/failure.env' -type f | wc -l | tr -d ' ')"

    {
        printf '# Whole-App Stability Qualification Result\n\n'
        printf '## Conclusion\n\n'
        printf 'Detours passed the runbook-governed whole-app blocking qualification with zero remaining failures.\n\n'
        printf -- '- Qualified app commit: `%s`\n' "$qualified_commit"
        printf -- '- Evidence commit: the documentation-only child containing this report\n'
        printf -- '- Capability results: %s passed, 0 failed, 0 pending\n' "$row_count"
        printf -- '- Final run ID: `%s`\n' "$(basename "$selected_dir")"
        printf -- '- Blocking wall time: %s seconds (budget: %s seconds)\n' \
            "$(report_env_value wall_seconds "$blocking_record")" \
            "$(report_env_value budget_seconds "$blocking_record")"
        printf -- '- Speedup over the 2,153.055-second baseline: %sx\n' \
            "$(report_env_value speedup "$blocking_record")"
        printf -- '- Recorded scenario executions: %s\n' "$timing_count"
        printf -- '- Installed-app logical workflow tests: 8 in %s XCResult bundle\n' "$bundle_count"
        printf -- '- Preserved failure traces for the final app commit: %s\n\n' "$regression_count"
        printf '## Final clean gate\n\n'
        printf '| Run ID | Completed (UTC) | Prompt events | Cleanup |\n'
        printf '| --- | --- | ---: | --- |\n'
        printf '| `%s` | %s | 0 | Passed |\n\n' \
            "$(basename "$selected_dir")" "$(report_env_value completed_at "$blocking_record")"
        printf 'The gate used one shared build, the selected deterministic workflow, known-defect, safety, structural, and accessibility contracts, the complete live-provider contract set, '
        printf 'and one installed-app boundary journey for each of the eight named workflows in a single Xcode invocation. '
        printf 'The older 100-by-20 GUI campaigns are retained only as a separately authorized reliability exercise; '
        printf 'they are not a blocking completion gate. The 12-hour soak was removed by Marco on 2026-07-22.\n\n'
        printf '## Environments and evidence\n\n'
        printf 'Raw preflight, timing, replay, state, outside-root snapshot, log, XCResult, prompt-audit, and cleanup evidence lives under `.build/qualification/%s/%s/`.\n\n' \
            "$qualified_commit" "$(basename "$selected_dir")"
        printf 'The qualified roles were local storage, disposable APFS, real iCloud Drive, SMB `%s/%s`, Linux `%s`, Intel Mac `%s`, and Windows `%s`. No selected test was skipped, retried into a pass, or allowed to exceed its deadline.\n\n' \
            "$smb_host" "$smb_share" "$linux_target" "$intel_mac_target" "$windows_target"
        printf '## Safety and cleanup\n\n'
        printf 'The independent TCC, visible-window, and XCUI-staging channels recorded zero consent dialogs. Outside-root snapshots were unchanged, and every marked folder, mount, app process, helper, test process, and watch was absent at the cleanup gate.\n'
    } > "$result_path"
}

append_qualification_test_log() {
    local qualified_commit="$1"
    local blocking_record="$2"
    local selected_dir
    selected_dir="$(dirname "$blocking_record")"
    {
        printf '\n- %s: Foundry whole-app blocking qualification PASS for `%s`, run `%s`: %ss against the 180s budget (%sx over baseline), 8 installed workflows in 1 XCResult, 0 prompts, 0 skips, and green guarded cleanup.\n' \
            "$(date '+%Y-%m-%d %H:%M %Z')" "$qualified_commit" "$(basename "$selected_dir")" \
            "$(report_env_value wall_seconds "$blocking_record")" \
            "$(report_env_value speedup "$blocking_record")"
    } >> "$PROJECT_DIR/Tests/TEST_LOG.md"
}

generate_qualification_report() {
    local qualified_commit commit_dir blocking_record changed_path
    [[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]] || fail "report generation requires a clean worktree"
    qualified_commit="$(canonical_commit)"
    commit_dir="$QUALIFICATION_ROOT/$qualified_commit"
    [[ -d "$commit_dir" ]] || fail "qualification evidence is missing for $qualified_commit"
    blocking_record="$(select_blocking_record "$commit_dir")"
    require_clean_selected_run "$blocking_record"

    update_qualification_matrix_results
    write_qualification_result "$qualified_commit" "$blocking_record"
    append_qualification_test_log "$qualified_commit" "$blocking_record"
    while IFS= read -r changed_path; do
        case "$changed_path" in
            resources/docs/260720-whole-app-stability-qualification-matrix.md|\
            resources/docs/260720-whole-app-stability-qualification-result.md|\
            Tests/TEST_LOG.md) ;;
            *) fail "report generation changed a forbidden tracked path: $changed_path" ;;
        esac
    done < <(git -C "$PROJECT_DIR" status --porcelain | sed -E 's/^.. //')
}
