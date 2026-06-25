import Foundation

struct PowerShellScript: Equatable, Sendable {
    let source: String
    let argumentsJSON: String

    init<Arguments: Encodable>(source: String, arguments: Arguments) throws {
        self.source = source
        let data = try JSONEncoder.detoursWindows.encode(arguments)
        argumentsJSON = String(decoding: data, as: UTF8.self)
    }

    init(source: String) {
        self.source = source
        argumentsJSON = "{}"
    }

    var sourceBase64UTF16LE: String {
        Data(source.utf16LittleEndianBytes).base64EncodedString()
    }

    var decodedSourceForTesting: String {
        String(data: Data(base64Encoded: sourceBase64UTF16LE) ?? Data(), encoding: .utf16LittleEndian) ?? ""
    }

    static func prelude(operationBody: String) -> String {
        """
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

private extension String {
    var utf16LittleEndianBytes: [UInt8] {
        Array(utf16.flatMap { codeUnit in
            [UInt8(codeUnit & 0x00ff), UInt8(codeUnit >> 8)]
        })
    }
}
