import SwiftUI

/// Where this build came from: the checkout, branch and commit, as
/// Scripts/write_build_info.sh found them when the build ran. Release builds
/// have none.
struct BuildInfo: Decodable {
    /// The checkout's path on the machine that built it; tells worktrees apart.
    var checkout: String
    var configuration: String
    var builtAt: Date
    /// Nil when the build wasn't from a git checkout.
    var commit: String?
    /// Nil on a detached HEAD.
    var branch: String?
    /// Tracked files with uncommitted changes.
    var modifiedFiles: Int?
    var untrackedFiles: Int?

    static let current: BuildInfo? = {
        guard let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(BuildInfo.self, from: data)
    }()

    /// The commit, and what the checkout had on top of it: "1a2b3c4 + 2 modified, 1 untracked".
    var commitSummary: String? {
        guard let commit else { return nil }
        var changes: [String] = []
        if let modifiedFiles, modifiedFiles > 0 { changes.append("\(modifiedFiles) modified") }
        if let untrackedFiles, untrackedFiles > 0 { changes.append("\(untrackedFiles) untracked") }
        return changes.isEmpty ? commit : "\(commit) + \(changes.joined(separator: ", "))"
    }
}

/// A Settings section describing the build, for telling test builds apart.
struct BuildInfoSection: View {
    let info: BuildInfo

    var body: some View {
        Section {
            if let branch = info.branch {
                LabeledContent("Branch", value: branch)
            }
            if let commit = info.commitSummary {
                LabeledContent("Commit", value: commit)
            }
            LabeledContent("Checkout", value: info.checkout)
            LabeledContent("Configuration", value: info.configuration)
            LabeledContent("Built", value: info.builtAt.formatted(date: .abbreviated, time: .standard))
        } header: {
            Text("Build")
        } footer: {
            Text("The checkout as it was when this build ran.")
        }
        .textSelection(.enabled)
    }
}
