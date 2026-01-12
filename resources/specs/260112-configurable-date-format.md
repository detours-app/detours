# Configurable Date Format

## Meta
- Status: Complete
- Branch: feature/date-format-setting

---

## Business

### Problem

The Date Modified column in the file list uses hardcoded date formats ("MMM d" for current year, "MMM d, yyyy" for other years). Users may prefer different formats like ISO dates, timestamps with time, or localized formats.

### Solution

Add two free-text date format fields in Appearance settings - one for current year dates, one for other years. Include live validation and preview so users can see the result immediately.

### Behaviors

- Two compact text fields in Appearance settings ("This year" and "Past years")
- "This year" field (default: "MMM d") - used for dates within the current year
- "Past years" field (default: "MMM d, yyyy") - used for dates in previous/future years
- Live preview integrated into Theme Preview section - file list shows sample dates using configured formats
- Invalid format strings show red border on input field
- Changes apply immediately to file list and preview
- Help text showing common DateFormatter specifiers

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
- Add `@State` properties for `dateFormatCurrentYear` and `dateFormatOtherYears`
- Add `DateFormatRow` component with two compact `DateFormatInput` fields side-by-side
- Fields show "This year" and "Past years" labels with monospace text inputs
- Invalid formats show red border; valid formats save immediately
- Add help text: "DateFormatter syntax: MMM d, yyyy-MM-dd, HH:mm, etc."
- Integrate date preview into `ThemePreview` - file list rows now show formatted dates
- `ThemePreview` accepts date format parameters and displays sample dates (current year and past year)

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
- [x] Add `dateFormatCurrentYear` and `dateFormatOtherYears` to `Settings` struct in `Settings.swift`
- [x] Add corresponding computed properties to `SettingsManager.swift`

**Phase 2: Settings UI**
- [x] Add "Date Format" section to `AppearanceSettingsView.swift`
- [x] Add text field for current year format with preview
- [x] Add text field for other years format with preview
- [x] Add validation (show error for invalid formats)
- [x] Add help text with format examples

**Phase 3: Apply Format**
- [x] Update `FileItem.formattedDate` to use settings instead of hardcoded formats
- [x] Test that file list updates when settings change

---

## Testing

### Automated Tests

Tests in `Tests/PreferencesTests.swift` and `Tests/FileItemTests.swift`.

- [x] `testDateFormatSettingsDefaults` - Default values are "MMM d" and "MMM d, yyyy"
- [x] `testDateFormatSettingsPersistence` - Custom formats save to and load from UserDefaults
- [x] `testFormattedDateUsesCurrentYearSetting` - Dates in current year use currentYear format
- [x] `testFormattedDateUsesOtherYearsSetting` - Dates in other years use otherYears format

### Test Log

| Date | Result | Notes |
|------|--------|-------|
| 2026-01-12 | Pass | 6 tests passed (4 FileItem + 2 Preferences)

### MCP UI Verification

Use macOS UI automation MCP server to verify:

- [x] Open Preferences > Appearance, verify date format fields exist
- [x] Verify two text fields with labels "This year" and "Past years"
- [x] Verify default values are "MMM d" and "MMM d, yyyy"
- [x] Verify Theme Preview shows file list with date column

### Manual Verification

- [ ] Type custom format in field, verify Theme Preview updates
- [ ] Type invalid format "%%%", verify red border appears on input
- [ ] Change format to valid value, verify file list date column updates
- [ ] Settings persist after quit and relaunch
