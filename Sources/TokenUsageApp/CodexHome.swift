import Foundation
import TokenUsageCore

/// One Codex data root shown to the App UI.
///
/// `bookmarkData` stays internal to the App target. The UI only needs the
/// stable identity, display name, resolved path, and authorization state.
struct CodexHome: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let rootURL: URL
    let isDefault: Bool
    let isEnabled: Bool
    let authorizationError: String?
    let bookmarkData: Data?

    var isAvailable: Bool { authorizationError == nil }
    var isActive: Bool { isEnabled && isAvailable }

    var pathSummary: String {
        rootURL.path(percentEncoded: false)
    }

    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func defaultHome(bookmarkData: Data? = nil) -> CodexHome {
        CodexHome(
            id: defaultID,
            name: "默认 Codex Home",
            rootURL: canonicalCodexRoot(CodexPaths.defaultRoot),
            isDefault: true,
            isEnabled: true,
            authorizationError: nil,
            bookmarkData: bookmarkData
        )
    }
}

enum CodexHomeError: LocalizedError {
    case notDirectory
    case duplicatePath
    case cannotRemoveDefault

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "所选路径不是可用的 Codex 数据目录。"
        case .duplicatePath:
            "这个 Codex Home 已经添加。"
        case .cannotRemoveDefault:
            "默认 Codex Home 不能删除。"
        }
    }
}

func canonicalCodexRoot(_ url: URL) -> URL {
    CodexPaths.codexRoot(for: url)
        .standardizedFileURL
        .resolvingSymlinksInPath()
}

func codexHomePathKey(_ url: URL) -> String {
    canonicalCodexRoot(url).path(percentEncoded: false)
}
