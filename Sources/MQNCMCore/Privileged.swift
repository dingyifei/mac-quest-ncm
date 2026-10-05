import Foundation

/// Root-only operations. Runs in-process when already root (the CLI under sudo); otherwise asks for an
/// administrator password once via `osascript … with administrator privileges` and runs the bundled `mqncm`.
public enum Privileged {
    /// The `mqncm` binary to elevate: the copy inside the app bundle, else next to the running executable.
    public static func cliPath() -> String? {
        if let p = Bundle.main.path(forResource: "mqncm", ofType: nil) { return p }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("mqncm").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs `mqncm <args>` as root. SUDO_USER is passed so adb still runs as the logged-in user.
    public static func runCLI(_ args: [String]) throws -> ShellResult {
        guard let cli = cliPath() else { throw NetError.command("mqncm binary not found next to the app") }
        let user = NSUserName()
        let cmd = (["/usr/bin/env", "SUDO_USER=\(user)", cli] + args).map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleScriptString(cmd)) with administrator privileges"
        return try Shell.run("/usr/bin/osascript", ["-e", script], timeout: 180)
    }

    public static func share(on: Bool, options: LinkOptions, log: @escaping (String) -> Void) throws {
        if Shell.isRoot {
            var o = options
            o.share = on
            if on { try Link(log: log).up(o) } else { try Link(log: log).shareOff(o) }
            return
        }
        var args = ["share", on ? "on" : "off", "--subnet", options.plan.subnetPrefix]
        if on, let dns = options.dns.first { args += ["--dns", dns] }
        if let s = options.serial { args += ["--serial", s] }
        let r = try runCLI(args)
        r.stdout.split(separator: "\n").forEach { log(String($0)) }
        guard r.ok else {
            let msg = r.stderr.contains("-128") ? "cancelled" : r.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NetError.command("share \(on ? "on" : "off") failed: \(msg)")
        }
    }
}
