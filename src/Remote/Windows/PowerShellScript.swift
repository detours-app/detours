import Foundation

struct PowerShellScript: Equatable, Sendable {
    let source: String
    let argumentsJSON: String

    init<Arguments: Encodable>(source: String, arguments: Arguments) throws {
        self.source = source
        let data = try JSONEncoder.detoursWindows.encode(arguments)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(arguments, EncodingError.Context(
                codingPath: [],
                debugDescription: "PowerShell arguments JSON was not valid UTF-8."
            ))
        }
        argumentsJSON = json
    }

    init(source: String) {
        self.source = source
        argumentsJSON = "{}"
    }

    var sourceBase64UTF16LE: String {
        source.utf16LittleEndianData.base64EncodedString()
    }

    var decodedSourceForTesting: String {
        guard let data = Data(base64Encoded: sourceBase64UTF16LE) else { return "" }
        return String(bytes: data, encoding: .utf16LittleEndian) ?? ""
    }

    static func prelude(operationBody: String) -> String {
        let lines = operationBody.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let parameterIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let candidate = lines[parameterIndex].trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix("param(") || candidate.hasPrefix("param (") {
                var bodyLines = lines
                bodyLines.remove(at: parameterIndex)
                return """
                \(candidate)
                $ErrorActionPreference = 'Stop'
                [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                \(bodyLines.joined(separator: "\n"))
                """
            }
        }

        return """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        \(operationBody)
        """
    }
}

extension JSONEncoder {
    static var detoursWindows: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var detoursWindows: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

extension String {
    /// UTF-16 little-endian bytes (no byte-order mark), the encoding PowerShell's
    /// `-EncodedCommand` and the `[scriptblock]::Create` dispatcher expect.
    var utf16LittleEndianData: Data {
        Data(utf16.flatMap { [UInt8($0 & 0x00ff), UInt8($0 >> 8)] })
    }
}
