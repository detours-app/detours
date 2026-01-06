import Foundation

struct FileOperationProgress {
    let operation: FileOperation
    var currentItem: URL?
    var completedCount: Int
    var totalCount: Int
    var bytesCompleted: Int64
    var bytesTotal: Int64

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}
