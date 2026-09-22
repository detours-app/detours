# Remote VM Browsing

Detours remote panes connect over the system `/usr/bin/ssh` to x86_64 Linux, Intel macOS, and Windows OpenSSH hosts whose default shell is Windows PowerShell. Detours does not mount SMB, NFS, sshfs, or a Finder-visible volume. It browses macOS and Linux through its own helper and uses a PowerShell backend on Windows.

## SSH Configuration

Add a host in Detours with a single SSH target, such as `build-linux`, `intel-mac`, or `user@example-host`. The target is the label shown in the sidebar and breadcrumb. Authentication is delegated to OpenSSH and the running SSH agent. Detours does not ask for a display name, password, key path, or private key passphrase.

The Add Remote Host sheet suggests entries from `~/.ssh/config`. Suggestions come from top-level `Host` blocks only. Literal aliases and wildcard host patterns are suggested. `Match` blocks and conditional `Include` files are not used for suggestions. Adding a host immediately connects it in the active pane and persists it under Remote Hosts for later reconnects.

The actual connection is still made by OpenSSH, so the SSH target may use the directives your terminal SSH already supports, including:

- `HostName`
- `User`
- `Port`
- `IdentityFile`
- `IdentitiesOnly`
- `ProxyJump`
- `ProxyCommand`
- `ForwardAgent`
- `ServerAliveInterval`
- `ServerAliveCountMax`
- `ControlMaster`
- `ControlPath`

Host-key trust uses OpenSSH. Before saving a new host, Detours displays the scanned key's fingerprint and asks the user to confirm it with the server administrator. Only an accepted key is recorded in the user's known-hosts file. Subsequent helper, transfer, and search SSH processes run with `StrictHostKeyChecking=yes`, public-key authentication, and no password prompts. If SSH rejects the target, Detours surfaces that failure instead of prompting for credentials inside the app.

## Remote Workflows

Remote panes are normal Detours panes for the commands that have been routed through provider-backed `Location` values:

- Browse folders, tabs, breadcrumbs, sorting, hidden-file toggling, and folder expansion
- Copy, cut, paste, F5 copy-to-other-pane, and F6 move-to-other-pane between the Mac and remote hosts
- Symbolic links on macOS and Linux hosts: a copy within one host keeps the link with its target text, a move within one host renames the link, and a transfer to another host carries the file or folder the link points at under the link's name. Inside a transferred folder, a link pointing within the folder is recreated relative to its copied counterpart; a link pointing outside becomes a copy of its target. A missing target or a link back into a folder already being copied fails that one item by name and the rest of the transfer continues. Windows hosts keep their existing behaviour.
- Drag files and folders within one remote host, across remote hosts, and in both
  directions between local and remote panes; valid targets highlight without
  opening folders during hover
- Move to Trash and Undo restore
- New Folder and New File
- Rename
- Get Info and Copy Path
- Quick Look and Open With round trips
- Drag files out to Finder or other apps
- Archive and Extract Here, with formats based on host tool availability
- Git status markers
- Automatic listing updates, including recovery from missed notifications, replaced folders, reconnects, and transient listing failures

Current remote exceptions:

- Duplicate and Duplicate Structure are local-only because those commands still operate on local URL selections.
- Reveal in Finder and Share are local-only because Finder and macOS sharing services require local files. Drag-out and Open With are the supported materialization paths for remote files.
- Delete Immediately permanently removes remote items after the same explicit,
  non-recoverable confirmation used for local items.
- Password-protected ZIP and 7Z work through the bundled helper on supported macOS and Linux hosts. Windows remote hosts support unencrypted archives only.
- Helper deployment accepts only x86_64 Linux and Intel macOS. Apple Silicon macOS, ARM Linux, BSD, and embedded sshd remotes are unsupported.

## Automatic Remote Updates

On supported macOS and Linux hosts, the helper watches the pane's root and expanded folders. It also compares directory identity and immediate-child metadata once per second on the remote host, catching in-place edits and missed native notifications without sending unchanged listings across SSH. Replacing a watched folder reattaches its native watch. Two panes watching the same folder keep independent subscriptions, so closing one does not stop updates in the other.

Native events are collected on a 20 ms loop, then watcher-only refreshes wait for a 100 ms quiet period before requesting a listing. A missed event can add about one second before detection. These are scheduling intervals, not an end-to-end guarantee: listing time, network latency, ongoing operations, and continuing changes can add delay.

Files that disappear during enumeration are skipped. If an expanded folder disappears, its parent is refreshed and the stale branch is removed. When a connection returns, loaded tabs for that host restore their watches and reload their visible directories. Transient listing failures retry automatically after 0.5, 1, and 2 seconds; navigation or a successful refresh cancels outstanding retries. An error that remains appears as a short, single-line banner above the listing, with Retry available. If the pane's root no longer exists, the banner directs the user to its parent; recreating the watched root can trigger recovery.

Windows uses its separate PowerShell watcher. The helper's one-second metadata check applies only to successfully registered Unix watches. If the host refuses watch allocation, such as when Linux reaches its inotify limit, automatic updates for that directory are unavailable until a watch can be restored. A ten-second client polling implementation exists but is not connected to production watch setup.

## Remote Quick Open

Command-P follows the active tab and never falls back to searching the Mac from a remote tab. On macOS and Linux hosts, Quick Open searches the remote home folder and `/opt` first and then the rest of the host through the helper, and streams results as they arrive. On Windows hosts, it searches from the active folder through PowerShell. Recent places remain scoped to the active host, and a disconnected remote tab shows a Reconnect action.

## Remote Quick Look

Quick Look opens its themed Detours preview window before downloading a remote file, with a delayed spinner for transfers that are not immediate. Supported text, Markdown, safely rendered HTML, and image previews stay in that window and support normal preview navigation. PDFs and unsupported types fall back to the system Quick Look panel after download. Files over 100 MB are rejected before transfer. A symbolic link previews the file it points at, under that file's name; a link to a folder closes the preview, as selecting a folder does.

## Unix Helper and Windows Backend

On first connect to supported macOS and Linux hosts, Detours installs the helper binary here:

```text
~/.detours-server/detours-server
```

The install writes a temporary file first and then renames it into place. On later connects, Detours compares the bundled helper hash with the installed helper and silently redeploys when the bundled helper is newer or different.

Bundled helper names:

- `detours-server-x86_64-linux` for `Linux x86_64`
- `detours-server-x86_64-darwin` for `Darwin x86_64`; the file is universal arm64/x86_64 so Foundry can verify it natively, but deployment still rejects `Darwin arm64` hosts

Apple Silicon macOS hosts (`Darwin arm64`) are not supported in this release.

Windows hosts do not receive a helper binary. Detours detects Windows automatically, runs one-shot PowerShell operations over the shared SSH connection, uses a dedicated PowerShell watcher for live updates, and uses SFTP for large transfers when the host exposes it.

## Password-Protected Archives

Supported macOS and Linux helper hosts can create and extract password-protected ZIP and 7Z archives. ZIP passwords are limited to 80 UTF-8 bytes; the app and helper reject longer input before starting an archive tool. Detours does not impose that limit on 7Z passwords.

Password-bearing ZIP and 7Z operations use `7z` or `7zz` through a controlling terminal. Encrypted ZIP archives use AES-256, and encrypted 7Z archives encrypt their headers so filenames are hidden. The password is absent from command-line arguments, environment values, progress frames, and error text. Incorrect passwords return to the Detours password sheet, and failed extraction removes the helper-created temporary output before retrying. This command-line secrecy does not claim protection from privileged memory inspection.

Windows remote hosts do not use the helper and do not support password-protected archive creation or extraction. Their unencrypted ZIP and tool-backed archive behavior is unchanged.

To remove the helper manually:

```bash
ssh <target> 'rm -rf ~/.detours-server'
```

Replace `<target>` with the same SSH alias or target used in Detours.

## Remote Trash

Remote deletes do not use the Mac Trash. On macOS and Linux hosts, they move files into the remote user's FreeDesktop trash location:

```text
~/.local/share/Trash/
```

The trashed file is stored below:

```text
~/.local/share/Trash/files/
```

Its restore metadata is stored below:

```text
~/.local/share/Trash/info/
```

Undo in Detours restores remote items by reading the `.trashinfo` metadata.

Windows hosts use a Detours-managed `.detours-trash` folder below the signed-in user's profile. Restore tokens remain inside Detours; Undo moves the item back to its original Windows path.

To empty the remote trash manually:

```bash
ssh <target> 'rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/*'
```

Run that command only when you are sure you no longer need anything in the remote trash. It is permanent.

## Connection Notes

Unix helper deployment supports x86_64 Linux and x86_64 macOS. Windows OpenSSH hosts are supported separately when their default shell is Windows PowerShell; Detours detects them before Unix helper deployment. Unsupported Unix architectures and Windows hosts with a Unix-style default shell are refused.

Large transfers use a second SSH channel so directory listings, git status, and watch events can continue on the metadata channel. Temporary paths keep incomplete files away from final destinations, and interrupted multi-item remote copies resume with the items that did not arrive. A transfer the host refuses fails with the host's own message, leaves nothing at the destination, and is not counted as copied.

Remote mutation refreshes reconcile the affected folder in place. Expanded branches, selection, scrolling, keyboard focus, sorting, and active filters stay stable, while a completed transfer into a selected closed folder expands it and reveals the result.

Remote directory listings complete before git status markers arrive. Git status runs asynchronously after the list refresh and the helper gives each git command a five-second timeout, so a slow or wedged repository should not leave a remote tab spinning indefinitely.
