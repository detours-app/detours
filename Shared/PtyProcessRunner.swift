import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum PtyPromptResponse: Sendable {
    case password
    case empty
}

public enum PtyPasswordEchoPolicy: Sendable {
    case requireToolDisabled
    case disableBeforeResponse
}

public struct PtyProcessInvocation: Sendable {
    public let executable: String
    public let arguments: [String]
    public let currentDirectory: URL?
    public let password: String?
    public let responses: [PtyPromptResponse]
    public let minimumResponses: Int
    public let passwordEchoPolicy: PtyPasswordEchoPolicy

    public init(
        executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        password: String? = nil,
        responses: [PtyPromptResponse] = [],
        minimumResponses: Int? = nil,
        passwordEchoPolicy: PtyPasswordEchoPolicy = .requireToolDisabled
    ) {
        self.executable = executable
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.password = password
        self.responses = responses
        self.minimumResponses = minimumResponses ?? responses.count
        self.passwordEchoPolicy = passwordEchoPolicy
    }
}

public struct PtyProcessResult: Sendable {
    public let status: Int32
    public let output: Data

    public init(status: Int32, output: Data) {
        self.status = status
        self.output = output
    }

    public var outputString: String {
        String(data: output, encoding: .utf8)
            ?? String(data: output, encoding: .isoLatin1)
            ?? ""
    }
}

public enum PtyProcessError: Error, Equatable, Sendable {
    case invalidResponsePolicy
    case missingPassword
    case systemCall(name: String, code: Int32)
    case promptTimedOut(tool: String)
}

public struct PtyProcessRunner: Sendable {
    public static let promptTimeout: TimeInterval = 10
    public static let cancellationGrace: TimeInterval = 1
    public static let preSendDelayMicroseconds: useconds_t = 50_000
    public static let diagnosticTailLimit = 65_536

    public init() {}

    public func run(
        _ invocation: PtyProcessInvocation,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) throws -> PtyProcessResult {
        let controller = PtyProcessController()
        return try run(invocation, controller: controller, onOutput: onOutput)
    }

    public func run(
        _ invocation: PtyProcessInvocation,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) async throws -> PtyProcessResult {
        let controller = PtyProcessController()
        // The run loop blocks on the pseudo-terminal until the process exits.
        // On a Swift concurrency executor that holds one of the pool's fixed
        // number of threads for the whole command; a dispatch queue adds
        // threads when they block instead.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.runQueue.async {
                    do {
                        continuation.resume(returning: try run(invocation, controller: controller, onOutput: onOutput))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            controller.cancel()
        }
    }

    private static let runQueue = DispatchQueue(
        label: "com.detours.pty.run",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private func run(
        _ invocation: PtyProcessInvocation,
        controller: PtyProcessController,
        onOutput: (@Sendable (Data) -> Void)?
    ) throws -> PtyProcessResult {
        guard invocation.minimumResponses >= 0,
              invocation.minimumResponses <= invocation.responses.count else {
            throw PtyProcessError.invalidResponsePolicy
        }
        if invocation.responses.contains(where: { response in
            if case .password = response { return true }
            return false
        }), invocation.password == nil {
            throw PtyProcessError.missingPassword
        }

        var passwordBytes = Array((invocation.password ?? "").utf8)
        defer { _ = passwordBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }

        var primaryDescriptor: Int32 = -1
        var replicaDescriptor: Int32 = -1
        guard openpty(&primaryDescriptor, &replicaDescriptor, nil, nil, nil) == 0 else {
            throw systemError("openpty")
        }
        defer { close(primaryDescriptor) }

        guard let replicaNamePointer = ttyname(replicaDescriptor) else {
            close(replicaDescriptor)
            throw systemError("ttyname")
        }
        let replicaPath = String(cString: replicaNamePointer)
        close(replicaDescriptor)

        let processID: pid_t
        do {
            processID = try spawn(
                invocation,
                primaryDescriptor: primaryDescriptor,
                replicaPath: replicaPath
            )
        } catch {
            throw error
        }
        controller.register(processID: processID)
        defer { controller.clear(processID: processID) }

        let currentFlags = fcntl(primaryDescriptor, F_GETFL)
        guard currentFlags >= 0,
              fcntl(primaryDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            terminateAndReap(processID)
            throw systemError("fcntl")
        }

        let startedAt = Date()
        var cancellationStartedAt: Date?
        var timeoutStarted = false
        var responseIndex = 0
        var promptBytes: [UInt8] = []
        var diagnosticTail = Data()
        var waitStatus: Int32 = 0
        var childExited = false
        var outputClosed = false

        while !childExited || !outputClosed {
            if controller.isCancelled, cancellationStartedAt == nil {
                cancellationStartedAt = Date()
                signalSession(processID, signal: SIGTERM)
            }
            if let cancellationStartedAt,
               Date().timeIntervalSince(cancellationStartedAt) >= Self.cancellationGrace {
                signalSession(processID, signal: SIGKILL)
            }

            if !timeoutStarted,
               responseIndex < invocation.minimumResponses,
               Date().timeIntervalSince(startedAt) >= Self.promptTimeout {
                timeoutStarted = true
                cancellationStartedAt = Date()
                signalSession(processID, signal: SIGTERM)
            }

            var descriptor = pollfd(fd: primaryDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let pollResult = poll(&descriptor, 1, 25)
            if pollResult < 0, errno != EINTR {
                terminateAndReap(processID)
                throw systemError("poll")
            }

            if pollResult > 0, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
                outputClosed = try drainOutput(
                    primaryDescriptor,
                    promptBytes: &promptBytes,
                    diagnosticTail: &diagnosticTail,
                    onOutput: onOutput
                )
            }

            if responseIndex < invocation.responses.count,
               containsPasswordPrompt(promptBytes),
               try prepareTerminalForPassword(
                   primaryDescriptor,
                   policy: invocation.passwordEchoPolicy
               ) {
                usleep(Self.preSendDelayMicroseconds)
                var responseBytes: [UInt8]
                switch invocation.responses[responseIndex] {
                case .password:
                    responseBytes = passwordBytes
                case .empty:
                    responseBytes = []
                }
                responseBytes.append(0x0A)
                try writeAll(responseBytes, to: primaryDescriptor)
                _ = responseBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                responseIndex += 1
                promptBytes.removeAll(keepingCapacity: true)
                if !invocation.responses.dropFirst(responseIndex).contains(where: { response in
                    if case .password = response { return true }
                    return false
                }) {
                    _ = passwordBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                }
            }

            if !childExited {
                let waited = waitpid(processID, &waitStatus, WNOHANG)
                if waited == processID {
                    childExited = true
                } else if waited < 0, errno != EINTR {
                    throw systemError("waitpid")
                }
            }

            if childExited, pollResult == 0 {
                outputClosed = true
            }
        }

        if controller.isCancelled {
            throw CancellationError()
        }
        if timeoutStarted {
            throw PtyProcessError.promptTimedOut(tool: URL(fileURLWithPath: invocation.executable).lastPathComponent)
        }
        return PtyProcessResult(status: decodedExitStatus(waitStatus), output: diagnosticTail)
    }

    private func spawn(
        _ invocation: PtyProcessInvocation,
        primaryDescriptor: Int32,
        replicaPath: String
    ) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else { throw systemError("posix_spawn_file_actions_init", code: result) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        result = posix_spawnattr_init(&attributes)
        guard result == 0 else { throw systemError("posix_spawnattr_init", code: result) }
        defer { posix_spawnattr_destroy(&attributes) }

        result = replicaPath.withCString {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDWR, 0)
        }
        guard result == 0 else { throw systemError("posix_spawn_file_actions_addopen", code: result) }
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            result = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, descriptor)
            guard result == 0 else { throw systemError("posix_spawn_file_actions_adddup2", code: result) }
        }
        result = posix_spawn_file_actions_addclose(&actions, primaryDescriptor)
        guard result == 0 else { throw systemError("posix_spawn_file_actions_addclose", code: result) }

        if let currentDirectory = invocation.currentDirectory {
            result = currentDirectory.path.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            }
            guard result == 0 else { throw systemError("posix_spawn_file_actions_addchdir", code: result) }
        }

        #if canImport(Darwin)
        let spawnSessionFlag = Int16(POSIX_SPAWN_SETSID)
        #else
        let spawnSessionFlag: Int16 = 0x80
        #endif
        result = posix_spawnattr_setflags(&attributes, spawnSessionFlag)
        guard result == 0 else { throw systemError("posix_spawnattr_setflags", code: result) }

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        #if canImport(Darwin)
        // Apple's zip cannot reopen /dev/tty when it is the immediate posix_spawn image.
        // A non-interactive shell preserves the new controlling terminal and immediately
        // replaces itself with the requested executable. Positional arguments avoid
        // interpolation, and the password remains exclusive to terminal input.
        let spawnedExecutable = "/bin/sh"
        let argumentStrings = [spawnedExecutable, "-c", "exec \"$@\"", "detours-pty", invocation.executable]
            + invocation.arguments
        #else
        let spawnedExecutable = invocation.executable
        let argumentStrings = [spawnedExecutable] + invocation.arguments
        #endif
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        let argumentPointers = argumentStrings.map { strdup($0) }
        let environmentPointers = environmentStrings.map { strdup($0) }
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }
        var arguments = argumentPointers + [nil]
        var environmentValues = environmentPointers + [nil]
        var processID: pid_t = 0
        result = spawnedExecutable.withCString { executable in
            posix_spawn(&processID, executable, &actions, &attributes, &arguments, &environmentValues)
        }
        guard result == 0 else { throw systemError("posix_spawn", code: result) }
        return processID
    }

    private func drainOutput(
        _ descriptor: Int32,
        promptBytes: inout [UInt8],
        diagnosticTail: inout Data,
        onOutput: (@Sendable (Data) -> Void)?
    ) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var reachedEnd = false
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer.prefix(count))
                onOutput?(data)
                diagnosticTail.append(data)
                if diagnosticTail.count > Self.diagnosticTailLimit {
                    diagnosticTail.removeFirst(diagnosticTail.count - Self.diagnosticTailLimit)
                }
                promptBytes.append(contentsOf: buffer.prefix(count))
                if promptBytes.count > 4_096 {
                    promptBytes.removeFirst(promptBytes.count - 4_096)
                }
            } else if count == 0 {
                reachedEnd = true
                break
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else if errno == EIO {
                reachedEnd = true
                break
            } else if errno != EINTR {
                throw systemError("read")
            }
        }
        return reachedEnd
    }

    private func containsPasswordPrompt(_ bytes: [UInt8]) -> Bool {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return false }
        let line = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).last ?? ""
        let trimmed = String(line).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.lowercased().contains("password") && trimmed.hasSuffix(":")
    }

    private func terminalEchoIsDisabled(_ descriptor: Int32) -> Bool {
        var settings = termios()
        return tcgetattr(descriptor, &settings) == 0 && settings.c_lflag & tcflag_t(ECHO) == 0
    }

    private func prepareTerminalForPassword(
        _ descriptor: Int32,
        policy: PtyPasswordEchoPolicy
    ) throws -> Bool {
        if terminalEchoIsDisabled(descriptor) {
            return true
        }
        guard policy == .disableBeforeResponse else {
            return false
        }
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            throw systemError("tcgetattr")
        }
        settings.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            throw systemError("tcsetattr")
        }
        return terminalEchoIsDisabled(descriptor)
    }

    private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw systemError("write")
                }
            }
        }
    }

    private func terminateAndReap(_ processID: pid_t) {
        signalSession(processID, signal: SIGTERM)
        let deadline = Date().addingTimeInterval(Self.cancellationGrace)
        var status: Int32 = 0
        while Date() < deadline {
            if waitpid(processID, &status, WNOHANG) == processID { return }
            usleep(10_000)
        }
        signalSession(processID, signal: SIGKILL)
        while waitpid(processID, &status, 0) < 0, errno == EINTR {}
    }

    private func signalSession(_ processID: pid_t, signal: Int32) {
        _ = kill(-processID, signal)
    }

    private func decodedExitStatus(_ status: Int32) -> Int32 {
        let terminationSignal = status & 0x7F
        if terminationSignal == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + terminationSignal
    }

    private func systemError(_ name: String, code: Int32 = errno) -> PtyProcessError {
        PtyProcessError.systemCall(name: name, code: code)
    }
}

private final class PtyProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func register(processID: pid_t) {
        let shouldCancel = lock.withLock {
            self.processID = processID
            return cancelled
        }
        if shouldCancel {
            _ = kill(-processID, SIGTERM)
        }
    }

    func cancel() {
        let processID = lock.withLock {
            cancelled = true
            return self.processID
        }
        if let processID {
            _ = kill(-processID, SIGTERM)
        }
    }

    func clear(processID: pid_t) {
        lock.withLock {
            if self.processID == processID {
                self.processID = nil
            }
        }
    }
}
