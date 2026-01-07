import Foundation

@MainActor
protocol PaneTabBarDelegate: AnyObject {
    func tabBarDidSelectTab(at index: Int)
    func tabBarDidRequestCloseTab(at index: Int)
    func tabBarDidRequestNewTab()
    func tabBarDidRequestBack()
    func tabBarDidRequestForward()
    func tabBarDidReorderTab(from sourceIndex: Int, to destinationIndex: Int)
    func tabBarDidReceiveDroppedTab(_ tab: PaneTab, at index: Int)
    func tabBarDidReceiveFileDrop(urls: [URL], to destination: URL, isCopy: Bool)
    func tabBarCurrentDirectory(forTabAt index: Int) -> URL?
}
