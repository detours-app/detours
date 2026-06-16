# README Screenshot Process

The README screenshot is staged on Foundry so it does not touch Spectre's filesystem. The managed fixture folders live under `~/Projects` and are recreated by the setup script.

## Target State

Match the current checked-in screenshot:

- Window size: set manually before capture; the configure script does not reset it.
- Theme: Dark.
- Sidebar: visible, about 189 pt wide.
- Left pane tabs: `Tools`, `Finance`, `acme-corp`; `acme-corp` selected.
- Left pane path: `~/Projects/acme-corp`.
- Left pane selection: `Budget-2026.xlsx`.
- Remote Hosts section: `devtest`, connected.
- File Servers section: `Acme NAS`, labeled `SMB`, with a `Projects` share.
- Right pane tabs: `INBOX`, `Downloads`, `api`; `api` selected.
- Right pane path: `devtest:/home/maf/Projects/taskflow/api`.
- Active pane: left pane, so the left selection is teal and the right pane is inactive.
- Pane split: exact 50/50 left/right after the sidebar.

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

The setup script recreates only these managed fixture folders:

- `~/Projects/acme-corp`
- `~/Projects/taskflow`

Run it both on Foundry and through SSH on `devtest`. It initializes the `taskflow` git repository with staged, modified, and untracked files so Detours can show git status markers locally and in the remote pane.

The configure script quits Detours, writes the screenshot session defaults, stores `devtest` as a Remote Host, adds the screenshot-only `Acme NAS` file server row, and relaunches `/Applications/Detours.app`. By default it queries `devtest` for its home directory and uses that for the remote `taskflow` tab; set `DETOURS_SCREENSHOT_REMOTE_BASE` to override it.

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
  "$HOME/dev"
```

It writes these session defaults for bundle id `com.detours.app`:

- `Detours.LeftPaneTabs`: `~/Projects/Tools`, `~/Projects/Finance`, `~/Projects/acme-corp`
- `Detours.LeftPaneSelectedIndex`: `2`
- `Detours.LeftPaneSelections`: only the `acme-corp` tab selects `~/Projects/acme-corp/Budget-2026.xlsx`
- `Detours.RightPaneTabs`: `~/Projects/INBOX`, `~/Projects/Downloads`, `~/Projects/taskflow/api`
- `Detours.RightPaneSelectedIndex`: `2`
- `Detours.RightPaneSelections`: only the `api` tab selects `/home/maf/Projects/taskflow/api/database.py`
- `Detours.RemoteHosts`: one host named `devtest`
- `Detours.RightPaneRemoteTabs`: the `api` tab targets `devtest:/home/maf/Projects/taskflow/api`
- `Detours.ScreenshotFileServers`: one screenshot-only `SMB` file server named `Acme NAS` with a `Projects` share
- `Detours.ActivePane`: `0`
- `Detours.SidebarVisible`: `true`
- `Detours.SidebarWidth`: `189`
- `Detours.SplitDividerPosition`: `0.5`
The settings JSON stored in `Detours.Settings` should keep restore-session, sidebar, status bar, folders-on-top, folder expansion, and git status enabled, with the dark theme and the screenshot favorites.

Wait for both panes to load before capturing.

## Capture

On Foundry, capture the Detours window via Screen Sharing. The command-line `screencapture` path currently fails from SSH with `could not create image from display`, so take the screenshot from the GUI session.

Save the final PNG over:

```text
resources/docs/screenshot.png
```
