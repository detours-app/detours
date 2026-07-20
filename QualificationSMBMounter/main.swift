import Foundation
import NetFS

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("detours-qualification-smb-mounter: \(message)\n".utf8))
    exit(1)
}

private func failMount(status: Int32) -> Never {
    FileHandle.standardError.write(Data("detours-qualification-smb-mounter: mount failed with status \(status)\n".utf8))
    exit(status > 0 && status < 126 ? status : 1)
}

private func value(after option: String, in arguments: [String]) -> String {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
        fail("missing \(option)")
    }
    return arguments[index + 1]
}

let environment = ProcessInfo.processInfo.environment
guard environment["DETOURS_QUALIFICATION_SECRET_TRANSPORT"] == "stdin-v1" else {
    fail("credential transport marker is missing")
}
guard let password = environment["DETOURS_SMB_TEST_PASSWORD"], !password.isEmpty else {
    fail("credential is empty")
}

let arguments = Array(CommandLine.arguments.dropFirst())
let mountParent = URL(
    fileURLWithPath: value(after: "--mount-parent", in: arguments),
    isDirectory: true
).standardizedFileURL
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: mountParent.path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
    fail("mount parent is unavailable")
}
guard let shareURL = URL(string: "smb://devtest/Detours%20Qualification") else {
    fail("fixed share URL is invalid")
}

let openOptions = NSMutableDictionary()
openOptions[kNetFSUseAuthenticationInfoKey] = true
openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
let mountOptions = NSMutableDictionary()
mountOptions[kNetFSSoftMountKey] = true
var mountPoints: Unmanaged<CFArray>?

let status = NetFSMountURLSync(
    shareURL as CFURL,
    mountParent as CFURL,
    "detours-qualification" as CFString,
    password as CFString,
    openOptions as CFMutableDictionary,
    mountOptions as CFMutableDictionary,
    &mountPoints
)
guard status == 0 else {
    failMount(status: status)
}
if let mountedURLs = mountPoints?.takeRetainedValue() as? [URL],
   let mountedURL = mountedURLs.first {
    print(mountedURL.standardizedFileURL.path)
    exit(0)
}

let expectedMount = mountParent.appendingPathComponent("Detours Qualification", isDirectory: true)
if FileManager.default.fileExists(atPath: expectedMount.path) {
    print(expectedMount.standardizedFileURL.path)
    exit(0)
}
FileHandle.standardError.write(Data("detours-qualification-smb-mounter: mount succeeded without a mount point\n".utf8))
exit(2)
