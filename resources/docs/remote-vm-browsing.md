# Remote VM Browsing

Detours remote panes connect to x86_64 Linux development machines and Intel macOS hosts over the system `/usr/bin/ssh`. Detours does not mount SMB, NFS, sshfs, or a Finder-visible volume. It starts its own helper on the remote host and browses files through that helper over SSH.

## SSH Configuration

Add a host in Detours with a single SSH target, such as `devtest`, `wraith`, or `marco@devtest`. The target is the label shown in the sidebar and breadcrumb. Authentication is delegated to OpenSSH and the running SSH agent. Detours does not ask for a display name, password, key path, or private key passphrase.

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

Host-key trust uses OpenSSH. The Add Remote Host flow scans the target host key before saving the host and records it in the user's known-hosts file; subsequent helper, transfer, and search SSH processes run with `StrictHostKeyChecking=yes`, public-key authentication, and no password prompts. If SSH rejects the target, Detours surfaces that failure instead of prompting for credentials inside the app.

## Remote Workflows

Remote panes are normal Detours panes for the commands that have been routed through provider-backed `Location` values:

- Browse folders, tabs, breadcrumbs, sorting, hidden-file toggling, and folder expansion
- Copy, cut, paste, F5 copy-to-other-pane, and F6 move-to-other-pane between the Mac and remote hosts
- Move to Trash, Undo restore, and Delete Immediately after confirmation
- New Folder and New File
- Rename
- Get Info and Copy Path
- Quick Look and Open With round trips
- Drag files out to Finder or other apps
- Git status markers
- File watching with polling fallback when needed

Current remote exceptions:

- Duplicate, Duplicate Structure, Archive, and Extract Here are local-only because those app commands still operate on local URL selections instead of provider-backed locations.
- Reveal in Finder and Share are local-only because Finder and macOS sharing services require local files. Drag-out and Open With are the supported materialization paths for remote files.
- Apple Silicon macOS, ARM Linux, BSD, and embedded sshd remotes are unsupported because this release bundles only `x86_64 Linux` and `x86_64 macOS` helpers.

## Remote Quick Open

Command-P follows the active tab. In a remote tab, Quick Open searches the active SSH host by file and folder name through the helper instead of searching the Mac. The scope header reads `Searching <host> - entire host`, results stream as the helper finds them, and recent remote places are scoped to the active host. A disconnected remote tab shows a Reconnect action and never falls back to local search.

## Helper Binary

On first connect, Detours installs the helper binary here on the remote host:

```text
~/.detours-server/detours-server
```

The install writes a temporary file first and then renames it into place. On later connects, Detours compares the bundled helper hash with the installed helper and silently redeploys when the bundled helper is newer or different.

Bundled helper names:

- `detours-server-x86_64-linux` for `Linux x86_64`
- `detours-server-x86_64-darwin` for `Darwin x86_64`

Apple Silicon macOS hosts (`Darwin arm64`) are not supported in this release.

To remove the helper manually:

```bash
ssh <target> 'rm -rf ~/.detours-server'
```

Replace `<target>` with the same SSH alias or target used in Detours.

## Remote Trash

Remote deletes do not use the Mac Trash. They move files into the remote host's FreeDesktop trash location:

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

To empty the remote trash manually:

```bash
ssh <target> 'rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/*'
```

Run that command only when you are sure you no longer need anything in the remote trash. It is permanent.

## Connection Notes

Only x86_64 Linux and x86_64 macOS hosts are supported in this release. Unsupported architectures are refused before helper install.

Large transfers use a second SSH channel so directory listings, git status, and watch events can continue on the metadata channel. Interrupted transfers write to a temporary partial file and remove that partial before retrying.

Remote directory listings complete before git status markers arrive. Git status runs asynchronously after the list refresh and the helper gives each git command a five-second timeout, so a slow or wedged repository should not leave a remote tab spinning indefinitely.
