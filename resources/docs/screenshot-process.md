# README Screenshot Process

The README screenshot is staged on Foundry so it does not touch Spectre's filesystem. The fixture tree is disposable and lives under `/tmp/detours-screenshot`.

## Target State

Match the current checked-in screenshot:

- Window size: set manually before capture; the configure script does not reset it.
- Theme: Dark.
- Sidebar: visible, about 190 pt wide.
- Left pane tabs: `Tools`, `Finance`, `acme-corp`; `acme-corp` selected.
- Left pane path: `/tmp/detours-screenshot/acme-corp`.
- Left pane selection: `Budget-2026.xlsx`.
- Remote Hosts section: `devtest`, connected.
- File Servers section: `Acme NAS`, with a `Projects` share.
- Right pane tabs: `INBOX`, `Downloads`, `api`; `api` selected.
- Right pane path: `devtest:/tmp/detours-screenshot/taskflow/api`.
- Active pane: left pane, so the left selection is teal and the right pane is inactive.
- Pane split: approximately 48/52 left/right after the sidebar.

## Fixture Setup

Run this on Foundry:

```bash
cd ~/dev/detours
git pull --ff-only
resources/scripts/screenshot-setup.sh
ssh devtest 'bash -s' < resources/scripts/screenshot-setup.sh
resources/scripts/screenshot-configure.sh
```

The setup script recreates:

- `/tmp/detours-screenshot/acme-corp`
- `/tmp/detours-screenshot/taskflow`

Run it both on Foundry and through SSH on `devtest`. It initializes the `taskflow` git repository with staged, modified, and untracked files so Detours can show git status markers locally and in the remote pane.

The configure script quits Detours, writes the screenshot session defaults, stores `devtest` as a Remote Host, adds the screenshot-only `Acme NAS` file server row, and relaunches `/Applications/Detours.app`.

## Manual Details

The configure script creates these extra tab/favorite directories used only for the screenshot chrome:

```bash
mkdir -p \
  /tmp/detours-screenshot/Tools \
  /tmp/detours-screenshot/Finance \
  /tmp/detours-screenshot/INBOX \
  /tmp/detours-screenshot/Downloads \
  "$HOME/INBOX" \
  "$HOME/1 Projects" \
  "$HOME/2 Areas" \
  "$HOME/3 Resources" \
  "$HOME/4 Archive" \
  "$HOME/dev"
```

It writes these session defaults for bundle id `com.detours.app`:

- `Detours.LeftPaneTabs`: `/tmp/detours-screenshot/Tools`, `/tmp/detours-screenshot/Finance`, `/tmp/detours-screenshot/acme-corp`
- `Detours.LeftPaneSelectedIndex`: `2`
- `Detours.LeftPaneSelections`: only the `acme-corp` tab selects `/tmp/detours-screenshot/acme-corp/Budget-2026.xlsx`
- `Detours.RightPaneTabs`: `/tmp/detours-screenshot/INBOX`, `/tmp/detours-screenshot/Downloads`, `/tmp/detours-screenshot/taskflow/api`
- `Detours.RightPaneSelectedIndex`: `2`
- `Detours.RightPaneSelections`: only the `api` tab selects `/tmp/detours-screenshot/taskflow/api/database.py`
- `Detours.RemoteHosts`: one host named `devtest`
- `Detours.RightPaneRemoteTabs`: the `api` tab targets `devtest:/tmp/detours-screenshot/taskflow/api`
- `Detours.ScreenshotFileServers`: one screenshot-only file server named `Acme NAS` with a `Projects` share
- `Detours.ActivePane`: `0`
- `Detours.SidebarVisible`: `true`
- `Detours.SidebarWidth`: `190`
- `Detours.SplitDividerPosition`: `0.4841646872525732`
The settings JSON stored in `Detours.Settings` should keep restore-session, sidebar, status bar, folders-on-top, folder expansion, and git status enabled, with the dark theme and the screenshot favorites.

Wait for both panes to load before capturing.

## Capture

On Foundry, capture the Detours window via Screen Sharing. The command-line `screencapture` path currently fails from SSH with `could not create image from display`, so take the screenshot from the GUI session.

Save the final PNG over:

```text
resources/docs/screenshot.png
```
