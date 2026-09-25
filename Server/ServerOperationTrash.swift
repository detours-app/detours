import Foundation
import RemoteOperationSupport

struct ServerOperationTrash: Sendable {
    struct Reservation: Codable, Equatable, Sendable {
        let original: OperationLocation
        let item: OperationLocation
        let information: OperationLocation
    }

    let homeDirectory: URL
    let account: OperationAccount

    func plan(id: OperationItemID, original: OperationLocation) throws -> Reservation {
        guard original.account == account, case .unix(let bytes) = original.path,
              bytes.first == 47, !bytes.contains(0) else { throw OperationFilesystemError.invalidPath }
        let name = "\(id.operation)-\(id.item)"
        return Reservation(
            original: original,
            item: OperationLocation(account: account, path: .unix(Data(filesDirectory.appendingPathComponent(name).path.utf8))),
            information: OperationLocation(account: account, path: .unix(Data(infoDirectory.appendingPathComponent(name + ".trashinfo").path.utf8)))
        )
    }

    func prepare(_ reservation: Reservation) throws -> OperationEffect {
        let names = try validate(reservation)
        try ensureDirectories()
        let files = try OperationDirectory(path: Data(filesDirectory.path.utf8))
        let info = try OperationDirectory(path: Data(infoDirectory.path.utf8))
        try files.requirePrivate()
        try info.requirePrivate()
        guard case .missing = try files.lookup(names.item) else { throw OperationFilesystemError.unexpectedContents }
        let created = try info.createExclusiveFile(names.information)
        let output = created.handle
        defer { try? output.close() }
        try output.write(contentsOf: Self.contents(reservation.original))
        try output.synchronize()
        try info.synchronize()
        let observed = try info.observe(names.information)
        guard observed.identity == created.identity else { throw OperationFilesystemError.identityChanged }
        return OperationEffect(location: reservation.information, observation: observed)
    }

    func removeInformation(_ effect: OperationEffect, reservation: Reservation) throws {
        let names = try validate(reservation)
        guard effect.location == reservation.information else { throw OperationContractError.invalidReceipt }
        let directory = try OperationDirectory(path: Data(infoDirectory.path.utf8))
        try directory.requirePrivate()
        try directory.removeOwnedFile(names.information, identity: effect.observation.identity)
    }

    private var trashDirectory: URL { homeDirectory.appendingPathComponent(".local/share/Trash") }
    private var filesDirectory: URL { trashDirectory.appendingPathComponent("files") }
    private var infoDirectory: URL { trashDirectory.appendingPathComponent("info") }

    private func ensureDirectories() throws {
        for url in [trashDirectory, filesDirectory, infoDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try OperationDirectory(path: Data(url.path.utf8)).requirePrivate()
        }
    }

    private func validate(_ reservation: Reservation) throws -> (item: Data, information: Data) {
        guard reservation.original.account == account, reservation.item.account == account,
              reservation.information.account == account,
              case .unix(let item) = reservation.item.path, case .unix(let info) = reservation.information.path else {
            throw OperationContractError.identityMismatch
        }
        let itemPrefix = Data((filesDirectory.path + "/").utf8)
        let infoPrefix = Data((infoDirectory.path + "/").utf8)
        guard item.starts(with: itemPrefix), info.starts(with: infoPrefix) else { throw OperationFilesystemError.invalidPath }
        let itemName = Data(item.dropFirst(itemPrefix.count))
        let infoName = Data(info.dropFirst(infoPrefix.count))
        guard !itemName.isEmpty, !itemName.contains(47), !itemName.contains(0),
              infoName == itemName + Data(".trashinfo".utf8) else { throw OperationFilesystemError.invalidPath }
        return (itemName, infoName)
    }

    private static func contents(_ original: OperationLocation) throws -> Data {
        guard case .unix(let bytes) = original.path, bytes.first == 47, !bytes.contains(0) else {
            throw OperationFilesystemError.invalidPath
        }
        let encoded = bytes.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 47, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return Data("[Trash Info]\nPath=\(encoded)\nDeletionDate=\(formatter.string(from: Date()))\n".utf8)
    }
}
