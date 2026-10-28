import Foundation
import SQLite3

/// Every document ever read, searchable by what it says.
///
/// The list in the main window is a work queue; this is the record. A row is
/// written when a file's result lands and rewritten when it is corrected, and
/// it stays when the file leaves the list, so a contract read in March can be
/// found in October by a phrase in it.
///
/// Backed by SQLite FTS5 with the trigram tokenizer, which needs no word
/// segmentation and so finds Chinese, Japanese and English alike. A query
/// shorter than three characters cannot use the trigram index and is matched
/// with LIKE instead, scanning the rows.
final class HistoryIndex: @unchecked Sendable {

    struct Entry: Identifiable, Equatable {
        var id: UUID
        var path: String
        var name: String
        var engine: OCREngine?
        var pages: Int
        var recognizedAt: Date
        /// Text around the match, with the match between `snippetMarks`.
        /// The start of the document when there is no query.
        var snippet: String
    }

    /// What `search` puts around a match in a snippet.
    static let snippetMarks = ("\u{E000}", "\u{E001}")

    private let queue = DispatchQueue(label: "OCRFlow.history", qos: .utility)
    private var db: OpaquePointer?

    init(file: URL) {
        queue.sync {
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                  nil) == SQLITE_OK else {
                sqlite3_close(db)
                db = nil
                return
            }
            execute("PRAGMA journal_mode = WAL")
            execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS history USING fts5(
                    id UNINDEXED, path UNINDEXED, name, engine UNINDEXED, pages UNINDEXED,
                    recognized_at UNINDEXED, text, tokenize = 'trigram')
                """)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// Records a document's current text, replacing what was kept for it.
    /// A correction keeps the date the document was read; a new reading
    /// takes today's.
    func record(id: UUID, path: String, name: String, engine: OCREngine?, pages: Int,
                isNewReading: Bool, text: String) {
        queue.async { [self] in
            let previous = rows("SELECT recognized_at FROM history WHERE id = ?", [id.uuidString]) {
                sqlite3_column_double($0, 0)
            }.first
            let recognizedAt = isNewReading ? Date() : previous.map(Date.init(timeIntervalSince1970:)) ?? Date()
            execute("DELETE FROM history WHERE id = ?", [id.uuidString])
            execute("INSERT INTO history (id, path, name, engine, pages, recognized_at, text) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [id.uuidString, path, name, engine?.rawValue, pages, recognizedAt.timeIntervalSince1970, text])
        }
    }

    /// The ids among `ids` that have a row.
    func recorded(among ids: [UUID]) -> Set<UUID> {
        queue.sync {
            let all = rows("SELECT id FROM history", []) { UUID(uuidString: column($0, 0)) }
            return Set(all.compactMap { $0 }).intersection(ids)
        }
    }

    func remove(_ ids: [UUID]) {
        queue.async { [self] in
            for id in ids { execute("DELETE FROM history WHERE id = ?", [id.uuidString]) }
        }
    }

    /// Removes every row but those for `kept`.
    func removeAll(keeping kept: Set<UUID>) -> [UUID] {
        queue.sync {
            let all = rows("SELECT id FROM history", []) { UUID(uuidString: column($0, 0)) }.compactMap { $0 }
            let dropped = all.filter { !kept.contains($0) }
            for id in dropped { execute("DELETE FROM history WHERE id = ?", [id.uuidString]) }
            return dropped
        }
    }

    /// The documents matching `query` in their name or text, newest first;
    /// every document when the query is empty.
    func search(_ query: String, limit: Int = 500) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let (open, close) = Self.snippetMarks
        let columns = "id, path, name, engine, pages, recognized_at"
        return queue.sync {
            if query.isEmpty {
                return rows("SELECT \(columns), substr(text, 1, 200) FROM history ORDER BY recognized_at DESC LIMIT ?",
                            [limit], entry)
            }
            if query.count >= 3 {
                // A phrase: the words in this order, not each anywhere.
                let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                return rows("""
                    SELECT \(columns), snippet(history, 6, ?, ?, '…', 24) FROM history
                    WHERE history MATCH ? ORDER BY recognized_at DESC LIMIT ?
                    """, [open, close, phrase, limit], entry)
            }
            let pattern = "%" + query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            return rows("""
                SELECT \(columns), text FROM history
                WHERE name LIKE ? ESCAPE '\\' OR text LIKE ? ESCAPE '\\' ORDER BY recognized_at DESC LIMIT ?
                """, [pattern, pattern, limit]) { statement in
                var found = entry(statement)
                found.snippet = Self.snippet(of: found.snippet, around: query)
                return found
            }
        }
    }

    /// The whole text kept for a document.
    func text(for id: UUID) -> String? {
        queue.sync {
            rows("SELECT text FROM history WHERE id = ?", [id.uuidString]) { column($0, 0) }.first
        }
    }

    // MARK: - SQLite

    private func entry(_ statement: OpaquePointer) -> Entry {
        Entry(id: UUID(uuidString: column(statement, 0)) ?? UUID(),
              path: column(statement, 1),
              name: column(statement, 2),
              engine: OCREngine(rawValue: column(statement, 3)),
              pages: Int(sqlite3_column_int64(statement, 4)),
              recognizedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
              snippet: column(statement, 6))
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    /// SQLite copies bound text when told the buffer is transient.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ arguments: [Any?]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Int:    sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            default:                  sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func execute(_ sql: String, _ arguments: [Any?] = []) {
        guard let statement = prepare(sql, arguments) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func rows<T>(_ sql: String, _ arguments: [Any?], _ read: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(read(statement)) }
        return result
    }

    /// About eighty characters around the first occurrence of `needle`, the
    /// occurrence marked the way FTS5's `snippet` marks it.
    static func snippet(of text: String, around needle: String) -> String {
        guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(120))
        }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        let (open, close) = snippetMarks
        let before = String(text[start..<range.lowerBound])
        let after = String(text[range.upperBound..<end])
        return (start > text.startIndex ? "…" : "") + before + open + String(text[range]) + close
            + after + (end < text.endIndex ? "…" : "")
    }
}
