import Foundation

@MainActor
protocol SidebarDelegate: AnyObject {
    /// Called when user clicks a sidebar item to navigate
    func sidebarDidSelectItem(_ item: SidebarItem)

    /// Called when user requests to eject a volume
    func sidebarDidRequestEject(_ volume: VolumeInfo)

    /// Called when user adds a folder to favorites via drag-drop
    func sidebarDidAddFavorite(_ url: URL)

    /// Called when user removes a folder from favorites
    func sidebarDidRemoveFavorite(_ url: URL)

    /// Called when user reorders favorites via drag-drop
    func sidebarDidReorderFavorites(_ urls: [URL])
}
