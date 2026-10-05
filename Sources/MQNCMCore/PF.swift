import Foundation

/// NAT for Mac -> Quest internet sharing, confined to the `com.apple/mqncm` anchor.
/// pf is enabled with a reference token (`pfctl -E`) and released with `pfctl -X`, so other users of pf
/// (Internet Sharing, VPN clients) are unaffected. Never `pfctl -d`, never touches the main ruleset.
public enum PF {
    public static let anchor = "com.apple/mqncm"
    static let pfctl = "/sbin/pfctl"
    static let stateDir = "/Library/Application Support/Mac-Quest-NCM"
    static var tokenFile: String { "\(stateDir)/pf-token" }
    /// Pre-rename (questlink) anchor and token, cleaned up by `disable()`.
    static let legacyAnchor = "com.apple/questlink"
    static let legacyTokenFile = "/Library/Application Support/QuestLink/pf-token"

    /// True when a pf token is held for sharing. The token file is world-readable, so this works without root.
    public static var isSharing: Bool { FileManager.default.fileExists(atPath: tokenFile) }

    public static func rule(egress: String, plan: LinkPlan) -> String {
        "nat on \(egress) inet from \(plan.subnetCIDR) to ! \(plan.subnetCIDR) -> (\(egress))\n"
    }

    public static func enable(egress: String, plan: LinkPlan) throws -> String {
        guard Shell.isRoot else { throw NetError.refuse("internet sharing needs root: run with sudo") }
        let load = try Shell.run(pfctl, ["-a", anchor, "-f", "-"], input: rule(egress: egress, plan: plan))
        guard load.ok else { throw NetError.command("pfctl load failed: \(load.combined)") }
        if let existing = try? String(contentsOfFile: tokenFile, encoding: .utf8), !existing.isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let en = try Shell.run(pfctl, ["-E"])
        guard let tok = en.combined.split(separator: "\n").first(where: { $0.contains("Token") })?
                .split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else {
            throw NetError.command("pfctl -E gave no token: \(en.combined)")
        }
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try tok.write(toFile: tokenFile, atomically: true, encoding: .utf8)
        return tok
    }

    public static func disable() throws {
        guard Shell.isRoot else { throw NetError.refuse("needs root: run with sudo") }
        try Shell.run(pfctl, ["-a", anchor, "-F", "all"])
        if let tok = try? String(contentsOfFile: tokenFile, encoding: .utf8) {
            try Shell.run(pfctl, ["-X", tok.trimmingCharacters(in: .whitespacesAndNewlines)])
            try? FileManager.default.removeItem(atPath: tokenFile)
        }
        try Shell.run(pfctl, ["-a", legacyAnchor, "-F", "all"])
        if let tok = try? String(contentsOfFile: legacyTokenFile, encoding: .utf8) {
            try Shell.run(pfctl, ["-X", tok.trimmingCharacters(in: .whitespacesAndNewlines)])
            try? FileManager.default.removeItem(atPath: legacyTokenFile)
        }
    }

    public static func loadedRules() -> String? {
        guard Shell.isRoot, let r = try? Shell.run(pfctl, ["-a", anchor, "-s", "nat"]) else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
