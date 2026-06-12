import XCTest
@testable import Detours

final class SSHConfigParserTests: XCTestCase {
    func testSuggestsTopLevelHosts() {
        let config = """
        Host devtest *.lab
          HostName devtest.local

        Include ~/.ssh/conf.d/*.conf

        Match host secret
          Host hidden
          User root

        Host prod !blocked *
          HostName prod.example.com

        Host devtest
          User marco
        """

        let suggestions = SSHConfigParser().hostSuggestions(from: config)

        XCTAssertEqual(suggestions, ["devtest", "*.lab", "prod"])
    }
}
