#!/bin/bash

# Fixture adapters sourced only by qualification.sh.

create_guarded_fixture_root() {
    local provider="$1"
    local parent="$2"
    local descriptor="$3"
    local identifier="$4"
    "$(qualification_guard)" create \
        --provider "$provider" \
        --parent "$parent" \
        --descriptor "$descriptor" \
        --identifier "$identifier"
}

seed_installed_fixture() {
    local root="$1"
    mkdir -p \
        "$root/AAA_First" \
        "$root/BBB_Second/SubfolderB1" \
        "$root/BBB_Second/SubfolderB2" \
        "$root/CCC_Third" \
        "$root/FolderA/SubfolderA1" \
        "$root/FolderA/SubfolderA2" \
        "$root/FolderB/SubfolderB1" \
        "$root/FolderB/SubfolderB2" \
        "$root/FolderC" \
        "$root/FolderD" \
        "$root/Projects2025/Quarterly/Q1" \
        "$root/Projects2025/Quarterly/Q2" \
        "$root/Projects2025/Annual"
    printf 'test\n' > "$root/FolderA/SubfolderA1/file.txt"
    printf 'test\n' > "$root/FolderA/alpha-file.txt"
    printf 'test\n' > "$root/FolderB/beta-file.txt"
    printf 'test\n' > "$root/FolderB/SubfolderB1/nested.txt"
    printf 'test\n' > "$root/file1.txt"
    printf 'test\n' > "$root/file2.txt"
    printf 'target\n' > "$root/zz-target.txt"
    printf 'target\n' > "$root/FolderB/unique-in-B.txt"
    printf 'data\n' > "$root/Projects2025/notes.txt"
}

verify_smb_authentication() {
    [[ "${DETOURS_QUALIFICATION_SECRET_TRANSPORT:-}" == "stdin-v1" ]] || \
        fail "SMB credentials must arrive through qualification-foundry.sh"
    [[ -n "${DETOURS_SMB_TEST_PASSWORD:-}" ]] || fail "SMB credential transport returned an empty value"
    require_command expect
    local auth_status
    set +e
    local smb_auth_url
    smb_auth_url="//$QUALIFICATION_SMB_USER@$QUALIFICATION_SMB_HOST"
    DETOURS_SMB_TEST_PASSWORD="$DETOURS_SMB_TEST_PASSWORD" SMB_AUTH_URL="$smb_auth_url" \
        expect <<'EXPECT' >/dev/null 2>&1
        log_user 0
        set timeout 15
        set password_prompts 0
        spawn smbutil view -f $env(SMB_AUTH_URL)
        expect {
            -nocase -re {password} {
                incr password_prompts
                if {$password_prompts > 1} { exit 77 }
                send -- "$env(DETOURS_SMB_TEST_PASSWORD)\r"
                exp_continue
            }
            eof { catch wait result; exit [lindex $result 3] }
            timeout { exit 124 }
        }
EXPECT
    auth_status=$?
    set -e
    case "$auth_status" in
        0) ;;
        77) fail "SMB authentication was rejected" ;;
        124) fail "SMB authentication timed out" ;;
        *) fail "SMB authentication failed with status $auth_status" ;;
    esac
}

mount_smb_fixture() {
    [[ "${DETOURS_QUALIFICATION_SECRET_TRANSPORT:-}" == "stdin-v1" ]] || \
        fail "SMB credentials must arrive through qualification-foundry.sh"
    [[ -n "${DETOURS_SMB_TEST_PASSWORD:-}" ]] || fail "DETOURS_SMB_TEST_PASSWORD is required to mount the SMB fixture"
    local mount_parent
    mount_parent="$(dirname "$SMB_MOUNT_POINT")"
    mkdir -p "$mount_parent"
    local mount_status
    smbutil logout "$QUALIFICATION_SMB_HOST" >/dev/null 2>&1 || true
    set +e
    SMB_MOUNTER="$(qualification_smb_mounter)" MOUNT_PARENT="$mount_parent" \
        SMB_HOST="$QUALIFICATION_SMB_HOST" SMB_SHARE="$QUALIFICATION_SMB_SHARE" \
        SMB_USER="$QUALIFICATION_SMB_USER" \
        expect <<'EXPECT' >/dev/null 2>&1
        log_user 0
        set timeout 30
        spawn env -u DETOURS_SMB_TEST_PASSWORD \
            DETOURS_QUALIFICATION_SECRET_TRANSPORT=stdin-v1 \
            $env(SMB_MOUNTER) --mount-parent $env(MOUNT_PARENT) \
            --host $env(SMB_HOST) --share $env(SMB_SHARE) --username $env(SMB_USER)
        send -- "$env(DETOURS_SMB_TEST_PASSWORD)\r"
        expect {
            eof { catch wait result; exit [lindex $result 3] }
            timeout { close -force; catch wait result; exit 124 }
        }
EXPECT
    mount_status=$?
    set -e
    case "$mount_status" in
        0) ;;
        124) fail "SMB fixture NetFS mount timed out" ;;
        *) fail "SMB fixture mount failed with status $mount_status" ;;
    esac
    mount | grep -F " on $SMB_MOUNT_POINT " >/dev/null 2>&1 || fail "SMB fixture did not mount at $SMB_MOUNT_POINT"
}

verify_smb_fixture_session_access() {
    local require_gui_probe="${1:-1}"
    local gui_probe_log
    mount | grep -F " on $SMB_MOUNT_POINT " >/dev/null 2>&1 || \
        fail "SMB fixture mount was lost; refusing to remount with a new guard identity"
    [[ -n "${SMB_ROOT:-}" && -d "$SMB_ROOT" ]] || \
        fail "SMB fixture root is unavailable in the current qualification session"
    find "$SMB_ROOT" -maxdepth 1 -name '.detours-qualification-root.json' -print -quit | grep -q . || \
        fail "SMB fixture sentinel is unavailable in the current qualification session"
    if [[ "$require_gui_probe" == "1" ]]; then
        gui_probe_log="$(run_dir)/logs/smb-session-$COMMAND.log"
        run_gui_command "$gui_probe_log" \
            /bin/test -f "$SMB_ROOT/.detours-qualification-root.json" || \
            fail "SMB fixture is unavailable to the current GUI qualification session"
    fi
}

fixture_setup_cleanup_on_exit() {
    local original_status="$1"
    trap - EXIT
    if (( original_status == 0 )); then
        exit 0
    fi
    set +e
    run_cleanup
    local cleanup_status=$?
    if (( cleanup_status == 0 )); then
        verify_qualification_cleanup
        cleanup_status=$?
    fi
    if (( cleanup_status != 0 )); then
        printf 'qualification: partial fixture cleanup failed with status %s\n' "$cleanup_status" >&2
        exit "$cleanup_status"
    fi
    exit "$original_status"
}

run_prepare_fixtures_command() {
    trap 'fixture_setup_cleanup_on_exit "$?"' EXIT
    run_prepare_fixtures
    trap - EXIT
}

run_prepare_fixtures() {
    local destination roots_dir images_dir fixture_file
    destination="$(run_dir)"
    roots_dir="$destination/roots"
    images_dir="$QUALIFICATION_ROOT/images"
    fixture_file="$destination/fixtures.env"
    mkdir -p "$roots_dir" "$images_dir" "$LOCAL_PARENT"
    [[ -d "$ICLOUD_PARENT" ]] || fail "iCloud qualification parent is missing"

    local local_id icloud_id apfs_id smb_id
    local_id="$(new_run_id)"
    icloud_id="$(new_run_id)"
    apfs_id="$(new_run_id)"
    smb_id="$(new_run_id)"

    local volume_name image_path mount_point
    volume_name="DetoursQualification-$apfs_id"
    image_path="$images_dir/$volume_name.sparsebundle"
    mount_point="/Volumes/$volume_name"

    local local_root icloud_root apfs_root smb_root
    local_root="$LOCAL_PARENT/$local_id"
    icloud_root="$ICLOUD_PARENT/$icloud_id"
    apfs_root="$mount_point/$apfs_id"
    smb_root="$SMB_MOUNT_POINT/$smb_id"
    {
        printf 'LOCAL_ROOT=%q\n' "$local_root"
        printf 'APFS_ROOT=%q\n' "$apfs_root"
        printf 'APFS_IMAGE=%q\n' "$image_path"
        printf 'APFS_MOUNT=%q\n' "$mount_point"
        printf 'ICLOUD_ROOT=%q\n' "$icloud_root"
        printf 'SMB_ROOT=%q\n' "$smb_root"
        printf 'LINUX_TARGET=%q\n' "$QUALIFICATION_LINUX_TARGET"
        printf 'INTEL_MAC_TARGET=%q\n' "$QUALIFICATION_INTEL_MAC_TARGET"
        printf 'WINDOWS_TARGET=%q\n' "$QUALIFICATION_WINDOWS_TARGET"
        printf 'SMB_HOST=%q\n' "$QUALIFICATION_SMB_HOST"
        printf 'SMB_SHARE=%q\n' "$QUALIFICATION_SMB_SHARE"
        printf 'SMB_USER=%q\n' "$QUALIFICATION_SMB_USER"
    } > "$fixture_file"

    [[ "$(create_guarded_fixture_root local "$LOCAL_PARENT" "$roots_dir/local.json" "$local_id")" == "$local_root" ]] || \
        fail "local fixture root differed from its recorded path"

    brctl download "$ICLOUD_PARENT" >/dev/null 2>&1 || fail "Keep Downloaded request failed for iCloud fixture"
    if find "$ICLOUD_PARENT" -name '*.icloud' -print -quit | grep -q .; then
        fail "iCloud fixture is not fully local after Keep Downloaded"
    fi
    [[ "$(create_guarded_fixture_root iCloud "$ICLOUD_PARENT" "$roots_dir/icloud.json" "$icloud_id")" == "$icloud_root" ]] || \
        fail "iCloud fixture root differed from its recorded path"

    [[ ! -e "$image_path" ]] || fail "APFS fixture image already exists: $image_path"
    hdiutil create -quiet -size 2g -fs APFS -volname "$volume_name" -type SPARSEBUNDLE "$image_path"
    hdiutil attach -quiet -nobrowse "$image_path"
    mount | grep -F " on $mount_point " >/dev/null 2>&1 || fail "APFS fixture did not mount at $mount_point"
    [[ "$(create_guarded_fixture_root apfs "$mount_point" "$roots_dir/apfs.json" "$apfs_id")" == "$apfs_root" ]] || \
        fail "APFS fixture root differed from its recorded path"

    mount_smb_fixture
    [[ "$(create_guarded_fixture_root smb "$SMB_MOUNT_POINT" "$roots_dir/smb.json" "$smb_id")" == "$smb_root" ]] || \
        fail "SMB fixture root differed from its recorded path"

    local fixture_root
    for fixture_root in "$local_root" "$apfs_root" "$icloud_root" "$smb_root"; do
        seed_installed_fixture "$fixture_root"
    done

    printf '%s\n' "$fixture_file"
}

cleanup_fixture_mounts() {
    local fixture_file
    fixture_file="$(run_dir)/fixtures.env"
    [[ -f "$fixture_file" ]] || return 0
    # shellcheck disable=SC1090
    source "$fixture_file"
    if [[ -n "${SMB_ROOT:-}" ]] && mount | grep -F " on $SMB_MOUNT_POINT " >/dev/null 2>&1; then
        diskutil unmount "$SMB_MOUNT_POINT" >/dev/null
    fi
    remove_exact_tree "$SMB_MOUNT_POINT" "$QUALIFICATION_ROOT/mounts"
    if [[ -n "${APFS_MOUNT:-}" ]] && mount | grep -F " on $APFS_MOUNT " >/dev/null 2>&1; then
        hdiutil detach -quiet "$APFS_MOUNT"
    fi
    if [[ -n "${APFS_IMAGE:-}" ]]; then
        remove_exact_tree "$APFS_IMAGE" "$QUALIFICATION_ROOT/images"
    fi
    return 0
}
