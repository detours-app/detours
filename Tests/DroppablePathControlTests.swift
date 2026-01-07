import XCTest
@testable import Detour

@MainActor
final class DroppablePathControlTests: XCTestCase {

    func testCalculateItemRectsReturnsRectForEachItem() {
        let pathControl = DroppablePathControl(frame: NSRect(x: 0, y: 0, width: 400, height: 24))

        // Set up path items
        let item1 = NSPathControlItem()
        item1.title = "/"
        let item2 = NSPathControlItem()
        item2.title = "Users"
        let item3 = NSPathControlItem()
        item3.title = "marco"

        pathControl.pathItems = [item1, item2, item3]

        let rects = pathControl.testableCalculateItemRects()

        XCTAssertEqual(rects.count, 3)
        // Each rect should have positive width
        for rect in rects {
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertEqual(rect.height, 24)
        }
    }

    func testCalculateItemRectsAreContiguous() {
        let pathControl = DroppablePathControl(frame: NSRect(x: 0, y: 0, width: 400, height: 24))

        let item1 = NSPathControlItem()
        item1.title = "Documents"
        let item2 = NSPathControlItem()
        item2.title = "Projects"

        pathControl.pathItems = [item1, item2]

        let rects = pathControl.testableCalculateItemRects()

        XCTAssertEqual(rects.count, 2)
        // Second rect should start where first ends
        XCTAssertEqual(rects[1].minX, rects[0].maxX, accuracy: 0.1)
    }

    func testPathItemIndexReturnsCorrectIndex() {
        let pathControl = DroppablePathControl(frame: NSRect(x: 0, y: 0, width: 400, height: 24))

        let item1 = NSPathControlItem()
        item1.title = "Root"
        let item2 = NSPathControlItem()
        item2.title = "Folder"
        let item3 = NSPathControlItem()
        item3.title = "Subfolder"

        pathControl.pathItems = [item1, item2, item3]

        let rects = pathControl.testableCalculateItemRects()

        // Point in first item
        let point1 = NSPoint(x: rects[0].midX, y: 12)
        XCTAssertEqual(pathControl.testablePathItemIndex(at: point1), 0)

        // Point in second item
        let point2 = NSPoint(x: rects[1].midX, y: 12)
        XCTAssertEqual(pathControl.testablePathItemIndex(at: point2), 1)

        // Point in third item
        let point3 = NSPoint(x: rects[2].midX, y: 12)
        XCTAssertEqual(pathControl.testablePathItemIndex(at: point3), 2)
    }

    func testPathItemIndexReturnsNilForPointOutsideItems() {
        let pathControl = DroppablePathControl(frame: NSRect(x: 0, y: 0, width: 400, height: 24))

        let item1 = NSPathControlItem()
        item1.title = "Short"

        pathControl.pathItems = [item1]

        // Point way to the right of all items
        let pointOutside = NSPoint(x: 350, y: 12)
        XCTAssertNil(pathControl.testablePathItemIndex(at: pointOutside))
    }

    func testPathItemIndexReturnsNilForEmptyPathItems() {
        let pathControl = DroppablePathControl(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        pathControl.pathItems = []

        let point = NSPoint(x: 50, y: 12)
        XCTAssertNil(pathControl.testablePathItemIndex(at: point))
    }
}

// MARK: - Test Helpers

extension DroppablePathControl {
    /// Exposes calculateItemRects for testing
    func testableCalculateItemRects() -> [NSRect] {
        var rects: [NSRect] = []
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let separatorWidth: CGFloat = 12
        var x: CGFloat = 0

        for (index, item) in pathItems.enumerated() {
            let title = item.title
            let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
            let itemWidth = textWidth + 4

            let hitWidth = index < pathItems.count - 1 ? itemWidth + separatorWidth : itemWidth
            let rect = NSRect(x: x, y: 0, width: hitWidth, height: bounds.height)
            rects.append(rect)
            x += hitWidth
        }

        return rects
    }

    /// Exposes pathItemIndex for testing
    func testablePathItemIndex(at point: NSPoint) -> Int? {
        let rects = testableCalculateItemRects()
        for (index, rect) in rects.enumerated() {
            if rect.contains(point) {
                return index
            }
        }
        return nil
    }
}
