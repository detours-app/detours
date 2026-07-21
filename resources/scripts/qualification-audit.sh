#!/bin/bash

# Capability traceability audit sourced only by qualification.sh.

qualification_check_catalog() {
    cat <<'CATALOG'
Q.accessibility|full-installed
Q.activation|activation
Q.allWorkflows|full-campaign
Q.archives|archive
Q.cleanup|safety
Q.connections|connection
Q.crossPaneTransfer|transfer
Q.fileMutations|mutation
Q.menuAndKeyboard|full-installed
Q.menuAndWindowCommands|full-installed
Q.openAndInspect|opening
Q.referenceImages|reference-images
Q.refreshAndView|refresh
Q.reliability|full-campaign
Q.sessionAppearance|session
Q.sidebarVolumes|full-installed
CATALOG
}

installed_filter_pair_exists() {
    local class_name="$1"
    local method_name="$2"
    awk -v wanted_class="$class_name" -v wanted_method="$method_name" '
        $1 == "final" && $2 == "class" {
            current_class = $3
            sub(/:.*/, "", current_class)
        }
        $1 == "class" {
            current_class = $2
            sub(/:.*/, "", current_class)
        }
        current_class == wanted_class && $1 == "func" {
            current_method = $2
            sub(/\(.*/, "", current_method)
            if (current_method == wanted_method) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$PROJECT_DIR"/Tests/UITests/DetoursUITests/DetoursUITests/*.swift
}

audit_installed_test_filters() {
    local group filter class_name method_name
    while IFS= read -r group; do
        filter="$(installed_test_filter "$group")"
        class_name="${filter%%/*}"
        method_name="${filter#*/}"
        [[ -n "$class_name" && -n "$method_name" && "$class_name" != "$method_name" ]] || \
            fail "installed workflow has an invalid test filter: $group=$filter"
        installed_filter_pair_exists "$class_name" "$method_name" || \
            fail "installed workflow filter does not resolve to one test method: $group=$filter"
    done < <(workflow_groups)
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

    local qualification_check catalog_entry gate
    while IFS= read -r qualification_check; do
        catalog_entry="$(qualification_check_catalog | grep -F "$qualification_check|" || true)"
        [[ -n "$catalog_entry" ]] || fail "matrix campaign check is not routed: $qualification_check"
        gate="${catalog_entry#*|}"
        case "$gate" in
            activation|refresh|transfer|mutation|connection|archive|session|opening|\
            full-installed|full-campaign|safety|reference-images) ;;
            *) fail "matrix campaign check has an unknown gate: $catalog_entry" ;;
        esac
    done < <(grep -Eo 'Q\.[[:alnum:]]+' "$MATRIX_PATH" | sort -u)

    while IFS='|' read -r qualification_check gate; do
        grep -F "$qualification_check" "$MATRIX_PATH" >/dev/null || \
            fail "campaign check catalog entry is unused: $qualification_check"
    done < <(qualification_check_catalog)

    audit_installed_test_filters

    printf 'matrix audit passed: %s capability rows\n' "$row_count"
}
