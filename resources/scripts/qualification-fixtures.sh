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

mount_smb_fixture() {
    [[ -n "${DETOURS_SMB_TEST_PASSWORD:-}" ]] || fail "DETOURS_SMB_TEST_PASSWORD is required to mount the SMB fixture"
    mkdir -p "$SMB_MOUNT_POINT"
    DETOURS_SMB_TEST_PASSWORD="$DETOURS_SMB_TEST_PASSWORD" expect <<EXPECT >/dev/null 2>&1 || fail "SMB fixture mount failed"
        log_user 0
        set timeout 20
        spawn mount_smbfs //detours-qualification@devtest/Detours%20Qualification {$SMB_MOUNT_POINT}
        expect {
            -re {(?i)password.*:} { send -- "\$env(DETOURS_SMB_TEST_PASSWORD)\r"; exp_continue }
            eof { catch wait result; exit [lindex \$result 3] }
            timeout { exit 124 }
        }
EXPECT
    mount | grep -F " on $SMB_MOUNT_POINT " >/dev/null 2>&1 || fail "SMB fixture did not mount at $SMB_MOUNT_POINT"
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

    local local_root icloud_root apfs_root smb_root
    local_root="$(create_guarded_fixture_root local "$LOCAL_PARENT" "$roots_dir/local.json" "$local_id")"

    brctl download "$ICLOUD_PARENT" >/dev/null 2>&1 || fail "Keep Downloaded request failed for iCloud fixture"
    if find "$ICLOUD_PARENT" -name '*.icloud' -print -quit | grep -q .; then
        fail "iCloud fixture is not fully local after Keep Downloaded"
    fi
    icloud_root="$(create_guarded_fixture_root iCloud "$ICLOUD_PARENT" "$roots_dir/icloud.json" "$icloud_id")"

    local volume_name image_path mount_point
    volume_name="DetoursQualification-$apfs_id"
    image_path="$images_dir/$volume_name.sparsebundle"
    mount_point="/Volumes/$volume_name"
    [[ ! -e "$image_path" ]] || fail "APFS fixture image already exists: $image_path"
    hdiutil create -quiet -size 2g -fs APFS -volname "$volume_name" -type SPARSEBUNDLE "$image_path"
    mkdir -p "$mount_point"
    hdiutil attach -quiet -nobrowse -mountpoint "$mount_point" "$image_path"
    apfs_root="$(create_guarded_fixture_root apfs "$mount_point" "$roots_dir/apfs.json" "$apfs_id")"

    mount_smb_fixture
    smb_root="$(create_guarded_fixture_root smb "$SMB_MOUNT_POINT" "$roots_dir/smb.json" "$smb_id")"

    {
        printf 'LOCAL_ROOT=%q\n' "$local_root"
        printf 'APFS_ROOT=%q\n' "$apfs_root"
        printf 'APFS_IMAGE=%q\n' "$image_path"
        printf 'APFS_MOUNT=%q\n' "$mount_point"
        printf 'ICLOUD_ROOT=%q\n' "$icloud_root"
        printf 'SMB_ROOT=%q\n' "$smb_root"
        printf 'LINUX_TARGET=%q\n' devtest
        printf 'INTEL_MAC_TARGET=%q\n' wraith
        printf 'WINDOWS_TARGET=%q\n' win-carriercall
    } > "$fixture_file"
    printf '%s\n' "$fixture_file"
}

cleanup_fixture_mounts() {
    local fixture_file
    fixture_file="$(run_dir)/fixtures.env"
    [[ -f "$fixture_file" ]] || return
    # shellcheck disable=SC1090
    source "$fixture_file"
    if [[ -n "${SMB_ROOT:-}" ]] && mount | grep -F " on $SMB_MOUNT_POINT " >/dev/null 2>&1; then
        diskutil unmount "$SMB_MOUNT_POINT" >/dev/null
    fi
    if [[ -n "${APFS_MOUNT:-}" ]] && mount | grep -F " on $APFS_MOUNT " >/dev/null 2>&1; then
        hdiutil detach -quiet "$APFS_MOUNT"
    fi
    if [[ -n "${APFS_IMAGE:-}" ]]; then
        remove_exact_tree "$APFS_IMAGE" "$QUALIFICATION_ROOT/images"
    fi
}
