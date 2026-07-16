import Foundation

struct ZipArchiveMetadata: Equatable, Sendable {
    let isEncrypted: Bool
    let compressionMethods: Set<UInt16>

    var requiresSevenZip: Bool {
        compressionMethods.contains { method in
            method != 0 && method != 8
        }
    }

    static func read(from archive: URL) throws -> ZipArchiveMetadata? {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { return nil }
        let tailSize = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailSize)
        guard let tail = try handle.read(upToCount: Int(tailSize)), tail.count >= 22,
              let endIndex = findEndRecord(in: tail) else {
            return nil
        }

        let endOffset = fileSize - tailSize + UInt64(endIndex)
        var centralSize = UInt64(littleEndianUInt32(tail, at: endIndex + 12))
        var centralOffset = UInt64(littleEndianUInt32(tail, at: endIndex + 16))
        if centralSize == UInt64(UInt32.max) || centralOffset == UInt64(UInt32.max) {
            guard endOffset >= 20,
                  let locator = try read(handle, offset: endOffset - 20, count: 20),
                  littleEndianUInt32(locator, at: 0) == 0x07064B50 else {
                return nil
            }
            let zip64Offset = littleEndianUInt64(locator, at: 8)
            guard let zip64 = try read(handle, offset: zip64Offset, count: 56),
                  littleEndianUInt32(zip64, at: 0) == 0x06064B50 else {
                return nil
            }
            centralSize = littleEndianUInt64(zip64, at: 40)
            centralOffset = littleEndianUInt64(zip64, at: 48)
        }

        guard centralOffset <= fileSize,
              centralSize <= fileSize - centralOffset,
              centralSize <= UInt64(Int.max),
              let directory = try read(handle, offset: centralOffset, count: Int(centralSize)) else {
            return nil
        }

        var encrypted = false
        var methods = Set<UInt16>()
        var index = 0
        while index + 46 <= directory.count {
            guard littleEndianUInt32(directory, at: index) == 0x02014B50 else {
                return nil
            }
            let flags = littleEndianUInt16(directory, at: index + 8)
            encrypted = encrypted || flags & 0x0001 != 0
            methods.insert(littleEndianUInt16(directory, at: index + 10))
            let variableLength = Int(littleEndianUInt16(directory, at: index + 28))
                + Int(littleEndianUInt16(directory, at: index + 30))
                + Int(littleEndianUInt16(directory, at: index + 32))
            guard variableLength <= directory.count - index - 46 else { return nil }
            index += 46 + variableLength
        }
        guard index == directory.count else { return nil }
        return ZipArchiveMetadata(isEncrypted: encrypted, compressionMethods: methods)
    }

    private static func findEndRecord(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for index in stride(from: data.count - 22, through: 0, by: -1)
        where littleEndianUInt32(data, at: index) == 0x06054B50 {
            let commentLength = Int(littleEndianUInt16(data, at: index + 20))
            if index + 22 + commentLength == data.count {
                return index
            }
        }
        return nil
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data? {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    private static func littleEndianUInt16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private static func littleEndianUInt32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(littleEndianUInt16(data, at: index))
            | UInt32(littleEndianUInt16(data, at: index + 2)) << 16
    }

    private static func littleEndianUInt64(_ data: Data, at index: Int) -> UInt64 {
        UInt64(littleEndianUInt32(data, at: index))
            | UInt64(littleEndianUInt32(data, at: index + 4)) << 32
    }
}
