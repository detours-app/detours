#!/bin/bash

# One-time whole-app stability qualification runner.
# Operational modes intentionally refuse to run anywhere except Foundry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MATRIX_PATH="$PROJECT_DIR/resources/docs/260720-whole-app-stability-qualification-matrix.md"
QUALIFICATION_ROOT="$PROJECT_DIR/.build/qualification"

qualification_guard() {
    local release_guard="$PROJECT_DIR/.build/arm64-apple-macosx/release/detours-qualification-guard"
    local debug_guard="$PROJECT_DIR/.build/arm64-apple-macosx/debug/detours-qualification-guard"
    if [[ -x "$release_guard" ]]; then
        printf '%s\n' "$release_guard"
    elif [[ -x "$debug_guard" ]]; then
        printf '%s\n' "$debug_guard"
    else
        fail "qualification guard is not built; run the build command first"
    fi
}

usage() {
    cat <<'USAGE'
Usage: resources/scripts/qualification.sh <command> [options]

Commands:
  audit-matrix                  Audit capability-source-check traceability
  preflight                    Validate Foundry and all live environments
  reset                        Remove exact marked qualification state
  build                        Build the qualifying app without installing it
  in-process <group|all>       Run a named workflow 100 times in process
  installed <group|all>        Run a named workflow 20 times in the installed app
  cold-run                     Reset and run one complete cold qualification
  soak                         Run the installed-app campaign for 12 hours
  report                       Generate the tracked matrix and result report
  cleanup                      Remove exact marked qualification state
  run                          Run preflight, build, three cold runs, and soak
  help                         Show this help

Options:
  --commit <sha>                Exact clean commit to qualify (default: HEAD)
  --run-id <id>                Evidence run identifier (default: generated UUID)
  --seed <unsigned-integer>     Replay scenario order and fixture-name choices
  --cold-index <1|2|3>          Cold-run sequence number

Named workflow groups:
  activation
  refresh
  transfer
  mutation
  connection
  archive
  session
  opening

The third cold run must begin after a Foundry reboot recorded by preflight.
USAGE
}

fail() {
    printf 'qualification: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

host_name() {
    if command -v scutil >/dev/null 2>&1; then
        scutil --get LocalHostName 2>/dev/null || hostname -s
    else
        hostname -s
    fi
}

require_foundry() {
    local current_host
    current_host="$(host_name | tr '[:upper:]' '[:lower:]')"
    case "$current_host" in
        foundry|foundry.*) ;;
        *) fail "operational commands run only on Foundry (current host: $current_host)" ;;
    esac
}

canonical_commit() {
    git -C "$PROJECT_DIR" rev-parse "${QUALIFICATION_COMMIT}^{commit}"
}

new_run_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        require_command python3
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

is_unsigned_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

parse_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --commit)
                [[ $# -ge 2 ]] || fail "--commit requires a value"
                QUALIFICATION_COMMIT="$2"
                shift 2
                ;;
            --run-id)
                [[ $# -ge 2 ]] || fail "--run-id requires a value"
                QUALIFICATION_RUN_ID="$2"
                shift 2
                ;;
            --seed)
                [[ $# -ge 2 ]] || fail "--seed requires a value"
                QUALIFICATION_SEED="$2"
                shift 2
                ;;
            --cold-index)
                [[ $# -ge 2 ]] || fail "--cold-index requires a value"
                QUALIFICATION_COLD_INDEX="$2"
                shift 2
                ;;
            *) fail "unknown option: $1" ;;
        esac
    done

    is_unsigned_integer "$QUALIFICATION_SEED" || fail "--seed must be an unsigned integer"
    case "$QUALIFICATION_COLD_INDEX" in
        0|1|2|3) ;;
        *) fail "--cold-index must be 1, 2, or 3" ;;
    esac
}

run_dir() {
    printf '%s/%s/%s\n' "$QUALIFICATION_ROOT" "$(canonical_commit)" "$QUALIFICATION_RUN_ID"
}

write_command_metadata() {
    local destination
    destination="$(run_dir)"
    mkdir -p "$destination"
    {
        printf 'command=%s\n' "$COMMAND"
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'run_id=%s\n' "$QUALIFICATION_RUN_ID"
        printf 'seed=%s\n' "$QUALIFICATION_SEED"
        printf 'cold_index=%s\n' "$QUALIFICATION_COLD_INDEX"
        printf 'host=%s\n' "$(host_name)"
        printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$destination/command.env"
}

workflow_groups() {
    printf '%s\n' activation refresh transfer mutation connection archive session opening
}

validate_group() {
    local requested="$1"
    if [[ "$requested" == "all" ]]; then
        return
    fi
    workflow_groups | grep -Fx "$requested" >/dev/null || fail "unknown workflow group: $requested"
}

audit_matrix() {
    [[ -f "$MATRIX_PATH" ]] || fail "matrix is missing: $MATRIX_PATH"

    local row_count
    row_count="$(grep -Ec '^\| [A-Z]+-[0-9]{3} \|' "$MATRIX_PATH")"
    [[ "$row_count" -gt 0 ]] || fail "matrix contains no capability rows"

    local missing_checks missing_repetitions duplicate_ids
    missing_checks="$(awk -F'|' '/^\| [A-Z]+-[0-9]{3} / { if ($7 ~ /^[[:space:]]*$/ || $7 ~ /TBD/) print $2 }' "$MATRIX_PATH")"
    missing_repetitions="$(awk -F'|' '/^\| [A-Z]+-[0-9]{3} / { if ($8 ~ /^[[:space:]]*$/ || $8 ~ /TBD/) print $2 }' "$MATRIX_PATH")"
    duplicate_ids="$(awk -F'|' '/^\| [A-Z]+-[0-9]{3} / { gsub(/[[:space:]]/, "", $2); print $2 }' "$MATRIX_PATH" | sort | uniq -d)"
    [[ -z "$missing_checks" ]] || fail "matrix rows lack automated checks: $missing_checks"
    [[ -z "$missing_repetitions" ]] || fail "matrix rows lack repetition levels: $missing_repetitions"
    [[ -z "$duplicate_ids" ]] || fail "matrix contains duplicate IDs: $duplicate_ids"

    local source
    for source in \
        src/App/MainMenu.swift \
        src/FileList/FileListViewController+ContextMenu.swift \
        src/FileList/FileListViewController+Keyboard.swift \
        src/FileList/FileListViewController+DragDrop.swift \
        src/Preferences/Settings.swift \
        resources/docs/USER_GUIDE.md; do
        grep -F "$source" "$MATRIX_PATH" >/dev/null || fail "matrix source census is missing $source"
    done

    local spec_name
    while IFS= read -r spec_name; do
        grep -F "${spec_name%.md}" "$MATRIX_PATH" >/dev/null || fail "matrix source census is missing $spec_name"
    done < <(find "$PROJECT_DIR/resources/specs/done" -maxdepth 1 -type f -name '*.md' -exec basename {} \; | sort)

    printf 'matrix audit passed: %s capability rows\n' "$row_count"
}

run_preflight() {
    if [[ "${DETOURS_QUALIFICATION_C4_READY:-0}" != "1" ]]; then
        fail "strict live preflight support is installed by C4"
    fi
}

run_reset() {
    if [[ "${DETOURS_QUALIFICATION_C4_READY:-0}" != "1" ]]; then
        fail "guarded reset support is installed by C4"
    fi
}

run_build() {
    mkdir -p "$(run_dir)/logs"
    DETOURS_BUILD_FORCE_QUIT=1 DETOURS_BUILD_SKIP_RELAUNCH=1 \
        "$SCRIPT_DIR/build.sh" --no-install 2>&1 | tee "$(run_dir)/logs/build.log"
}

run_in_process() {
    local group="$1"
    validate_group "$group"
    if [[ "${DETOURS_QUALIFICATION_C7_READY:-0}" != "1" ]]; then
        fail "in-process workflow support is installed by C7"
    fi
}

run_installed() {
    local group="$1"
    validate_group "$group"
    if [[ "${DETOURS_QUALIFICATION_C7_READY:-0}" != "1" ]]; then
        fail "installed-app workflow support is installed by C7"
    fi
}

run_cold() {
    [[ "$QUALIFICATION_COLD_INDEX" != "0" ]] || fail "cold-run requires --cold-index 1, 2, or 3"
    run_preflight
    run_reset
    run_build
    "$0" in-process all --commit "$(canonical_commit)" --run-id "$QUALIFICATION_RUN_ID" --seed "$QUALIFICATION_SEED" --cold-index "$QUALIFICATION_COLD_INDEX"
    "$0" installed all --commit "$(canonical_commit)" --run-id "$QUALIFICATION_RUN_ID" --seed "$QUALIFICATION_SEED" --cold-index "$QUALIFICATION_COLD_INDEX"
}

run_soak() {
    if [[ "${DETOURS_QUALIFICATION_C8_READY:-0}" != "1" ]]; then
        fail "12-hour soak support is installed by C8"
    fi
}

run_report() {
    if [[ "${DETOURS_QUALIFICATION_C11_READY:-0}" != "1" ]]; then
        fail "tracked report generation is installed by C11"
    fi
}

run_cleanup() {
    local descriptors_dir descriptor guard_binary
    descriptors_dir="$(run_dir)/roots"
    [[ -d "$descriptors_dir" ]] || return
    guard_binary="$(qualification_guard)"
    while IFS= read -r descriptor; do
        "$guard_binary" remove --descriptor "$descriptor"
    done < <(find "$descriptors_dir" -maxdepth 1 -type f -name '*.json' | sort)
}

run_all() {
    run_preflight
    run_build
    local index
    for index in 1 2; do
        "$0" cold-run --commit "$(canonical_commit)" --run-id "$(new_run_id)" --seed "$QUALIFICATION_SEED" --cold-index "$index"
    done
    fail "reboot Foundry before cold run 3, then resume with cold-run --cold-index 3"
}

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
    shift
fi

QUALIFICATION_COMMIT="HEAD"
QUALIFICATION_RUN_ID=""
QUALIFICATION_SEED="0"
QUALIFICATION_COLD_INDEX="0"
GROUP="all"

case "$COMMAND" in
    in-process|installed)
        if [[ $# -gt 0 && "$1" != --* ]]; then
            GROUP="$1"
            shift
        fi
        ;;
esac

parse_options "$@"

case "$COMMAND" in
    help|-h|--help)
        usage
        exit 0
        ;;
    audit-matrix)
        audit_matrix
        exit 0
        ;;
esac

require_foundry
require_command git
[[ -d "$PROJECT_DIR/.git" ]] || fail "project is not a Git worktree: $PROJECT_DIR"
QUALIFICATION_COMMIT="$(canonical_commit)"
if [[ -z "$QUALIFICATION_RUN_ID" ]]; then
    QUALIFICATION_RUN_ID="$(new_run_id)"
fi
write_command_metadata

case "$COMMAND" in
    preflight) run_preflight ;;
    reset) run_reset ;;
    build) run_build ;;
    in-process) run_in_process "$GROUP" ;;
    installed) run_installed "$GROUP" ;;
    cold-run) run_cold ;;
    soak) run_soak ;;
    report) run_report ;;
    cleanup) run_cleanup ;;
    run) run_all ;;
    *) fail "unknown command: $COMMAND (run '$0 help')" ;;
esac
