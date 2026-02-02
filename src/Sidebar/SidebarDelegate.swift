import Foundation

@MainActor
protocol SidebarDelegate: AnyObject {
    /// Called when user clicks a sidebar item to navigate
    func sidebarDidSelectItem(_ item: SidebarItem)

    /// Called when user requests to eject a volume
    func sidebarDidRequestEject(_ volume: VolumeInfo)

    /// Called when user adds a folder to favorites via drag-drop
    func sidebarDidAddFavorite(_ url: URL, at index: Int?)

    /// Called when user removes a folder from favorites
    func sidebarDidRemoveFavorite(_ url: URL)

    /// Called when user reorders favorites via drag-drop
    func sidebarDidReorderFavorites(_ urls: [URL])

    /// Called when user drops files onto a favorite to copy/move them there
    func sidebarDidDropFiles(_ urls: [URL], to destination: URL, isCopy: Bool)
}
