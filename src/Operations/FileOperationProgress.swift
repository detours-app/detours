import Foundation

struct FileOperationProgress {
    let operation: FileOperation
    var currentItem: URL?
    var completedCount: Int
    var totalCount: Int
    var bytesCompleted: Int64
    var bytesTotal: Int64

    var fractionCompleted: Double {
        if bytesTotal > 0 {
            return min(Double(bytesCompleted) / Double(bytesTotal), 1.0)
        }
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}
