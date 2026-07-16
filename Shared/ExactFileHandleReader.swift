import Foundation

public enum ExactFileHandleReader {
    /// Reads until `count` bytes have arrived or the handle reaches EOF. Pipe
    /// reads may legally return short chunks even when more bytes are coming.
    public static func read(_ count: Int, from handle: FileHandle) -> Data {
        guard count > 0 else { return Data() }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk = handle.readData(ofLength: count - data.count)
            guard !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }
}
