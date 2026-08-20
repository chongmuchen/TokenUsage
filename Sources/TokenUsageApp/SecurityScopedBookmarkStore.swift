import Foundation

final class SecurityScopedBookmarkStore {
    private struct PersistedHome: Codable {
        let id: UUID
        var name: String
        var bookmarkData: Data?
        var lastKnownPath: String
        let isDefault: Bool
        var isEnabled: Bool?
    }

    private let defaults: UserDefaults
    private let homesKey = "CodexHomesSecurityScopedBookmarksV2"
    private let legacyKey = "CodexRootSecurityScopedBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadHomes() -> [CodexHome] {
        var records = decodedHomes() ?? migratedHomes()
        records = ensureDefault(in: records)

        var resolved: [CodexHome] = []
        var seenPaths = Set<String>()

        for index in records.indices {
            let resolution = resolve(records[index])
            if let renewedBookmark = resolution.renewedBookmark {
                records[index].bookmarkData = renewedBookmark
                records[index].lastKnownPath = resolution.url.path(percentEncoded: false)
            }

            let pathKey = codexHomePathKey(resolution.url)
            if seenPaths.insert(pathKey).inserted {
                resolved.append(
                    CodexHome(
                        id: records[index].id,
                        name: records[index].name,
                        rootURL: canonicalCodexRoot(resolution.url),
                        isDefault: records[index].isDefault,
                        isEnabled: records[index].isEnabled ?? true,
                        authorizationError: resolution.error,
                        bookmarkData: records[index].bookmarkData
                    )
                )
            }
        }

        // Persist on every successful load. Besides renewing stale bookmarks,
        // this also repairs an empty/corrupt v2 list and makes migration
        // idempotent before the legacy key is removed.
        savePersisted(recordsForHomes(resolved))
        defaults.removeObject(forKey: legacyKey)
        return resolved
    }

    func makeHome(url: URL, existingHomes: [CodexHome], name: String? = nil) throws -> CodexHome {
        let root = canonicalCodexRoot(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexHomeError.notDirectory
        }
        let key = codexHomePathKey(root)
        guard !existingHomes.contains(where: { codexHomePathKey($0.rootURL) == key }) else {
            throw CodexHomeError.duplicatePath
        }

        let bookmark = try root.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let fallbackName = root.lastPathComponent.isEmpty ? "Codex Home" : root.lastPathComponent
        return CodexHome(
            id: UUID(),
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallbackName,
            rootURL: root,
            isDefault: false,
            isEnabled: true,
            authorizationError: nil,
            bookmarkData: bookmark
        )
    }

    func saveHomes(_ homes: [CodexHome]) {
        savePersisted(recordsForHomes(ensureDefaultHomes(homes)))
    }

    private func decodedHomes() -> [PersistedHome]? {
        guard let data = defaults.data(forKey: homesKey) else { return nil }
        return try? JSONDecoder().decode([PersistedHome].self, from: data)
    }

    private func migratedHomes() -> [PersistedHome] {
        var records = [defaultRecord()]
        guard let legacyBookmark = defaults.data(forKey: legacyKey) else { return records }

        var stale = false
        guard let legacyURL = try? URL(
            resolvingBookmarkData: legacyBookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return records }

        let root = canonicalCodexRoot(legacyURL)
        if codexHomePathKey(root) == codexHomePathKey(CodexHome.defaultHome().rootURL) {
            records[0].bookmarkData = renewedBookmark(for: root, fallback: legacyBookmark, stale: stale)
        } else {
            records.append(
                PersistedHome(
                    id: UUID(),
                    name: root.lastPathComponent.isEmpty ? "Codex Home" : root.lastPathComponent,
                    bookmarkData: renewedBookmark(for: root, fallback: legacyBookmark, stale: stale),
                    lastKnownPath: root.path(percentEncoded: false),
                    isDefault: false,
                    isEnabled: true
                )
            )
        }
        return records
    }

    private func ensureDefault(in records: [PersistedHome]) -> [PersistedHome] {
        var result = records
        if let defaultIndex = result.firstIndex(where: \.isDefault) {
            if defaultIndex != 0 {
                let defaultHome = result.remove(at: defaultIndex)
                result.insert(defaultHome, at: 0)
            }
        } else {
            result.insert(defaultRecord(), at: 0)
        }
        return result
    }

    private func ensureDefaultHomes(_ homes: [CodexHome]) -> [CodexHome] {
        guard !homes.contains(where: \.isDefault) else { return homes }
        return [CodexHome.defaultHome()] + homes
    }

    private func defaultRecord() -> PersistedHome {
        let home = CodexHome.defaultHome()
        return PersistedHome(
            id: home.id,
            name: home.name,
            bookmarkData: nil,
            lastKnownPath: home.pathSummary,
            isDefault: true,
            isEnabled: true
        )
    }

    private func recordsForHomes(_ homes: [CodexHome]) -> [PersistedHome] {
        homes.map {
            PersistedHome(
                id: $0.id,
                name: $0.name,
                bookmarkData: $0.bookmarkData,
                lastKnownPath: $0.pathSummary,
                isDefault: $0.isDefault,
                isEnabled: $0.isEnabled
            )
        }
    }

    private func savePersisted(_ records: [PersistedHome]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: homesKey)
    }

    private func resolve(_ record: PersistedHome) -> (url: URL, renewedBookmark: Data?, error: String?) {
        guard let bookmark = record.bookmarkData else {
            return (
                canonicalCodexRoot(URL(fileURLWithPath: record.lastKnownPath, isDirectory: true)),
                nil,
                nil
            )
        }

        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return (
                canonicalCodexRoot(URL(fileURLWithPath: record.lastKnownPath, isDirectory: true)),
                nil,
                "目录授权已失效，请重新添加该 Codex Home。"
            )
        }
        let root = canonicalCodexRoot(url)
        let renewed = stale ? renewedBookmark(for: root, fallback: bookmark, stale: true) : nil
        return (root, renewed, nil)
    }

    private func renewedBookmark(for url: URL, fallback: Data, stale: Bool) -> Data {
        guard stale else { return fallback }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return (try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )) ?? fallback
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
