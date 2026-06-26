import XCTest
@testable import Detours

final class PowerShellScriptTests: XCTestCase {
    func testDispatcherPayloadIsUTF16LEBase64() throws {
        let source = PowerShellScript.prelude(operationBody: "param($Arguments)\n$Arguments.Name")
        let script = try PowerShellScript(source: source, arguments: ["Name": "Résumé.txt"])

        XCTAssertEqual(script.decodedSourceForTesting, source)
        XCTAssertTrue(script.decodedSourceForTesting.hasPrefix("param($Arguments)"))
        XCTAssertTrue(script.decodedSourceForTesting.contains("[Console]::OutputEncoding"))
        XCTAssertTrue(script.decodedSourceForTesting.contains("$OutputEncoding"))
    }

    func testArgumentsAreDataNotConcatenated() throws {
        struct Arguments: Encodable {
            let name: String
        }
        let hostileName = #"semi; quote" backtick` dollar$(Get-ChildItem).txt"#
        let source = PowerShellScript.prelude(operationBody: "param($Arguments)\n$Arguments.Name")
        let script = try PowerShellScript(source: source, arguments: Arguments(name: hostileName))

        XCTAssertFalse(script.source.contains(hostileName))
        XCTAssertTrue(script.argumentsJSON.contains(#"semi; quote\" backtick` dollar$(Get-ChildItem).txt"#))
        XCTAssertTrue(script.decodedSourceForTesting.contains("param($Arguments)"))
    }
}
