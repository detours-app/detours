# Chrome Polish Screenshot Process

The README screenshot is staged on Foundry so it does not touch Spectre's filesystem. The managed fixture folders live under `~/Projects` and are recreated by the setup script.

## Target State

Stage this capture state:

- Window size: set manually before capture; the configure script does not reset it.
- Theme: Dark for the README screenshot, plus Light for chrome-polish verification.
- Sidebar: visible.
- Devices section: local boot volume plus mounted `Specs.sparsebundle` and `Detours.dmg` fixture volumes, both with eject affordances.
- Left pane tabs: `Tools`, `Finance`, `acme-corp`, `Specs.sparsebundle`; `acme-corp` selected.
- Left pane path: `~/Projects/acme-corp`.
- Left pane selection: `Budget-2027.xlsx`.
- Remote Hosts section: `devtest`, connected.
- File Servers section: `Acme NAS`, labeled `SMB`, with a `Projects` share.
- Right pane tabs: `INBOX`, `Downloads`, `api`, `Detours.dmg`; `api` selected.
- Right pane path: `devtest:/home/maf/Projects/taskflow/api`.
- Active pane: left pane, so the left selection is teal and the right pane is inactive.
- Pane split and window size: AppKit autosave/manual for capture; both panes must remain visible and usable.

## Fixture Setup

Run this on Foundry:

```bash
cd ~/dev/detours
git pull --ff-only
resources/scripts/build.sh --screenshot-fixtures
resources/scripts/screenshot-setup.sh
ssh devtest 'bash -s' < resources/scripts/screenshot-setup.sh
resources/scripts/screenshot-configure.sh
```

The screenshot-only file server injection is compiled out of normal builds. The `--screenshot-fixtures` build flag enables the fixture-only `Detours.ScreenshotFileServers` preference reader for capture builds.

The setup script recreates only these managed fixture paths:

- `~/Projects/acme-corp`
- `~/Projects/taskflow`
- `~/Projects/Volumes`
- `/Volumes/Specs.sparsebundle`
- `/Volumes/Detours.dmg`

Run it both on Foundry and through SSH on `devtest`. On Foundry it also creates the fixture-owned sparse bundle and DMG under `~/Projects/Volumes`, mounts them at `/Volumes/Specs.sparsebundle` and `/Volumes/Detours.dmg`, and populates them with small browseable trees. On non-macOS hosts the mounted-volume fixture step is skipped. The script initializes the `taskflow` git repository with staged, modified, and untracked files so Detours can show git status markers locally and in the remote pane.

The configure script quits Detours, verifies the local and mounted-volume fixtures, writes the screenshot session defaults, stores `devtest` as a Remote Host, adds the screenshot-only `Acme NAS` file server row, and relaunches `/Applications/Detours.app`. By default it queries `devtest` for its home directory and uses that for the remote `taskflow` tab; set `DETOURS_SCREENSHOT_REMOTE_BASE` to override it. Set `DETOURS_SCREENSHOT_THEME=light` to configure the same scene in Light theme. If running the script through SSH and GUI relaunch is blocked, run it with `DETOURS_SCREENSHOT_SKIP_RELAUNCH=1`, then relaunch Detours in the logged-in Foundry GUI session.

## Manual Details

The configure script creates these extra tab/favorite directories used only for the screenshot chrome:

```bash
mkdir -p \
  ~/Projects/Tools \
  ~/Projects/Finance \
  ~/Projects/INBOX \
  ~/Projects/Downloads \
  "$HOME/INBOX" \
  "$HOME/1 Projects" \
  "$HOME/2 Areas" \
  "$HOME/3 Resources" \
  "$HOME/4 Archive" \
  "$HOME/dev" \
  "$HOME/Documents" \
  "$HOME/Downloads" \
  "$HOME/Applications"
```

It writes these session defaults for bundle id `com.detours.app`:

- `Detours.LeftPaneTabs`: `~/Projects/Tools`, `~/Projects/Finance`, `~/Projects/acme-corp`, `/Volumes/Specs.sparsebundle`
- `Detours.LeftPaneSelectedIndex`: `2`
- `Detours.LeftPaneSelections`: the `acme-corp` tab selects `~/Projects/acme-corp/Budget-2027.xlsx`; the `Specs.sparsebundle` tab selects `/Volumes/Specs.sparsebundle/token`
- `Detours.RightPaneTabs`: `~/Projects/INBOX`, `~/Projects/Downloads`, `~/Projects/taskflow/api`, `/Volumes/Detours.dmg`
- `Detours.RightPaneSelectedIndex`: `2`
- `Detours.RightPaneSelections`: the `api` tab selects `/home/maf/Projects/taskflow/api/database.py`; the `Detours.dmg` tab selects `/Volumes/Detours.dmg/Detours.app`
- `Detours.RemoteHosts`: one host named `devtest`
- `Detours.RightPaneRemoteTabs`: the `api` tab targets `devtest:/home/maf/Projects/taskflow/api`
- `Detours.ScreenshotFileServers`: one screenshot-only `SMB` file server named `Acme NAS` with a `Projects` share
- `Detours.ActivePane`: `0`
- `Detours.Settings`: selected screenshot theme, Compact density, restore-session, sidebar, status bar, folders-on-top, folder expansion, git status, and screenshot favorites enabled

The screenshot configurator does not write legacy split geometry keys. Use the current AppKit window and split-view autosave state, or adjust the window manually before capture.

Wait for both panes to load before capturing.

## Automated Capture

The legacy direct UI-test capture route is suspended. It bypasses the mandatory qualification prompt sentry and can leave an `Allow` dialog unattended. Do not invoke `resources/scripts/uitest.sh` directly for screenshot capture.

Release captures now run through `qualification-foundry.sh installed-smoke`, with one repetition and an explicit test filter. `QuietProCaptureTests/testCaptureReleaseScenes` uses `opening LOCAL_ROOT` for the main workspace and document previews. `ReleaseQuickOpenCaptureTests/testCaptureRecentPlacesAndRemoteSearch` uses `activation LINUX_TARGET` for recent places and a real remote search. `QuietProCaptureTests/testCaptureReleaseHostSuggestions` captures Cmd-K without connecting. All inherit the qualification prompt sentries and cleanup contract. Export attachments from the completed result bundle and inspect them before replacing public images.

The release samples use 2026 invoice, contract and report names, a Q3 2026 financial report, and `Budget-2027.xlsx`. Keep modification dates in the past. Update existing samples in place; do not rerun the destructive legacy setup merely to refresh names or dates. The older setup instructions above describe a full fixture rebuild, not the release refresh workflow.

## Manual Capture

On Foundry, capture the Detours window via Screen Sharing. The command-line `screencapture` path currently fails from SSH with `could not create image from display`, so take the screenshot from the GUI session.

Save the final PNG over:

```text
resources/docs/screenshot.png
```
