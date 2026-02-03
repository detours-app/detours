# Network Volume Support

## Meta
- Status: Complete
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
- On successful mount, volume appears under the server in NETWORK section (hierarchical display)
- On failure, show error alert with reason

**Hierarchical Network Volume Display:**
- DEVICES section shows only local volumes (internal drives, USB, etc.)
- NETWORK section shows servers with mounted volumes nested underneath
- Servers with mounted volumes auto-expand to show volumes
- Network volumes show with 8px indentation under their parent server (per Apple HIG sidebar guidance)
- Network volumes have distinct teal icon and eject button with capacity display
- Synthetic servers created for volumes mounted via manual URL (Cmd+K) with no Bonjour discovery
- Synthetic servers show "manual" badge instead of protocol badge
- Offline servers (lost Bonjour but volumes still mounted) shown dimmed with "offline" badge

**Server Eject and Additional Shares:**
- Servers with mounted volumes show eject button (ejects all volumes from that server)
- Right-click server with volumes shows "Eject" context menu option
- Right-click server with volumes shows "Connect to Share..." to mount additional shares
- Click on server row toggles expand/collapse (no disclosure triangle)
- Network volume eject uses diskutil with auto force fallback for busy volumes

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
- Add `.syntheticServer(SyntheticServer)` case for manually-connected servers
- Add `.networkVolume(VolumeInfo)` case for volumes under servers
- Add `SyntheticServer` struct for servers derived from mounted volumes
- Add `VolumeInfo.matchesServer(_:)` method for host matching

**src/Sidebar/VolumeMonitor.swift**
- Add `isNetwork: Bool` property to `VolumeInfo` (from `volumeIsLocalKey` inverted)
- Add `serverHost: String?` property parsed from `volumeURLForRemounting`
- Update `refreshVolumes()` to populate network detection properties

**src/Sidebar/SidebarViewController.swift**
- Add `NetworkBrowser.serversDidChange` observer in `observeNotifications()`
- Replace `flatItems()` with `topLevelItems()` for hierarchical structure
- Add `buildNetworkHierarchy()` to create server + synthetic server list
- Add `mountedVolumes(forHost:)` to get volumes for a server
- Implement hierarchical `NSOutlineViewDataSource` methods for server expansion
- Add `expandServersWithVolumes()` to auto-expand servers with mounted volumes
- Handle click on server item: call `delegate?.sidebarDidSelectServer(_:)`
- Update drag-drop validation to reject drops on servers (discovered and synthetic)
- Filter `devicesItems()` to return only local volumes

**src/Sidebar/SidebarItemView.swift**
- Handle `.server` item type in `configure(with:theme:)`
- Handle `.syntheticServer` type with "manual" badge
- Handle `.networkVolume` type with indentation support
- Add `configureAsSyntheticServer(_:theme:)` method
- Add `configureAsNetworkVolume(_:theme:indented:)` method
- Update `configureAsServer(_:theme:isOffline:)` for offline styling
- Update `resetNameLeading(indent:)` to support indentation
- Show network server icon (`NSImage(systemSymbolName: "server.rack")`)
- Show protocol badge (SMB/NFS), "manual" for synthetic, "offline" for disconnected

**src/Sidebar/NetworkBrowser.swift**
- Add `offlineServers: Set<String>` to track servers that went offline with volumes
- Add `isServerOffline(host:)` method to check offline status
- Add `refreshOfflineServers()` method to clean up when volumes unmount
- Update `handleResultsChanged` to track offline servers when volumes still mounted

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
- [x] Create `NetworkBrowser.swift` with NWBrowser wrapper
- [x] Create `NetworkServer` struct and `NetworkProtocol` enum
- [x] Add `.network` section to `SidebarSection`
- [x] Add `.server` case to `SidebarItem`
- [x] Update `SidebarViewController` to display NETWORK section
- [x] Update `SidebarItemView` to render server items
- [x] Test discovery with local SMB/NFS server

**Phase 2: Mounting Infrastructure**
- [x] Create `NetworkMounter.swift` with NetFS wrapper
- [x] Create `NetworkMountError` enum with all error cases
- [x] Create `KeychainCredentialStore.swift` with secure storage
- [x] Test mounting public (no-auth) share
- [x] Test Keychain storage with access control

**Phase 3: Authentication Flow**
- [x] Create `AuthenticationView.swift` SwiftUI dialog
- [x] Create `AuthenticationWindowController.swift`
- [x] Add `sidebarDidSelectServer(_:)` to `SidebarDelegate`
- [x] Implement mount flow in `MainSplitViewController`
- [x] Test mounting protected share with credential prompt
- [x] Test "Remember in Keychain" saves with user presence requirement
- [x] Test subsequent mount requires Touch ID/password

**Phase 4: Connect to Server Dialog**
- [x] Create `ConnectToServerView.swift` SwiftUI dialog
- [x] Create `ConnectToServerWindowController.swift`
- [x] Add `recentServers` to Settings
- [x] Add `.connectToServer` shortcut action with Cmd+K default
- [x] Add menu item to Go menu
- [x] Wire up `AppDelegate.connectToServer(_:)`
- [x] Test manual URL entry and mount

**Phase 5: Polish**
- [x] Handle edge cases (server offline, auth failure, network timeout)
- [x] Add loading indicator during mount
- [x] Add error alerts with actionable messages
- [x] Test with SMB, NFS servers
- [x] Test Keychain credential deletion (right-click server → "Forget Password")
- [x] Verify no credentials accessible without user interaction

**Phase 6: Hierarchical Volume Display**
- [x] Add `isNetwork` and `serverHost` to `VolumeInfo`
- [x] Add `SyntheticServer` struct for manually-connected volumes
- [x] Add `.syntheticServer` and `.networkVolume` cases to `SidebarItem`
- [x] Add `VolumeInfo.matchesServer(_:)` method
- [x] Refactor `SidebarViewController` to hierarchical data source
- [x] Filter DEVICES to local-only volumes
- [x] Show network volumes under their parent server
- [x] Create synthetic servers for volumes without Bonjour discovery
- [x] Add offline server tracking in `NetworkBrowser`
- [x] Add offline styling (dimmed with "offline" badge)
- [x] Add indentation (8px) for network volumes under servers
- [x] Auto-expand servers with mounted volumes

**Phase 7: Server Eject and Polish**
- [x] Add eject button on servers with mounted volumes
- [x] Add right-click "Eject" context menu for servers
- [x] Add right-click "Connect to Share..." for mounting additional shares
- [x] Remove disclosure triangle, use click-to-expand instead
- [x] Use diskutil with force fallback for network volume unmount
- [x] Add distinct teal icon for network shares
- [x] Update indentation to 8px per Apple HIG guidance
- [x] Fix permission denied error messages for network vs local volumes

---

## Testing

### Automated Tests

Tests go in `Tests/NetworkTests.swift`. Log results in `Tests/TEST_LOG.md`.

- [x] `testNetworkProtocolURLSchemes` - NetworkProtocol returns correct URL schemes (smb, nfs)
- [x] `testNetworkServerEquality` - NetworkServer equality based on host and protocol
- [x] `testNetworkMountErrorDescriptions` - All error cases have user-friendly descriptions
- [x] `testRecentServersMaxCount` - Recent servers list capped at 10 entries
- [x] `testRecentServersPersistence` - Recent servers save/load from UserDefaults
- [x] `testConnectToServerURLValidation` - Valid/invalid URL detection for smb://, nfs://

### XCUITest Tests

Tests go in `Tests/UITests/DetoursUITests/NetworkUITests.swift`. Run with `resources/scripts/uitest.sh NetworkUITests`.

**Sidebar Network Section:**
- [x] `testNetworkSectionExists` - NETWORK section header appears in sidebar between DEVICES and FAVORITES
- [x] `testNetworkSectionShowsPlaceholder` - Shows "No servers found" placeholder when no servers discovered

**Connect to Server Dialog:**
- [x] `testConnectToServerOpensWithKeyboardShortcut` - Cmd+K opens Connect to Server sheet
- [x] `testConnectToServerDialogElements` - Dialog contains URL field, Connect and Cancel buttons
- [x] `testConnectToServerCancelCloses` - Cancel button dismisses dialog
- [x] `testConnectToServerValidatesURL` - Connect button disabled for empty URLs
- [x] `testGoMenuHasConnectToServer` - Go menu has Connect to Server item

### User Verification

**Marco (requires local network with SMB/NFS server):**
- [x] NETWORK section shows discovered servers on local network
- [x] Click server → mounts and navigates to share
- [x] Protected share prompts for credentials
- [x] "Remember in Keychain" + remount → Touch ID/password prompt appears
- [x] Cmd+K opens Connect to Server dialog
- [x] Manual URL entry works for known server
- [x] Server eject button works
- [x] Right-click "Connect to Share..." mounts additional shares
- [x] Network shares show distinct teal icon
