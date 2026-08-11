import Foundation
import WebKit

/// Serves the rest of a long preview to the page, a chunk at a time, on request.
///
/// The alternative is putting the whole file in the document and only building part of it, which
/// still means the page reads all of it. Here the document holds its first lines and nothing else,
/// and asks for each further chunk only when it is scrolled towards, so a file nobody scrolls
/// through is never read past its first screenful.
final class DetoursPreviewChunkHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "detours-preview-chunk"

    private let queue = DispatchQueue(label: "com.detours.preview-chunks")
    private var _directory: URL?

    /// The preview whose chunks may be served. Set when a preview is loaded, so a page can never
    /// ask for anything belonging to a different file.
    var directory: URL? {
        get { queue.sync { _directory } }
        set { queue.sync { _directory = newValue } }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let directory else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        // The last path component names the chunk. It is checked against the shape a chunk name
        // has, so nothing else under the preview's folder can be asked for.
        let name = url.lastPathComponent
        guard Self.isChunkName(name) else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        let file = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": "\(data.count)",
                // The page is loaded from a file, so asking this scheme is a cross-origin request.
                "Access-Control-Allow-Origin": "*"
            ]
        )
        if let response {
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.badServerResponse))
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    nonisolated static func isChunkName(_ name: String) -> Bool {
        guard name.hasPrefix("chunk-"), name.hasSuffix(".html") else { return false }
        let digits = name.dropFirst("chunk-".count).dropLast(".html".count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    nonisolated static func chunkName(_ index: Int) -> String { "chunk-\(index).html" }
}
