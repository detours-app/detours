#!/bin/bash
# lint-ignore: max-lines -- single entry point: usage, argument parsing and command dispatch for
# the qualification surface belong together, and the campaign and workflow bodies already live
# in their own sourced files.

# One-time whole-app stability qualification runner.
# Operational modes intentionally refuse to run anywhere except Foundry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export MATRIX_PATH="$PROJECT_DIR/resources/docs/260720-whole-app-stability-qualification-matrix.md"
QUALIFICATION_ROOT="$PROJECT_DIR/.build/qualification"
# shellcheck disable=SC2034 # Consumed by sourced qualification modules.
# /Users/Shared, not the home directory: macOS 14 container data protection denies the
# sandboxed XCUI runner any write inside a per-user directory, which is Apple's documented
# reason to keep cross-process test fixtures here.
LOCAL_PARENT="/Users/Shared/DetoursQualification"
# The XCUI runner is App Sandboxed by Xcode's own runner template, with a read-only
# exception for "/", so control files it writes must live inside its container.
# shellcheck disable=SC2034 # Consumed by sourced qualification modules.
RUNNER_CONTROL_PARENT="$HOME/Library/Containers/MAF.DetoursUITests.xctrunner/Data/DetoursQualification"
# shellcheck disable=SC2034 # Consumed by sourced qualification modules.
ICLOUD_PARENT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Detours Qualification"
SMB_MOUNT_POINT=""
# shellcheck disable=SC2034 # Consumed by sourced qualification modules.
APP_BUNDLE_ID="com.detours.app"
# shellcheck disable=SC2034 # Consumed by sourced qualification modules.
QUALIFICATION_KEYCHAIN_SERVICE="com.detours.qualification"
# shellcheck disable=SC2034 # Consumed by sourced qualification modules.
MINIMUM_FREE_KILOBYTES=$((50 * 1024 * 1024))

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

qualification_smb_mounter() {
    local release_mounter="$PROJECT_DIR/.build/arm64-apple-macosx/release/detours-qualification-smb-mounter"
    local debug_mounter="$PROJECT_DIR/.build/arm64-apple-macosx/debug/detours-qualification-smb-mounter"
    if [[ -x "$release_mounter" ]]; then
        printf '%s\n' "$release_mounter"
    elif [[ -x "$debug_mounter" ]]; then
        printf '%s\n' "$debug_mounter"
    else
        fail "qualification SMB mounter is not built; run the build command first"
    fi
}

usage() {
    cat <<'USAGE'
Usage: resources/scripts/qualification.sh <command> [options]

Commands:
  audit-matrix                  Audit capability-source-check traceability
  preflight                    Validate Foundry and all live environments
  reset                        Remove exact marked qualification state
  smb-auth                     Validate SMB authentication without mounting
  fixtures                     Create and mount every guarded fixture root
  build                        Build the qualifying app without installing it
  blocking                     Run the whole-app blocking gate (hard limit: 180s)
  blocking-refresh             Run the focused refresh blocking gate (hard limit: 180s)
  in-process <group|all>       Gate 2 only: run 100 times in process
  in-process-run <group|all>   Gate 2 only: guarded in-process campaign
  installed <group|all>        Gate 2 only: run 20 installed-app cycles
  workflow-run <group|all>     Gate 2 only: run both repeated layers
  installed-smoke <group> <root|target>
                               Run focused installed repetitions in one audit session
  installed-all <root>         Run every installed UI test once in one audit session
  visibility-probe             Prove live progress, failure reporting, and termination
  failure-probe <provider>     Prove one provider failure is preserved and cleaned
  cold-run                     Separately authorized reliability campaign only
  soak                         Disabled; requires a separate future authorization
  report                       Generate the tracked matrix and result report
  cleanup                      Remove exact marked qualification state
  cancel                       Stop the exact active GUI job for a run
  run                          Run the whole-app blocking qualification
  help                         Show this help

Options:
  --commit <sha>                Exact clean commit to qualify (default: HEAD)
  --run-id <id>                Evidence run identifier (default: generated UUID)
  --seed <unsigned-integer>     Replay scenario order and fixture-name choices
  --in-process-repetitions <1-100>
                               Focused in-process repetition count (default: 100)
  --smoke-repetitions <1-20>    Installed-smoke repetition count (default: 1)
  --test-filter <Class/method>   Installed-smoke XCUI filter override
  --cold-index <1|2|3>          Cold-run sequence number
  --linux-target <ssh-alias>    Linux qualification endpoint (default: devtest)
  --intel-mac-target <alias>    Intel Mac qualification endpoint (default: wraith)
  --windows-target <alias>      Windows qualification endpoint (default: detours-windows)
  --smb-host <host>             SMB qualification endpoint (default: devtest)
  --smb-share <name>            SMB qualification share (default: Detours Qualification)
  --smb-user <name>             SMB qualification account (default: detours-qualification)

Named workflow groups:
  activation
  refresh
  transfer
  mutation
  connection
  archive
  session
  opening

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

path_is_within() {
    local candidate="$1"
    local parent="$2"
    [[ "$candidate" == "$parent" || "$candidate" == "$parent/"* ]]
}

remove_exact_tree() {
    local target="$1"
    local allowed_parent="$2"
    [[ -n "$target" && -n "$allowed_parent" ]] || fail "refusing cleanup with an empty path"
    [[ "$target" != "/" && "$allowed_parent" != "/" ]] || fail "refusing broad cleanup path"
    path_is_within "$target" "$allowed_parent" || fail "cleanup target escapes $allowed_parent: $target"
    [[ -e "$target" || -L "$target" ]] || return 0
    rm -rf -- "$target"
}

canonical_commit() {
    git -C "$PROJECT_DIR" rev-parse "${QUALIFICATION_COMMIT}^{commit}"
}

new_run_id() {
    require_command uuidgen
    uuidgen | tr '[:upper:]' '[:lower:]'
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
            --in-process-repetitions)
                [[ $# -ge 2 ]] || fail "--in-process-repetitions requires a value"
                QUALIFICATION_IN_PROCESS_REPETITIONS="$2"
                shift 2
                ;;
            --smoke-repetitions)
                [[ $# -ge 2 ]] || fail "--smoke-repetitions requires a value"
                QUALIFICATION_SMOKE_REPETITIONS="$2"
                shift 2
                ;;
            --test-filter)
                [[ $# -ge 2 ]] || fail "--test-filter requires a value"
                QUALIFICATION_TEST_FILTER="$2"
                shift 2
                ;;
            --cold-index)
                [[ $# -ge 2 ]] || fail "--cold-index requires a value"
                QUALIFICATION_COLD_INDEX="$2"
                shift 2
                ;;
            --linux-target)
                [[ $# -ge 2 ]] || fail "--linux-target requires a value"
                QUALIFICATION_LINUX_TARGET="$2"
                shift 2
                ;;
            --intel-mac-target)
                [[ $# -ge 2 ]] || fail "--intel-mac-target requires a value"
                QUALIFICATION_INTEL_MAC_TARGET="$2"
                shift 2
                ;;
            --windows-target)
                [[ $# -ge 2 ]] || fail "--windows-target requires a value"
                QUALIFICATION_WINDOWS_TARGET="$2"
                shift 2
                ;;
            --smb-host)
                [[ $# -ge 2 ]] || fail "--smb-host requires a value"
                QUALIFICATION_SMB_HOST="$2"
                shift 2
                ;;
            --smb-share)
                [[ $# -ge 2 ]] || fail "--smb-share requires a value"
                QUALIFICATION_SMB_SHARE="$2"
                shift 2
                ;;
            --smb-user)
                [[ $# -ge 2 ]] || fail "--smb-user requires a value"
                QUALIFICATION_SMB_USER="$2"
                shift 2
                ;;
            *) fail "unknown option: $1" ;;
        esac
    done

    is_unsigned_integer "$QUALIFICATION_SEED" || fail "--seed must be an unsigned integer"
    is_unsigned_integer "$QUALIFICATION_IN_PROCESS_REPETITIONS" || \
        fail "--in-process-repetitions must be an integer from 1 through 100"
    (( QUALIFICATION_IN_PROCESS_REPETITIONS >= 1 && QUALIFICATION_IN_PROCESS_REPETITIONS <= 100 )) || \
        fail "--in-process-repetitions must be an integer from 1 through 100"
    is_unsigned_integer "$QUALIFICATION_SMOKE_REPETITIONS" || \
        fail "--smoke-repetitions must be an integer from 1 through 20"
    (( QUALIFICATION_SMOKE_REPETITIONS >= 1 && QUALIFICATION_SMOKE_REPETITIONS <= 20 )) || \
        fail "--smoke-repetitions must be an integer from 1 through 20"
    case "$QUALIFICATION_COLD_INDEX" in
        0|1|2|3) ;;
        *) fail "--cold-index must be 1, 2, or 3" ;;
    esac
    local configured_value
    for configured_value in \
        "$QUALIFICATION_LINUX_TARGET" \
        "$QUALIFICATION_INTEL_MAC_TARGET" \
        "$QUALIFICATION_WINDOWS_TARGET" \
        "$QUALIFICATION_SMB_HOST" \
        "$QUALIFICATION_SMB_SHARE" \
        "$QUALIFICATION_SMB_USER"; do
        [[ -n "$configured_value" && "$configured_value" != *$'\n'* ]] || \
            fail "qualification target values must be non-empty single lines"
    done
}

run_dir() {
    printf '%s/%s/%s\n' "$QUALIFICATION_ROOT" "$(canonical_commit)" "$QUALIFICATION_RUN_ID"
}

write_command_metadata() {
    local destination metadata_path
    destination="$(run_dir)"
    mkdir -p "$destination/commands"
    metadata_path="$destination/commands/$(date +%s)-$$-$COMMAND.env"
    {
        printf 'command=%s\n' "$COMMAND"
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'run_id=%s\n' "$QUALIFICATION_RUN_ID"
        printf 'seed=%s\n' "$QUALIFICATION_SEED"
        printf 'in_process_repetitions=%s\n' "$QUALIFICATION_IN_PROCESS_REPETITIONS"
        printf 'smoke_repetitions=%s\n' "$QUALIFICATION_SMOKE_REPETITIONS"
        printf 'cold_index=%s\n' "$QUALIFICATION_COLD_INDEX"
        printf 'linux_target=%s\n' "$QUALIFICATION_LINUX_TARGET"
        printf 'intel_mac_target=%s\n' "$QUALIFICATION_INTEL_MAC_TARGET"
        printf 'windows_target=%s\n' "$QUALIFICATION_WINDOWS_TARGET"
        printf 'smb_host=%s\n' "$QUALIFICATION_SMB_HOST"
        printf 'smb_share=%s\n' "$QUALIFICATION_SMB_SHARE"
        printf 'smb_user=%s\n' "$QUALIFICATION_SMB_USER"
        printf 'host=%s\n' "$(host_name)"
        printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$metadata_path"
    cp "$metadata_path" "$destination/command.env"
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

run_soak() {
    fail "the 12-hour soak was removed from this qualification on 2026-07-22; a future reliability exercise requires separate authorization"
}

run_report() {
    generate_qualification_report
}

run_cleanup() {
    local descriptors_dir descriptor fixture_file guard_binary
    local progress_dir progress_marker progress_tmp recorded_root root_path
    # First, so a cleanup that fails on a leftover process still puts macOS settings back.
    restore_accessibility_settings
    detach_demo_volumes
    pkill -x Detours >/dev/null 2>&1 || true
    local _
    for _ in {1..50}; do
        pgrep -x Detours >/dev/null 2>&1 || break
        sleep 0.1
    done
    ! pgrep -x Detours >/dev/null 2>&1 || fail "Detours did not stop during cleanup"
    ! pgrep -x xctest >/dev/null 2>&1 || fail "xctest remains active during cleanup"
    ! pgrep -x xcodebuild >/dev/null 2>&1 || fail "xcodebuild remains active during cleanup"

    descriptors_dir="$(run_dir)/roots"
    fixture_file="$(run_dir)/fixtures.env"
    if [[ -f "$descriptors_dir/smb.json" && -f "$fixture_file" ]]; then
        # Cleanup must use the exact mount recorded when the SMB fixture was
        # created. A remount has a different volume identity and must fail
        # closed instead of weakening or rebinding the destructive guard.
        # shellcheck disable=SC1090
        source "$fixture_file"
        verify_smb_fixture_session_access 0
    fi
    if [[ -d "$descriptors_dir" ]]; then
        guard_binary="$(qualification_guard)"
        progress_dir="$(run_dir)/cleanup/removed-roots"
        mkdir -p "$progress_dir"
        while IFS= read -r descriptor; do
            root_path="$(plutil -extract rootPath raw -o - "$descriptor")"
            progress_marker="$progress_dir/$(basename "$descriptor").env"
            if [[ -f "$progress_marker" ]]; then
                recorded_root="$(sed -n 's/^root_path=//p' "$progress_marker")"
                [[ "$recorded_root" == "$root_path" ]] || \
                    fail "cleanup checkpoint does not match descriptor: $descriptor"
                [[ ! -e "$root_path" && ! -L "$root_path" ]] || \
                    fail "checkpointed qualification root reappeared: $root_path"
                continue
            fi
            "$guard_binary" remove --descriptor "$descriptor"
            progress_tmp="$progress_marker.tmp.$$"
            {
                printf 'root_path=%s\n' "$root_path"
                printf 'removed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            } > "$progress_tmp"
            mv "$progress_tmp" "$progress_marker"
        done < <(find "$descriptors_dir" -maxdepth 1 -type f -name '*.json' | sort)
    fi

    cleanup_fixture_mounts
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-fixtures.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-prompts.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-workflows.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-visibility-probe.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-soak.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-evidence.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-report.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-audit.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-failure-probe.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-campaigns.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-blocking.sh"

run_all() {
    run_blocking_qualification
}

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
    shift
fi

QUALIFICATION_COMMIT="HEAD"
QUALIFICATION_RUN_ID=""
QUALIFICATION_SEED="0"
# Absolute ceiling for the whole-target installed run, which has no per-iteration
# heartbeat to bound it.
# shellcheck disable=SC2034 # Consumed by sourced qualification modules.
QUALIFICATION_INSTALLED_ALL_DEADLINE="${DETOURS_QUALIFICATION_INSTALLED_ALL_DEADLINE:-2400}"
QUALIFICATION_IN_PROCESS_REPETITIONS="100"
QUALIFICATION_SMOKE_REPETITIONS="1"
QUALIFICATION_TEST_FILTER=""
QUALIFICATION_COLD_INDEX="0"
QUALIFICATION_LINUX_TARGET="${DETOURS_QUALIFICATION_LINUX_TARGET:-devtest}"
QUALIFICATION_INTEL_MAC_TARGET="${DETOURS_QUALIFICATION_INTEL_MAC_TARGET:-wraith}"
QUALIFICATION_WINDOWS_TARGET="${DETOURS_QUALIFICATION_WINDOWS_TARGET:-detours-windows}"
QUALIFICATION_SMB_HOST="${DETOURS_QUALIFICATION_SMB_HOST:-devtest}"
QUALIFICATION_SMB_SHARE="${DETOURS_QUALIFICATION_SMB_SHARE:-Detours Qualification}"
QUALIFICATION_SMB_USER="${DETOURS_QUALIFICATION_SMB_USER:-detours-qualification}"
GROUP="all"
SMOKE_ROOT=""
FAILURE_PROVIDER=""

case "$COMMAND" in
    in-process|in-process-run|installed|workflow-run)
        if [[ $# -gt 0 && "$1" != --* ]]; then
            GROUP="$1"
            shift
        fi
        ;;
    installed-smoke)
        [[ $# -ge 2 && "$1" != --* && "$2" != --* ]] || \
            fail "installed-smoke requires a workflow group and context"
        GROUP="$1"
        SMOKE_ROOT="$2"
        shift 2
        ;;
    installed-all)
        [[ $# -ge 1 && "$1" != --* ]] || fail "installed-all requires a context"
        SMOKE_ROOT="$1"
        shift
        ;;
    failure-probe)
        [[ $# -gt 0 && "$1" != --* ]] || fail "failure-probe requires a provider"
        FAILURE_PROVIDER="$1"
        shift
        ;;
esac

parse_options "$@"
if [[ "$COMMAND" != "installed-smoke" && "$QUALIFICATION_SMOKE_REPETITIONS" != "1" ]]; then
    fail "--smoke-repetitions is available only with installed-smoke"
fi
if [[ "$COMMAND" != "installed-smoke" && -n "$QUALIFICATION_TEST_FILTER" ]]; then
    fail "--test-filter is available only with installed-smoke"
fi
if [[ -n "$QUALIFICATION_TEST_FILTER" \
    && ! "$QUALIFICATION_TEST_FILTER" =~ ^[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]+$ ]]; then
    fail "--test-filter must be a Class/testMethod identifier"
fi
if [[ "$COMMAND" != "in-process" && "$COMMAND" != "in-process-run" \
    && "$QUALIFICATION_IN_PROCESS_REPETITIONS" != "100" ]]; then
    fail "--in-process-repetitions is available only with in-process or in-process-run"
fi
[[ "$QUALIFICATION_SMB_SHARE" != "." \
    && "$QUALIFICATION_SMB_SHARE" != ".." \
    && "$QUALIFICATION_SMB_SHARE" != */* ]] || \
    fail "--smb-share must be a single path component"
# shellcheck disable=SC2034 # Consumed by sourced qualification modules.
SMB_MOUNT_POINT="/Volumes/$QUALIFICATION_SMB_SHARE"
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
prepare_evidence_layout
export QUALIFICATION_FAILURE_CAPTURED=0
trap 'qualification_on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

case "$COMMAND" in
    preflight) run_preflight ;;
    reset) run_reset ;;
    smb-auth) verify_smb_authentication ;;
    fixtures) run_prepare_fixtures_command ;;
    build) run_build ;;
    blocking) run_blocking_qualification ;;
    blocking-refresh) run_blocking_refresh ;;
    in-process) require_gate2_authorization; run_in_process "$GROUP" ;;
    in-process-run) require_gate2_authorization; run_in_process_campaign "$GROUP" ;;
    installed) require_gate2_authorization; run_installed "$GROUP" ;;
    workflow-run) require_gate2_authorization; run_workflow_campaign "$GROUP" ;;
    installed-smoke) run_installed_smoke_campaign "$GROUP" "$SMOKE_ROOT" ;;
    installed-all) run_installed_all_campaign "$SMOKE_ROOT" ;;
    visibility-probe) run_failure_visibility_probe ;;
    failure-probe) run_provider_failure_probe "$FAILURE_PROVIDER" ;;
    cold-run) require_gate2_authorization; run_cold ;;
    soak) run_soak ;;
    report) run_report ;;
    cleanup) run_cleanup ;;
    cancel) run_cancel ;;
    run) run_all ;;
    *) fail "unknown command: $COMMAND (run '$0 help')" ;;
esac
