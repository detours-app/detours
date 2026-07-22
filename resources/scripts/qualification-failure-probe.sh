#!/bin/bash

# Deliberate provider failure probe sourced only by qualification.sh.

qualification_providers() {
    printf '%s\n' local apfs iCloud smb linux intelMac windows
}

run_provider_failure_probe() {
    local provider="$1"
    qualification_providers | grep -Fx "$provider" >/dev/null || fail "unknown qualification provider: $provider"
    trap 'campaign_cleanup_on_exit "$?"' EXIT
    mkdir -p "$LOCAL_PARENT" "$(run_dir)/roots"

    local descriptor identifier root
    descriptor="$(run_dir)/roots/$provider.json"
    identifier="$(new_run_id)"
    root="$(create_guarded_fixture_root "$provider" "$LOCAL_PARENT" "$descriptor" "$identifier")"
    printf 'failure-probe-seed\n' > "$root/fixture.txt"
    printf '%s\tfailure-probe\t%s\t1\n' "$provider" "$root" >> "$(run_dir)/replay.tsv"
    capture_outside_root_snapshots before
    capture_state_observation "$provider-before-failure"
    capture_outside_root_snapshots after
    compare_outside_root_snapshots

    printf 'qualification: deliberate %s provider failure\n' "$provider" >&2
    return 97
}
