import Foundation
import Quartz

/// Wraps a generated preview file so Quick Look shows the original file's name in
/// its title bar. Without a `previewItemTitle`, Quick Look falls back to the URL's
/// last path component, which for generated previews is always `preview.html`.
final class DetoursQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
    }
}
