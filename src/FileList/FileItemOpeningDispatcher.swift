import Foundation

enum FileItemOpenAction: Equatable {
    case ordinaryFile
    case virtualSharedFolder
    case folder
    case archive
    case diskImage
}

struct FileItemOpenFailure {
    let item: FileItem
    let error: any Error
}

enum FileItemOpeningError: LocalizedError {
    case failedToOpen(String)
    case permissionDenied(String)
    case remoteProviderUnavailable

    var errorDescription: String? {
        switch self {
        case .failedToOpen(let name):
            return "The system could not open \"\(name)\"."
        case .permissionDenied(let name):
            return "Permission denied: \"\(name)\"."
        case .remoteProviderUnavailable:
            return "The remote connection is unavailable."
        }
    }
}

struct FileItemOpenBatchResult {
    let attemptedItems: [FileItem]
    let openedItems: [FileItem]
    let skippedItems: [FileItem]
    let failures: [FileItemOpenFailure]
    let performedFocusedAction: Bool
    let wasCancelled: Bool
}

@MainActor
struct FileItemOpeningDispatcher {
    typealias ActionPerformer = (FileItem, FileItemOpenAction) -> Result<Void, any Error>
    typealias ConfirmationHandler = (_ fileCount: Int) -> Bool

    let confirmationThreshold: Int
    let confirmsOpening: ConfirmationHandler
    let performsAction: ActionPerformer

    init(
        confirmationThreshold: Int = 5,
        confirmsOpening: @escaping ConfirmationHandler,
        performsAction: @escaping ActionPerformer
    ) {
        self.confirmationThreshold = confirmationThreshold
        self.confirmsOpening = confirmsOpening
        self.performsAction = performsAction
    }

    func open(items: [FileItem], focusedItem: FileItem?) -> FileItemOpenBatchResult {
        let classifiedItems = items.map { ($0, Self.action(for: $0)) }
        let ordinaryItems = classifiedItems.compactMap { item, action in
            action == .ordinaryFile ? item : nil
        }

        guard !ordinaryItems.isEmpty else {
            guard let focusedItem else {
                return FileItemOpenBatchResult(
                    attemptedItems: [],
                    openedItems: [],
                    skippedItems: items,
                    failures: [],
                    performedFocusedAction: false,
                    wasCancelled: false
                )
            }

            let action = Self.action(for: focusedItem)
            let result = performsAction(focusedItem, action)
            return result.batchResult(
                for: focusedItem,
                skippedItems: items.filter { $0 !== focusedItem },
                performedFocusedAction: true
            )
        }

        let skippedItems = classifiedItems.compactMap { item, action in
            action == .ordinaryFile ? nil : item
        }
        guard ordinaryItems.count <= confirmationThreshold || confirmsOpening(ordinaryItems.count) else {
            return FileItemOpenBatchResult(
                attemptedItems: [],
                openedItems: [],
                skippedItems: skippedItems,
                failures: [],
                performedFocusedAction: false,
                wasCancelled: true
            )
        }

        var openedItems: [FileItem] = []
        var failures: [FileItemOpenFailure] = []
        for item in ordinaryItems {
            switch performsAction(item, .ordinaryFile) {
            case .success:
                openedItems.append(item)
            case .failure(let error):
                failures.append(FileItemOpenFailure(item: item, error: error))
            }
        }

        return FileItemOpenBatchResult(
            attemptedItems: ordinaryItems,
            openedItems: openedItems,
            skippedItems: skippedItems,
            failures: failures,
            performedFocusedAction: false,
            wasCancelled: false
        )
    }

    static func action(for item: FileItem) -> FileItemOpenAction {
        if item.isVirtualSharedFolder {
            return .virtualSharedFolder
        }
        if item.isNavigableFolder {
            return .folder
        }
        if FileListViewController.isExtractableArchiveLocation(item.location) {
            return .archive
        }
        if FileOpenHelper.isDiskImage(URL(fileURLWithPath: item.location.path)) {
            return .diskImage
        }
        return .ordinaryFile
    }
}

private extension Result where Success == Void, Failure == any Error {
    func batchResult(
        for item: FileItem,
        skippedItems: [FileItem],
        performedFocusedAction: Bool
    ) -> FileItemOpenBatchResult {
        switch self {
        case .success:
            return FileItemOpenBatchResult(
                attemptedItems: [item],
                openedItems: [item],
                skippedItems: skippedItems,
                failures: [],
                performedFocusedAction: performedFocusedAction,
                wasCancelled: false
            )
        case .failure(let error):
            return FileItemOpenBatchResult(
                attemptedItems: [item],
                openedItems: [],
                skippedItems: skippedItems,
                failures: [FileItemOpenFailure(item: item, error: error)],
                performedFocusedAction: performedFocusedAction,
                wasCancelled: false
            )
        }
    }
}
