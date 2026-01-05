import Foundation

@MainActor
protocol PaneTabBarDelegate: AnyObject {
    func tabBarDidSelectTab(at index: Int)
    func tabBarDidRequestCloseTab(at index: Int)
    func tabBarDidRequestNewTab()
    func tabBarDidReorderTab(from sourceIndex: Int, to destinationIndex: Int)
    func tabBarDidReceiveDroppedTab(_ tab: PaneTab, at index: Int)
}
