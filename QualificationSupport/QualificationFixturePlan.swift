import Foundation

public struct QualificationFixturePlan: Codable, Equatable, Sendable {
    public struct LocalFixture: Codable, Equatable, Sendable {
        public let provider: QualificationProvider
        public let parentPath: String
        public let rootPath: String

        public init(provider: QualificationProvider, parentPath: String, rootPath: String) {
            self.provider = provider
            self.parentPath = parentPath
            self.rootPath = rootPath
        }
    }

    public struct RemoteFixture: Codable, Equatable, Sendable {
        public let provider: QualificationProvider
        public let sshTarget: String

        public init(provider: QualificationProvider, sshTarget: String) {
            self.provider = provider
            self.sshTarget = sshTarget
        }
    }

    public let localFixtures: [LocalFixture]
    public let remoteFixtures: [RemoteFixture]

    public init(localFixtures: [LocalFixture], remoteFixtures: [RemoteFixture]) {
        self.localFixtures = localFixtures
        self.remoteFixtures = remoteFixtures
    }

    public static let remoteTargets = [
        RemoteFixture(provider: .linux, sshTarget: "devtest"),
        RemoteFixture(provider: .intelMac, sshTarget: "wraith"),
        RemoteFixture(provider: .windows, sshTarget: "win-carriercall"),
    ]
}
