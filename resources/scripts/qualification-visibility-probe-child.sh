#!/bin/bash

# Synthetic long-running GUI job used only by qualification-visibility-probe.sh.

set -euo pipefail

[[ $# -eq 5 ]] || exit 64

heartbeat_dir="$1"
result_bundle="$2"
descendant_pid_file="$3"
late_marker="$4"
lifecycle_file="$5"

for path in "$heartbeat_dir" "$result_bundle" "$descendant_pid_file" "$late_marker" "$lifecycle_file"; do
    [[ "$path" == /* ]] || exit 65
done

mkdir -p "$heartbeat_dir" "$result_bundle/Staging/1_Test"

/bin/sleep 300 &
descendant_pid=$!
printf '%s\n' "$descendant_pid" > "$descendant_pid_file"
trap 'printf "terminated\n" > "$lifecycle_file"; exit 143' HUP INT TERM

heartbeat_tmp="$heartbeat_dir/.detours-qualification-visibility-probe-repetition-001.json.tmp"
printf '{"iteration":1,"total":2}\n' > "$heartbeat_tmp"
mv "$heartbeat_tmp" \
    "$heartbeat_dir/.detours-qualification-visibility-probe-repetition-001.json"

/bin/sleep 1
diagnostic="$result_bundle/Staging/1_Test/StandardOutputAndStandardError.txt"
diagnostic_tmp="$diagnostic.tmp"
printf '%s\n' \
    '/tmp/QualificationHarness.swift:42: error: -[QualificationHarness testFailureVisibility] : XCTAssertTrue failed - deliberate live failure visibility probe' \
    > "$diagnostic_tmp"
mv "$diagnostic_tmp" "$diagnostic"

/bin/sleep 10
printf '{"iteration":2,"total":2}\n' \
    > "$heartbeat_dir/.detours-qualification-visibility-probe-repetition-002.json"
printf 'iteration-two-ran\n' > "$late_marker"
wait "$descendant_pid"
