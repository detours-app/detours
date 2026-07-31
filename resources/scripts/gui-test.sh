#!/bin/bash

# Runs `swift test` inside the logged-in GUI session on this machine.
#
# An SSH session cannot reach the services that belong to the console user's login session.
# NSPasteboard is the one that bites: `NSPasteboard.general.setString` silently returns false
# over SSH, so every test that copies or pastes fails for a reason that has nothing to do with
# the code under test. Submitting the run through launchd puts it in the console user's domain,
# where those services answer normally.
#
# Usage: resources/scripts/gui-test.sh [swift test arguments...]
#   resources/scripts/gui-test.sh --filter ClipboardManagerTests

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
DEADLINE_SECONDS="${DETOURS_GUI_TEST_DEADLINE:-1800}"

command -v launchctl >/dev/null 2>&1 || {
    printf 'gui-test: launchctl is unavailable\n' >&2
    exit 69
}

label="detours.gui-test.$(uuidgen)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/detours-gui-test.XXXXXX")"
log_path="$work_dir/test.log"
status_path="$work_dir/status"
runner_path="$work_dir/run.sh"

cleanup() {
    launchctl remove "$label" 2>/dev/null || true
    rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# launchd gives the job no working directory and a bare environment, so the command is
# materialised as a script rather than threaded through `env`, which on macOS cannot change
# directory for its child.
{
    printf '#!/bin/bash\n'
    printf 'cd %q || exit 1\n' "$PROJECT_DIR"
    printf 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin\n'
    printf 'exec /usr/bin/swift test'
    for argument in "$@"; do
        printf ' %q' "$argument"
    done
    printf '\n'
} > "$runner_path"
chmod +x "$runner_path"

# `launchctl submit` restarts a job that exits, so the wrapper records the status and the
# job is removed the moment that status appears.
launchctl submit \
    -l "$label" \
    -o "$work_dir/launch.out" \
    -e "$work_dir/launch.err" \
    -- "$SCRIPT_DIR/qualification-gui-command.sh" "$log_path" "$status_path" "$runner_path" || {
    printf 'gui-test: the GUI job could not be submitted\n' >&2
    exit 70
}

emitted_lines=0
emit_new_output() {
    local total
    [[ -f "$log_path" ]] || return 0
    total="$(wc -l < "$log_path" | tr -d '[:space:]')"
    if (( total > emitted_lines )); then
        sed -n "$((emitted_lines + 1)),${total}p" "$log_path"
        emitted_lines="$total"
    fi
}

started_at="$(date +%s)"
while [[ ! -f "$status_path" ]]; do
    emit_new_output
    if (( $(date +%s) - started_at >= DEADLINE_SECONDS )); then
        launchctl remove "$label" 2>/dev/null || true
        emit_new_output
        printf 'gui-test: the run exceeded its %ss deadline and was stopped\n' "$DEADLINE_SECONDS" >&2
        exit 75
    fi
    sleep 1
done

launchctl remove "$label" 2>/dev/null || true
emit_new_output

status="$(cat "$status_path")"
[[ "$status" =~ ^[0-9]+$ ]] || {
    printf 'gui-test: the GUI job recorded an unreadable status: %s\n' "$status" >&2
    exit 70
}
exit "$status"
