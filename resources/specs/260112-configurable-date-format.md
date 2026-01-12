# Configurable Date Format

## Meta
- Status: Draft
- Branch: feature/date-format-setting

---

## Business

### Problem

The Date Modified column in the file list uses hardcoded date formats ("MMM d" for current year, "MMM d, yyyy" for other years). Users may prefer different formats like ISO dates, timestamps with time, or localized formats.

### Solution

Add two free-text date format fields in Appearance settings - one for current year dates, one for other years. Include live validation and preview so users can see the result immediately.

### Behaviors

- Two text fields in Appearance settings under new "Date Format" section
- "Current year" field (default: "MMM d") - used for dates within the current year
- "Other years" field (default: "MMM d, yyyy") - used for dates in previous/future years
- Live preview next to each field showing today's date (or a sample date for "other years") in that format
- Invalid format strings show inline error and revert to default on blur
- Changes apply immediately to file list
- Help text with link to Apple's date format documentation or inline hint showing common specifiers

---

## Technical

### Approach

Add two new String properties to `Settings` struct for the date formats. Update `AppearanceSettingsView` with a new "Date Format" section containing two text fields with live previews. Modify `FileItem.formattedDate` to read formats from `SettingsManager` instead of hardcoded strings. Validation uses `DateFormatter` - if it can format a date without crashing, the format is valid.

**Testing approach:** Use the macOS UI automation MCP server to verify UI elements after building. Run the app in background mode during testing to inspect element positions and values without manual intervention.

### File Changes

**src/Preferences/Settings.swift**
- Add `dateFormatCurrentYear: String = "MMM d"` property to `Settings` struct
- Add `dateFormatOtherYears: String = "MMM d, yyyy"` property to `Settings` struct

**src/Preferences/SettingsManager.swift**
- Add computed properties `dateFormatCurrentYear` and `dateFormatOtherYears` with getters/setters (follow existing pattern like `restoreSession`)

**src/Preferences/AppearanceSettingsView.swift**
- Add new "Date Format" section after font size section
- Add `@State` properties for `dateFormatCurrentYear` and `dateFormatOtherYears`
- Add text field for current year format with live preview (use today's date)
- Add text field for other years format with live preview (use a date from previous year, e.g., Dec 15, 2025)
- Add `DateFormatPreview` helper view that shows formatted date or "Invalid format" in red
- Add small help text: "Uses DateFormatter syntax (e.g., MMM d, yyyy-MM-dd, HH:mm)"
- Validate on change: if format is invalid, show error state but don't save until valid

**src/FileList/FileItem.swift**
- Modify `formattedDate` computed property to read formats from `SettingsManager.shared`
- Replace hardcoded `"MMM d"` with `SettingsManager.shared.dateFormatCurrentYear`
- Replace hardcoded `"MMM d, yyyy"` with `SettingsManager.shared.dateFormatOtherYears`

### Risks

| Risk | Mitigation |
|------|------------|
| Invalid format string crashes DateFormatter | DateFormatter doesn't crash on invalid formats - it just produces unexpected output. Validate by checking if output is non-empty and reasonable. |
| User enters empty string | Treat empty as invalid, keep previous valid value |
| Performance: creating DateFormatter on every cell | DateFormatter is lightweight; current code already creates one per cell. Could optimize later with caching if needed. |
| User doesn't know format syntax | Provide help text with common examples and link to documentation |

### Implementation Plan

**Phase 1: Settings Infrastructure**
- [ ] Add `dateFormatCurrentYear` and `dateFormatOtherYears` to `Settings` struct in `Settings.swift`
- [ ] Add corresponding computed properties to `SettingsManager.swift`

**Phase 2: Settings UI**
- [ ] Add "Date Format" section to `AppearanceSettingsView.swift`
- [ ] Add text field for current year format with preview
- [ ] Add text field for other years format with preview
- [ ] Add validation (show error for invalid formats)
- [ ] Add help text with format examples

**Phase 3: Apply Format**
- [ ] Update `FileItem.formattedDate` to use settings instead of hardcoded formats
- [ ] Test that file list updates when settings change

---

## Testing

### Automated Tests

Tests go in `Tests/SettingsTests.swift` (extend existing file).

- [ ] `testDateFormatSettingsDefaults` - Default values are "MMM d" and "MMM d, yyyy"
- [ ] `testDateFormatSettingsPersistence` - Custom formats save to and load from UserDefaults
- [ ] `testFileItemFormattedDateUsesSettings` - formattedDate respects settings values
- [ ] `testFileItemFormattedDateCurrentYear` - Dates in current year use currentYear format
- [ ] `testFileItemFormattedDateOtherYear` - Dates in other years use otherYears format

### Test Log

| Date | Result | Notes |
|------|--------|-------|
| — | — | No tests run yet |

### User Verification

After implementation, manually verify:

- [ ] Appearance settings shows "Date Format" section with two text fields
- [ ] Default values are "MMM d" and "MMM d, yyyy"
- [ ] Preview shows correctly formatted dates next to each field
- [ ] Changing format updates preview immediately
- [ ] Invalid format (e.g., "%%%") shows error indication
- [ ] Valid format change updates file list immediately
- [ ] Settings persist after quit and relaunch
- [ ] Files from current year use current year format
- [ ] Files from other years use other years format
