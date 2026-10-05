import Foundation

public struct ShellResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
    /// stdout and stderr together; some tools (e.g. `svc usb getFunctions`) print results on stderr.
    public var combined: String { stdout + stderr }
}

public enum ShellError: Error, CustomStringConvertible {
    case timeout(String)
    case launch(String, Error)
    public var description: String {
        switch self {
        case .timeout(let cmd): return "timed out: \(cmd)"
        case .launch(let cmd, let err): return "could not run \(cmd): \(err)"
        }
    }
}

public enum Shell {
    /// Runs an executable with arguments, capturing output. Never goes through a shell, so arguments are not re-parsed.
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30, input: String? = nil) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = inPipe
        do { try p.run() } catch { throw ShellError.launch(([path] + args).joined(separator: " "), error) }
        if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try? inPipe.fileHandleForWriting.close()

        // Drain pipes concurrently so a chatty child cannot block on a full pipe.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()
            throw ShellError.timeout(([path] + args).joined(separator: " "))
        }
        group.wait()
        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }

    public static var isRoot: Bool { geteuid() == 0 }
    public static var sudoUser: String? {
        guard isRoot, let u = ProcessInfo.processInfo.environment["SUDO_USER"], !u.isEmpty, u != "root" else { return nil }
        return u
    }
}
