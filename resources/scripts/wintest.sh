#!/usr/bin/env bash
# Live Windows remote-test runner.
#
# Streams XCTest output in real time through a pty so every test's start/pass/fail is
# visible the instant it happens (no buffered silence), and bounds the whole run so a hang
# is killed but the streamed log still shows exactly which test stalled.
#
# Usage:   resources/scripts/wintest.sh [filter]
#   filter defaults to WindowsRemoteLiveTests; pass e.g. WindowsRemoteLiveTests/testFoo
# Env:     DETOURS_WINDOWS_TEST_TARGET (default win-carriercall)
#          WINTEST_TIMEOUT  whole-run timeout in seconds (default 420)
#          WINTEST_LOG      log file (default /tmp/detours-wintest.log)
set -uo pipefail

cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
export DETOURS_WINDOWS_TEST_TARGET="${DETOURS_WINDOWS_TEST_TARGET:-win-carriercall}"
filter="${1:-WindowsRemoteLiveTests}"
deadline="${WINTEST_TIMEOUT:-420}"
log="${WINTEST_LOG:-/tmp/detours-wintest.log}"

echo "wintest: target=$DETOURS_WINDOWS_TEST_TARGET filter=$filter timeout=${deadline}s log=$log"
: > "$log"

run_with_timeout() {
    local seconds="$1"
    shift

    "$@" &
    local command_pid="$!"
    (
        sleep "$seconds"
        if kill -0 "$command_pid" 2>/dev/null; then
            kill -TERM "$command_pid" 2>/dev/null || true
        fi
    ) &
    local timer_pid="$!"

    wait "$command_pid"
    local rc="$?"
    if kill -0 "$timer_pid" 2>/dev/null; then
        kill "$timer_pid" 2>/dev/null || true
        wait "$timer_pid" 2>/dev/null || true
        return "$rc"
    fi
    wait "$timer_pid" 2>/dev/null || true
    return 124
}

# `script -q` gives swift test a pty so it line-buffers and streams live; tee mirrors to the
# log so a background run can be tailed for real-time progress. The shell watchdog keeps
# this portable across Foundry's macOS userspace, where GNU `timeout` is not installed.
run_with_timeout "$deadline" script -q /dev/null swift test --filter "$filter" 2>&1 | tee "$log"
rc="${PIPESTATUS[0]}"

if [ "$rc" = "124" ]; then
  echo "wintest: TIMED OUT after ${deadline}s — last test still running (see log tail above)"
fi
exit "$rc"
