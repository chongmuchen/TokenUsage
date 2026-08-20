import CSQLite
import Foundation

public actor ThreadTitleStore {
    public init() {}

    public func titles(for threadIDs: Set<String>, codexRoot: URL, prefixLimit: Int = 36) -> [String: String] {
        guard !threadIDs.isEmpty else { return [:] }
        var collected: [String: String] = [:]
        for databaseURL in candidateDatabases(in: codexRoot) {
            let remaining = threadIDs.subtracting(Set(collected.keys))
            guard !remaining.isEmpty else { break }
            if let result = query(databaseURL: databaseURL, threadIDs: remaining, prefixLimit: prefixLimit) {
                collected.merge(result, uniquingKeysWith: { current, _ in current })
            }
        }
        return collected
    }

    public static func makeTitle(from firstMessage: String, prefixLimit: Int = 36) -> String? {
        guard prefixLimit > 0 else { return nil }
        let normalized = userRequestText(from: firstMessage)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let prefix = String(normalized.prefix(prefixLimit))
        return normalized.count > prefix.count ? prefix + "…" : prefix
    }

    /// Codex Desktop may wrap an attached-file prompt in a local metadata
    /// preamble. That preamble is useful to the runtime, but it is not a useful
    /// session title. Prefer the explicit request section and otherwise peel
    /// only a recognized leading attachment block.
    static func userRequestText(from firstMessage: String) -> String {
        let text = firstMessage
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return text
        }
        if let inline = requestHeadingBody(lines[firstIndex]) {
            return ([inline] + Array(lines.dropFirst(firstIndex + 1))).joined(separator: "\n")
        }
        guard isAttachmentHeader(lines[firstIndex]) || isAttachmentDirective(lines[firstIndex]) else {
            return text
        }

        var index = firstIndex + 1
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if let inline = requestHeadingBody(line) {
                return ([inline] + Array(lines.dropFirst(index + 1))).joined(separator: "\n")
            }
            if line.isEmpty
                || isAttachmentHeader(line)
                || isAttachmentDirective(line)
                || isAttachedFileEntry(line)
            {
                index += 1
                continue
            }
            return lines[index...].joined(separator: "\n")
        }
        return ""
    }

    private static func isAttachmentHeader(_ line: String) -> Bool {
        // Match only Codex's known attachment-envelope headings. A looser
        // keyword check would incorrectly strip ordinary Markdown such as
        // “# User file management”. Keep the observed `metioned` typo for
        // compatibility with older/copied envelopes.
        let pattern = #"(?i)^\s{0,3}#{1,6}\s*(?:(?:files?\s+(?:mentioned|metioned|attached|uploaded)\s+by\s+(?:the\s+)?user)|(?:(?:attached|uploaded)\s+files?))\s*:?\s*$"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isAttachedFileEntry(_ line: String) -> Bool {
        guard line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return false }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("/")
            || value.hasPrefix("~")
            || value.hasPrefix("file://")
            || value.hasPrefix("http://")
            || value.hasPrefix("https://")
            || value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
            || value.contains("codex-clipboard-")
    }

    private static func isAttachmentDirective(_ line: String) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.hasPrefix("distinguish instructions")
            && (lower.contains("attached") || lower.contains("uploaded"))
            && lower.contains("request")
    }

    /// Returns nil when the line is not a request heading. An empty string is
    /// a valid match when the request starts on the next line.
    private static func requestHeadingBody(_ line: String) -> String? {
        let pattern = #"(?i)^\s*#{1,6}\s*(?:my\s+request(?:\s+for\s+codex)?|我的请求)\s*:?[ \t]*(.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range), match.range.location != NSNotFound else {
            return nil
        }
        guard let bodyRange = Range(match.range(at: 1), in: line) else { return "" }
        return String(line[bodyRange])
    }

    private func candidateDatabases(in codexRoot: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: codexRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { url in
                url.pathExtension == "sqlite"
                    && url.deletingPathExtension().lastPathComponent.range(
                        of: #"^state_[0-9]+$"#,
                        options: .regularExpression
                    ) != nil
            }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    private func query(databaseURL: URL, threadIDs: Set<String>, prefixLimit: Int) -> [String: String]? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close_v2(database) }
            return nil
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 200)

        var statement: OpaquePointer?
        let sql = "SELECT first_user_message FROM threads WHERE id = ? LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result: [String: String] = [:]
        for threadID in threadIDs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let bindResult = threadID.withCString { pointer in
                sqlite3_bind_text(statement, 1, pointer, -1, transient)
            }
            guard bindResult == SQLITE_OK else { continue }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { continue }
            let message = String(cString: value)
            if let title = Self.makeTitle(from: message, prefixLimit: prefixLimit) {
                result[threadID] = title
            }
        }
        return result
    }
}
