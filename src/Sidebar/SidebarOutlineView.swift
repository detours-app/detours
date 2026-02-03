import AppKit

/// Custom outline view that hides disclosure triangles.
/// Expansion is handled via row click instead.
final class SidebarOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // Return zero frame to hide disclosure triangle
        return .zero
    }
}
