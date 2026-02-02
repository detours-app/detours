# Network Volume Support

## Meta
- Status: Draft
- Branch: feature/network-volumes

---

## Business

### Problem

Detours can only access volumes that are already mounted. Users cannot discover network shares (NAS, file servers) or mount them from within the app. They must use Finder's "Connect to Server" (Cmd+K) first, then navigate in Detours.

Additionally, storing network credentials insecurely enables two attack vectors:
1. Kids using an unlocked Mac can access protected NAS shares
2. Malware running as the user can silently mount NAS shares to encrypt/delete backups

### Solution

Add Bonjour-based network discovery to the sidebar, NetFS-based mounting with authentication, and Keychain credential storage that requires user interaction (Touch ID / password) for each mount attempt.

### Behaviors

**Network Section in Sidebar:**
- New "NETWORK" section appears between DEVICES and FAVORITES
- Shows discovered servers on the local network via Bonjour (SMB, NFS)
- Each server shows: icon (network server), name, protocol badge (SMB/NFS)
- Servers appear/disappear dynamically as they come online/offline
- Clicking a server initiates mount

**Mounting Flow:**
- Click server in NETWORK section → attempt mount
- If server requires authentication → show credential dialog
- Credential dialog: server name, username field, password field, "Remember in Keychain" checkbox
- On successful mount, volume appears in DEVICES section (existing behavior)
- On failure, show error alert with reason

**Keychain Credential Storage:**
- "Remember in Keychain" saves credentials with access control requiring user presence
- Next mount attempt: Keychain prompts for Touch ID / password before releasing credentials
- Malware cannot silently retrieve credentials - physical user interaction required
- Credentials stored per-server (not per-share)

**Connect to Server Dialog (Cmd+K):**
- Opens modal dialog for manual server URL entry
- URL field with placeholder: "smb://server/share or nfs://server/export"
- Recent servers dropdown (last 10, persisted)
- Connect button initiates mount with same auth flow
- Supports SMB, NFS, AFP (legacy) URL schemes

**Keyboard Shortcuts:**
- Cmd+K: Open "Connect to Server" dialog (new, configurable)

---

## Technical

### Approach

Network discovery uses `NWBrowser` from the Network framework to browse for Bonjour services (`_smb._tcp` and `_nfs._tcp`). Discovered servers are displayed in a new "NETWORK" sidebar section.

Mounting uses the NetFS framework (`NetFSMountURLAsync`) which handles protocol negotiation, authentication prompts, and mount point creation. The function accepts optional credentials; if omitted and the server requires auth, it triggers the system authentication dialog.

Credential storage uses Security framework's Keychain Services with `kSecAccessControlUserPresence` access control. This flag requires Touch ID, Apple Watch, or password confirmation before the credential can be accessed - preventing silent credential theft by malware.

The "Connect to Server" dialog is implemented in SwiftUI, presented as a sheet from the main window. Recent servers are stored in UserDefaults via SettingsManager.

### File Changes

**src/Sidebar/NetworkBrowser.swift** (new)
- Singleton class wrapping `NWBrowser` for Bonjour discovery
- Browse for `_smb._tcp.` and `_nfs._tcp.` service types
- `discoveredServers: [NetworkServer]` published property
- `NetworkServer` struct: `name: String`, `host: String`, `port: Int`, `protocol: NetworkProtocol`
- `NetworkProtocol` enum: `.smb`, `.nfs`, `.afp`
- Posts `NetworkBrowser.serversDidChange` notification on updates
- `start()` and `stop()` methods for lifecycle management
- Start browsing in `init()`, stop on deinit

**src/Sidebar/NetworkMounter.swift** (new)
- Handles mounting network volumes via NetFS
- `mount(url: URL, username: String?, password: String?, saveToKeychain: Bool) async throws -> URL`
- Wraps `NetFSMountURLAsync` with Swift async/await
- Returns mount point URL on success
- Throws `NetworkMountError` on failure (`.authenticationFailed`, `.serverUnreachable`, `.permissionDenied`, `.cancelled`)
- `unmount(mountPoint: URL) async throws` for explicit unmounting

**src/Sidebar/KeychainCredentialStore.swift** (new)
- Manages network credentials in Keychain with secure access control
- `save(server: String, username: String, password: String)` - saves with `kSecAccessControlUserPresence`
- `retrieve(server: String) async throws -> (username: String, password: String)?` - prompts for Touch ID/password
- `delete(server: String)` - removes stored credential
- `hasCredential(server: String) -> Bool` - checks if credential exists (no auth required)
- Uses `kSecAttrService` = "com.detours.network" for all entries
- Uses `kSecAttrAccount` = server hostname

**src/Sidebar/SidebarSection.swift**
- Add `.network` case to `SidebarSection` enum
- Update `allCases` order: `.devices`, `.network`, `.favorites`

**src/Sidebar/SidebarItem.swift**
- Add `.server(NetworkServer)` case to `SidebarItem` enum

**src/Sidebar/SidebarViewController.swift**
- Add `NetworkBrowser.serversDidChange` observer in `observeNotifications()`
- Update `flatItems()` to include NETWORK section and discovered servers
- Handle click on server item: call `delegate?.sidebarDidSelectServer(_:)`
- Update drag-drop validation to reject drops on network servers (not mounted yet)

**src/Sidebar/SidebarItemView.swift**
- Handle `.server` item type in `configure(with:theme:)`
- Show network server icon (`NSImage(systemSymbolName: "server.rack")`)
- Show protocol badge (SMB/NFS) as small label, Text Tertiary color

**src/Sidebar/SidebarDelegate.swift**
- Add `sidebarDidSelectServer(_ server: NetworkServer)` method

**src/Sidebar/ConnectToServerView.swift** (new)
- SwiftUI view for "Connect to Server" dialog
- URL text field with validation (must be valid smb://, nfs://, or afp:// URL)
- Recent servers picker (populated from SettingsManager)
- Connect and Cancel buttons
- `onConnect: (URL) -> Void` callback
- `onCancel: () -> Void` callback

**src/Sidebar/ConnectToServerWindowController.swift** (new)
- `NSWindowController` subclass hosting `ConnectToServerView`
- `present(over: NSWindow)` method to show as sheet
- Handles connect action: validates URL, dismisses sheet, calls delegate

**src/Sidebar/AuthenticationView.swift** (new)
- SwiftUI view for credential entry when mounting protected share
- Server name label (read-only)
- Username text field
- Password secure field
- "Remember in Keychain" checkbox (default: true)
- Connect and Cancel buttons
- `onAuthenticate: (String, String, Bool) -> Void` callback (username, password, remember)

**src/Sidebar/AuthenticationWindowController.swift** (new)
- `NSWindowController` subclass hosting `AuthenticationView`
- `present(over: NSWindow, server: String) async -> (username: String, password: String, remember: Bool)?`
- Returns nil if cancelled

**src/Windows/MainSplitViewController.swift**
- Implement `sidebarDidSelectServer(_:)` delegate method
- On server click: attempt mount, show auth dialog if needed, navigate to mount point on success
- Add `showConnectToServer()` method
- Add `mountNetworkServer(_ server: NetworkServer)` async method with full mount flow

**src/Preferences/Settings.swift**
- Add `recentServers: [String] = []` property (URL strings, max 10)

**src/Preferences/Settings.swift** - ShortcutAction enum
- Add `.connectToServer` case
- Add `displayName` "Connect to Server"

**src/Utilities/ShortcutManager.swift**
- Add default shortcut for `.connectToServer`: Cmd+K

**src/App/MainMenu.swift**
- Add "Connect to Server..." item to Go menu with Cmd+K shortcut
- Action: `#selector(AppDelegate.connectToServer(_:))`

**src/App/AppDelegate.swift**
- Add `@objc func connectToServer(_:)` method
- Calls `mainWindowController?.splitViewController.showConnectToServer()`

**Package.swift** (if needed)
- NetFS framework is part of macOS SDK, no package changes needed
- Network framework is part of macOS SDK, no package changes needed

### Risks

| Risk | Mitigation |
|------|------------|
| NetFS is C API, complex to wrap | Create focused Swift wrapper with async/await, handle all error codes |
| Bonjour discovery floods with servers | Limit display to 20 servers, sort by name, add "Refresh" option |
| Keychain access control blocks main thread | All Keychain operations are async, UI shows spinner during auth |
| Network framework requires macOS 10.14+ | Already require macOS 14.0+, not an issue |
| Server goes offline after discovery | Handle mount failure gracefully, remove from list on browse update |
| User cancels Touch ID repeatedly | After 3 failures, show "Keychain access denied" and offer manual entry |
| AFP protocol deprecated | Support for legacy servers, show deprecation note in UI |

### Implementation Plan

**Phase 1: Network Discovery**
- [ ] Create `NetworkBrowser.swift` with NWBrowser wrapper
- [ ] Create `NetworkServer` struct and `NetworkProtocol` enum
- [ ] Add `.network` section to `SidebarSection`
- [ ] Add `.server` case to `SidebarItem`
- [ ] Update `SidebarViewController` to display NETWORK section
- [ ] Update `SidebarItemView` to render server items
- [ ] Test discovery with local SMB/NFS server

**Phase 2: Mounting Infrastructure**
- [ ] Create `NetworkMounter.swift` with NetFS wrapper
- [ ] Create `NetworkMountError` enum with all error cases
- [ ] Create `KeychainCredentialStore.swift` with secure storage
- [ ] Test mounting public (no-auth) share
- [ ] Test Keychain storage with access control

**Phase 3: Authentication Flow**
- [ ] Create `AuthenticationView.swift` SwiftUI dialog
- [ ] Create `AuthenticationWindowController.swift`
- [ ] Add `sidebarDidSelectServer(_:)` to `SidebarDelegate`
- [ ] Implement mount flow in `MainSplitViewController`
- [ ] Test mounting protected share with credential prompt
- [ ] Test "Remember in Keychain" saves with user presence requirement
- [ ] Test subsequent mount requires Touch ID/password

**Phase 4: Connect to Server Dialog**
- [ ] Create `ConnectToServerView.swift` SwiftUI dialog
- [ ] Create `ConnectToServerWindowController.swift`
- [ ] Add `recentServers` to Settings
- [ ] Add `.connectToServer` shortcut action with Cmd+K default
- [ ] Add menu item to Go menu
- [ ] Wire up `AppDelegate.connectToServer(_:)`
- [ ] Test manual URL entry and mount

**Phase 5: Polish**
- [ ] Handle edge cases (server offline, auth failure, network timeout)
- [ ] Add loading indicator during mount
- [ ] Add error alerts with actionable messages
- [ ] Test with SMB, NFS, and AFP servers
- [ ] Test Keychain credential deletion (right-click server → "Forget Password")
- [ ] Verify no credentials accessible without user interaction

---

## Testing

### Automated Tests

Tests go in `Tests/NetworkTests.swift`. Log results in `Tests/TEST_LOG.md`.

- [ ] `testNetworkProtocolURLSchemes` - NetworkProtocol returns correct URL schemes (smb, nfs, afp)
- [ ] `testNetworkServerEquality` - NetworkServer equality based on host and protocol
- [ ] `testNetworkMountErrorDescriptions` - All error cases have user-friendly descriptions
- [ ] `testRecentServersMaxCount` - Recent servers list capped at 10 entries
- [ ] `testRecentServersPersistence` - Recent servers save/load from UserDefaults
- [ ] `testConnectToServerURLValidation` - Valid/invalid URL detection for smb://, nfs://, afp://

### XCUITest Tests

Tests go in `Tests/UITests/DetoursUITests/NetworkUITests.swift`. Run with `resources/scripts/uitest.sh NetworkUITests`.

**Sidebar Network Section:**
- [ ] `testNetworkSectionExists` - NETWORK section header appears in sidebar between DEVICES and FAVORITES
- [ ] `testNetworkSectionShowsDiscoveredServers` - Discovered servers appear under NETWORK section (requires test server on network)

**Connect to Server Dialog:**
- [ ] `testConnectToServerOpensWithKeyboardShortcut` - Cmd+K opens Connect to Server sheet
- [ ] `testConnectToServerDialogElements` - Dialog contains URL field, recent servers picker, Connect and Cancel buttons
- [ ] `testConnectToServerCancelCloses` - Cancel button dismisses dialog
- [ ] `testConnectToServerValidatesURL` - Connect button disabled for invalid URLs, enabled for valid smb:// URLs
- [ ] `testConnectToServerRecentServersPopulated` - Recent servers dropdown shows previously used servers

**Authentication Dialog:**
- [ ] `testAuthenticationDialogElements` - Auth dialog contains server label, username field, password field, Remember checkbox, Connect and Cancel buttons
- [ ] `testAuthenticationDialogCancel` - Cancel button dismisses auth dialog without mounting

### User Verification

**Marco (requires local network with SMB/NFS server):**
- [ ] NETWORK section shows discovered servers on local network
- [ ] Click server → mounts and navigates to share
- [ ] Protected share prompts for credentials
- [ ] "Remember in Keychain" + remount → Touch ID/password prompt appears
- [ ] Cmd+K opens Connect to Server dialog
- [ ] Manual URL entry works for known server
