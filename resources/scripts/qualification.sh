#!/bin/bash

# One-time whole-app stability qualification runner.
# Operational modes intentionally refuse to run anywhere except Foundry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MATRIX_PATH="$PROJECT_DIR/resources/docs/260720-whole-app-stability-qualification-matrix.md"
QUALIFICATION_ROOT="$PROJECT_DIR/.build/qualification"
LOCAL_PARENT="$HOME/DetoursQualification"
ICLOUD_PARENT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Detours Qualification"
SMB_MOUNT_POINT="/Volumes/Detours Qualification"
APP_BUNDLE_ID="com.detours.app"
QUALIFICATION_KEYCHAIN_SERVICE="com.detours.qualification"
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

usage() {
    cat <<'USAGE'
Usage: resources/scripts/qualification.sh <command> [options]

Commands:
  audit-matrix                  Audit capability-source-check traceability
  preflight                    Validate Foundry and all live environments
  reset                        Remove exact marked qualification state
  fixtures                     Create and mount every guarded fixture root
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
    [[ -e "$target" || -L "$target" ]] || return
    rm -rf -- "$target"
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
    local destination metadata_path
    destination="$(run_dir)"
    mkdir -p "$destination/commands"
    metadata_path="$destination/commands/$(date +%s)-$$-$COMMAND.env"
    {
        printf 'command=%s\n' "$COMMAND"
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'run_id=%s\n' "$QUALIFICATION_RUN_ID"
        printf 'seed=%s\n' "$QUALIFICATION_SEED"
        printf 'cold_index=%s\n' "$QUALIFICATION_COLD_INDEX"
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
    local requested_commit head_commit current_branch free_kilobytes boot_epoch
    requested_commit="$(canonical_commit)"
    head_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    [[ "$head_commit" == "$requested_commit" ]] || fail "HEAD $head_commit does not match requested commit $requested_commit"
    current_branch="$(git -C "$PROJECT_DIR" branch --show-current)"
    [[ "$current_branch" == "testing/whole-app-stability-qualification" ]] || fail "Foundry is on unexpected branch: $current_branch"
    [[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]] || fail "Foundry worktree is not clean"

    audit_matrix
    free_kilobytes="$(df -Pk "$PROJECT_DIR" | awk 'NR == 2 { print $4 }')"
    is_unsigned_integer "$free_kilobytes" || fail "could not read free storage"
    (( free_kilobytes >= MINIMUM_FREE_KILOBYTES )) || fail "qualification needs at least 50 GB free"
    boot_epoch="$(sysctl -n kern.boottime | sed -E 's/^.*sec = ([0-9]+).*$/\1/')"
    is_unsigned_integer "$boot_epoch" || fail "could not read Foundry boot time"

    local host
    for host in devtest wraith win-carriercall; do
        ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" true >/dev/null 2>&1 || fail "required host is unreachable: $host"
    done
    nc -G 8 -z devtest 445 >/dev/null 2>&1 || fail "devtest SMB port 445 is unreachable"

    [[ -d "$ICLOUD_PARENT" ]] || fail "iCloud qualification parent is missing: $ICLOUD_PARENT"
    if find "$ICLOUD_PARENT" -name '*.icloud' -print -quit | grep -q .; then
        fail "iCloud qualification parent contains non-local placeholders"
    fi

    [[ -n "${DETOURS_SMB_TEST_PASSWORD:-}" ]] || fail "DETOURS_SMB_TEST_PASSWORD is required for non-logging SMB authentication"
    require_command expect
    DETOURS_SMB_TEST_PASSWORD="$DETOURS_SMB_TEST_PASSWORD" expect <<'EXPECT' >/dev/null 2>&1 || fail "SMB authentication failed"
        log_user 0
        set timeout 15
        spawn smbutil view //detours-qualification@devtest
        expect {
            -re {(?i)password.*:} { send -- "$env(DETOURS_SMB_TEST_PASSWORD)\r"; exp_continue }
            eof { catch wait result; exit [lindex $result 3] }
            timeout { exit 124 }
        }
EXPECT

    ! pgrep -x Detours >/dev/null 2>&1 || fail "Detours is running"
    ! pgrep -x detours-server >/dev/null 2>&1 || fail "a local detours-server process is running"
    [[ ! -e "$QUALIFICATION_ROOT/.soak-active" ]] || fail "a prior qualification soak marker remains"
    ! mount | grep -F "$SMB_MOUNT_POINT" >/dev/null 2>&1 || fail "qualification SMB share is still mounted"
    ! mount | grep -E '/Volumes/DetoursQualification-[0-9a-f-]{36}' >/dev/null 2>&1 || fail "qualification APFS image is still mounted"
    ! defaults read "$APP_BUNDLE_ID" >/dev/null 2>&1 || fail "Detours preferences remain; run reset"
    [[ ! -e "$HOME/Library/Caches/$APP_BUNDLE_ID" ]] || fail "Detours cache remains; run reset"
    [[ ! -e "$HOME/Library/Saved Application State/$APP_BUNDLE_ID.savedState" ]] || fail "Detours saved state remains; run reset"
    [[ ! -e "$HOME/DetoursUITests-Temp" ]] || fail "UI test fixture root remains; run reset"
    ! security find-generic-password -s "$QUALIFICATION_KEYCHAIN_SERVICE" >/dev/null 2>&1 || fail "qualification Keychain credential remains; run reset"

    mkdir -p "$(run_dir)/preflight"
    {
        printf 'commit=%s\n' "$head_commit"
        printf 'branch=%s\n' "$current_branch"
        printf 'host=%s\n' "$(host_name)"
        printf 'free_kilobytes=%s\n' "$free_kilobytes"
        printf 'boot_epoch=%s\n' "$boot_epoch"
        printf 'macos=%s\n' "$(sw_vers -productVersion)"
        printf 'xcode=%s\n' "$(xcodebuild -version | tr '\n' ' ')"
        printf 'swift=%s\n' "$(swift --version | head -1)"
        printf 'checked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(run_dir)/preflight/environment.env"
}

run_reset() {
    pkill -x Detours >/dev/null 2>&1 || true
    local _
    for _ in {1..50}; do
        pgrep -x Detours >/dev/null 2>&1 || break
        sleep 0.1
    done
    ! pgrep -x Detours >/dev/null 2>&1 || fail "Detours did not stop during reset"

    local guard_binary=""
    if guard_binary="$(qualification_guard 2>/dev/null)"; then
        local parent sentinel
        for parent in "$LOCAL_PARENT" "$ICLOUD_PARENT"; do
            [[ -d "$parent" ]] || continue
            while IFS= read -r sentinel; do
                "$guard_binary" remove --descriptor "$sentinel"
            done < <(find "$parent" -mindepth 2 -maxdepth 2 -type f -name '.detours-qualification-root.json' | sort)
        done
        run_cleanup
    fi

    if mount | grep -F "$SMB_MOUNT_POINT" >/dev/null 2>&1; then
        diskutil unmount "$SMB_MOUNT_POINT" >/dev/null
    fi
    local mounted_apfs
    while IFS= read -r mounted_apfs; do
        [[ -n "$mounted_apfs" ]] || continue
        diskutil unmount "$mounted_apfs" >/dev/null
    done < <(mount | sed -nE 's|^.* on (/Volumes/DetoursQualification-[0-9a-f-]{36}) \(.*$|\1|p')

    defaults delete "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
    security delete-generic-password -s "$QUALIFICATION_KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
    remove_exact_tree "$HOME/Library/Caches/$APP_BUNDLE_ID" "$HOME/Library/Caches"
    remove_exact_tree "$HOME/Library/Saved Application State/$APP_BUNDLE_ID.savedState" "$HOME/Library/Saved Application State"
    remove_exact_tree "$HOME/Library/Containers/MAF.DetoursUITests.xctrunner" "$HOME/Library/Containers"
    remove_exact_tree "$HOME/DetoursUITests-Temp" "$HOME"
    rm -f -- "$QUALIFICATION_ROOT/.soak-active"

    mkdir -p "$(run_dir)/reset"
    printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(run_dir)/reset/result.env"
}

run_build() {
    mkdir -p "$(run_dir)/logs"
    DETOURS_BUILD_FORCE_QUIT=1 DETOURS_BUILD_SKIP_RELAUNCH=1 \
        "$SCRIPT_DIR/build.sh" --no-install 2>&1 | tee "$(run_dir)/logs/build.log"
}

run_cold() {
    [[ "$QUALIFICATION_COLD_INDEX" != "0" ]] || fail "cold-run requires --cold-index 1, 2, or 3"
    trap 'campaign_cleanup_on_exit "$?"' EXIT
    run_reset
    run_preflight
    run_build
    run_prepare_fixtures
    capture_outside_root_snapshots before
    capture_state_observation cold-before
    "$0" in-process all --commit "$(canonical_commit)" --run-id "$QUALIFICATION_RUN_ID" --seed "$QUALIFICATION_SEED" --cold-index "$QUALIFICATION_COLD_INDEX"
    "$0" installed all --commit "$(canonical_commit)" --run-id "$QUALIFICATION_RUN_ID" --seed "$QUALIFICATION_SEED" --cold-index "$QUALIFICATION_COLD_INDEX"
    capture_state_observation cold-after
    capture_outside_root_snapshots after
    compare_outside_root_snapshots
    run_cleanup
    verify_qualification_cleanup
    {
        printf 'status=passed\n'
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'cold_index=%s\n' "$QUALIFICATION_COLD_INDEX"
        printf 'seed=%s\n' "$QUALIFICATION_SEED"
        printf 'boot_epoch=%s\n' "$(sed -n 's/^boot_epoch=//p' "$(run_dir)/preflight/environment.env")"
        printf 'completed_epoch=%s\n' "$(date +%s)"
        printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(run_dir)/cold.env"
    trap - EXIT
}

run_soak() {
    run_twelve_hour_soak
}

run_report() {
    generate_qualification_report
}

run_cleanup() {
    local descriptors_dir descriptor guard_binary
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
    if [[ -d "$descriptors_dir" ]]; then
        guard_binary="$(qualification_guard)"
        while IFS= read -r descriptor; do
            "$guard_binary" remove --descriptor "$descriptor"
        done < <(find "$descriptors_dir" -maxdepth 1 -type f -name '*.json' | sort)
    fi

    cleanup_fixture_mounts
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-fixtures.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-workflows.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-soak.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-evidence.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-report.sh"

run_all() {
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
prepare_evidence_layout
export QUALIFICATION_FAILURE_CAPTURED=0
trap 'qualification_on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

case "$COMMAND" in
    preflight) run_preflight ;;
    reset) run_reset ;;
    fixtures) run_prepare_fixtures ;;
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
