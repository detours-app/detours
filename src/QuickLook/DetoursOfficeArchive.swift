import Compression
import Foundation

enum DetoursOfficeArchiveError: Error, Equatable {
    case notAnArchive
    case corrupt
    case entryNotFound(String)
    case encrypted
    case unsupportedCompression(UInt16)
    case expansionLimitExceeded
}

/// Reads one named part out of an Office container without unpacking the rest of it.
///
/// An Office file is a ZIP of XML parts, and a preview needs three or four of them. Walking the
/// central directory and inflating only what is asked for keeps a large document off the heap, and
/// it extends code this app already trusts: `ZipArchiveMetadata` parses the same directory,
/// including the ZIP64 case, for the archive browser.
///
/// A container may lie about how far its contents expand, so the declared size of a part is checked
/// against a ceiling before a byte of it is read, and the running total is checked against a second
/// ceiling across the document.
final class DetoursOfficeArchive {
    /// How far one part, and one whole document, may expand before reading stops. A container can
    /// declare a tiny compressed size and unpack into something enormous, so neither number is ever
    /// taken on trust from the header.
    static let partByteLimit = 64 * 1_024 * 1_024
    static let documentByteLimit = 256 * 1_024 * 1_024

    private struct Entry {
        let localHeaderOffset: Int
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let isEncrypted: Bool
    }

    private let data: Data
    private let entries: [String: Entry]
    private let partLimit: Int
    private let documentLimit: Int
    private var inflatedTotal = 0

    init(
        data: Data,
        partByteLimit: Int = DetoursOfficeArchive.partByteLimit,
        documentByteLimit: Int = DetoursOfficeArchive.documentByteLimit
    ) throws {
        self.data = data
        self.partLimit = partByteLimit
        self.documentLimit = documentByteLimit
        self.entries = try Self.readCentralDirectory(data)
    }

    func contains(_ name: String) -> Bool {
        entries[name] != nil
    }

    /// The names of every part in the container, in no particular order.
    var entryNames: [String] {
        Array(entries.keys)
    }

    func data(forEntry name: String) throws -> Data {
        guard let entry = entries[name] else {
            throw DetoursOfficeArchiveError.entryNotFound(name)
        }
        if entry.isEncrypted {
            throw DetoursOfficeArchiveError.encrypted
        }
        guard entry.compressionMethod == 0 || entry.compressionMethod == 8 else {
            throw DetoursOfficeArchiveError.unsupportedCompression(entry.compressionMethod)
        }
        guard entry.uncompressedSize <= partLimit,
              inflatedTotal + entry.uncompressedSize <= documentLimit else {
            throw DetoursOfficeArchiveError.expansionLimitExceeded
        }

        let payload = try payloadRange(for: entry)
        let inflated: Data
        if entry.compressionMethod == 0 {
            inflated = data.subdata(in: payload)
        } else {
            inflated = try Self.inflate(data.subdata(in: payload), expectedSize: entry.uncompressedSize)
        }
        inflatedTotal += inflated.count
        guard inflatedTotal <= documentLimit else {
            throw DetoursOfficeArchiveError.expansionLimitExceeded
        }
        return inflated
    }

    /// Where an entry's bytes start, which is only knowable from its local header: the name and
    /// extra field there may be a different length from the ones in the central directory.
    private func payloadRange(for entry: Entry) throws -> Range<Int> {
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count,
              Self.uint32(data, at: header) == 0x0403_4B50 else {
            throw DetoursOfficeArchiveError.corrupt
        }
        let nameLength = Int(Self.uint16(data, at: header + 26))
        let extraLength = Int(Self.uint16(data, at: header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, start <= end else {
            throw DetoursOfficeArchiveError.corrupt
        }
        return start..<end
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written: Int = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                // COMPRESSION_ZLIB is raw DEFLATE here, which is exactly what a ZIP entry carries.
                return compression_decode_buffer(
                    destinationBase,
                    expectedSize,
                    sourceBase,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else {
            throw DetoursOfficeArchiveError.corrupt
        }
        return output.prefix(written)
    }

    private static func readCentralDirectory(_ data: Data) throws -> [String: Entry] {
        guard data.count >= 22 else { throw DetoursOfficeArchiveError.notAnArchive }
        guard let endIndex = findEndRecord(in: data) else {
            throw DetoursOfficeArchiveError.notAnArchive
        }

        var centralSize = Int(uint32(data, at: endIndex + 12))
        var centralOffset = Int(uint32(data, at: endIndex + 16))
        if centralSize == Int(UInt32.max) || centralOffset == Int(UInt32.max) {
            guard endIndex >= 20,
                  uint32(data, at: endIndex - 20) == 0x0706_4B50 else {
                throw DetoursOfficeArchiveError.corrupt
            }
            let zip64Offset = Int(uint64(data, at: endIndex - 20 + 8))
            guard zip64Offset >= 0, zip64Offset + 56 <= data.count,
                  uint32(data, at: zip64Offset) == 0x0606_4B50 else {
                throw DetoursOfficeArchiveError.corrupt
            }
            centralSize = Int(uint64(data, at: zip64Offset + 40))
            centralOffset = Int(uint64(data, at: zip64Offset + 48))
        }

        guard centralOffset >= 0, centralSize >= 0, centralOffset + centralSize <= data.count else {
            throw DetoursOfficeArchiveError.corrupt
        }

        var entries: [String: Entry] = [:]
        var index = centralOffset
        let end = centralOffset + centralSize
        while index + 46 <= end {
            guard uint32(data, at: index) == 0x0201_4B50 else {
                throw DetoursOfficeArchiveError.corrupt
            }
            let flags = uint16(data, at: index + 8)
            let method = uint16(data, at: index + 10)
            var compressedSize = Int(uint32(data, at: index + 20))
            var uncompressedSize = Int(uint32(data, at: index + 24))
            let nameLength = Int(uint16(data, at: index + 28))
            let extraLength = Int(uint16(data, at: index + 30))
            let commentLength = Int(uint16(data, at: index + 32))
            var localOffset = Int(uint32(data, at: index + 42))

            let nameStart = index + 46
            let extraStart = nameStart + nameLength
            guard extraStart + extraLength + commentLength <= end else {
                throw DetoursOfficeArchiveError.corrupt
            }
            let nameBytes = data.subdata(in: nameStart..<extraStart)
            // Office writes UTF-8 names; the Latin-1 reading is a never-failing last resort so one
            // oddly named part cannot take the whole container down.
            let name = String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1)
                ?? ""

            // The ZIP64 extra field carries whichever of the three numbers overflowed, in a fixed
            // order and only when its 32-bit slot is saturated.
            if uncompressedSize == Int(UInt32.max) || compressedSize == Int(UInt32.max)
                || localOffset == Int(UInt32.max) {
                var cursor = extraStart
                let extraEnd = extraStart + extraLength
                while cursor + 4 <= extraEnd {
                    let fieldID = uint16(data, at: cursor)
                    let fieldSize = Int(uint16(data, at: cursor + 2))
                    var value = cursor + 4
                    guard value + fieldSize <= extraEnd else { break }
                    if fieldID == 0x0001 {
                        if uncompressedSize == Int(UInt32.max), value + 8 <= extraEnd {
                            uncompressedSize = Int(uint64(data, at: value))
                            value += 8
                        }
                        if compressedSize == Int(UInt32.max), value + 8 <= extraEnd {
                            compressedSize = Int(uint64(data, at: value))
                            value += 8
                        }
                        if localOffset == Int(UInt32.max), value + 8 <= extraEnd {
                            localOffset = Int(uint64(data, at: value))
                        }
                        break
                    }
                    cursor += 4 + fieldSize
                }
            }

            entries[name] = Entry(
                localHeaderOffset: localOffset,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                isEncrypted: flags & 0x0001 != 0
            )
            index = extraStart + extraLength + commentLength
        }
        guard !entries.isEmpty else { throw DetoursOfficeArchiveError.notAnArchive }
        return entries
    }

    private static func findEndRecord(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 65_557)
        for index in stride(from: data.count - 22, through: lowest, by: -1)
        where uint32(data, at: index) == 0x0605_4B50 {
            let commentLength = Int(uint16(data, at: index + 20))
            if index + 22 + commentLength == data.count {
                return index
            }
        }
        return nil
    }

    private static func uint16(_ data: Data, at index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= data.count else { return 0 }
        let base = data.startIndex + index
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func uint32(_ data: Data, at index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= data.count else { return 0 }
        return UInt32(uint16(data, at: index)) | UInt32(uint16(data, at: index + 2)) << 16
    }

    private static func uint64(_ data: Data, at index: Int) -> UInt64 {
        guard index >= 0, index + 8 <= data.count else { return 0 }
        return UInt64(uint32(data, at: index)) | UInt64(uint32(data, at: index + 4)) << 32
    }
}
