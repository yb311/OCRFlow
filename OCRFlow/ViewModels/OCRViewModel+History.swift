import Foundation
import AppKit

extension OCRViewModel {

    // MARK: - History

    /// Writes a history row for every finished file that has none — results
    /// read before the history existed, or whose row was lost.
    func recordMissingHistory() {
        let finished = items.filter(\.isExportable)
        let store = self.store
        Task {
            let ids = finished.map(\.id)
            let recorded = await BlockingWork.run { store.history.recorded(among: ids) }
            for item in finished where !recorded.contains(item.id) {
                store.recordInHistory(item)
            }
        }
    }

    /// Brings a document from the history into the list: selects it when it
    /// is still there, puts its kept result back when it is not, and failing
    /// both adds the file to be read again.
    func openFromHistory(_ entry: HistoryIndex.Entry) {
        mode = .workspace
        let url = URL(filePath: entry.path)
        if let listed = items.first(where: { $0.id == entry.id }) ?? items.first(where: { $0.url == url }) {
            selectedIDs = [listed.id]
            return
        }
        guard let pages = store.historyPages(for: entry.id) else {
            add([(url, nil)])
            if let added = items.first(where: { $0.url == url }) { selectedIDs = [added.id] }
            return
        }
        store.restoreFromHistory(entry.id)
        var item = ImageItem(url: url, id: entry.id)
        item.status = .completed
        item.engine = entry.engine
        item.pages = pages
        items.append(item)
        rebuildDocument(at: items.count - 1)
        selectedIDs = [entry.id]
        recalcProgress()
        store.saveQueue(items)
        loadThumbnails(for: [entry.id])
    }

    func forgetHistory(_ ids: Set<UUID>) {
        store.forget(Array(ids))
    }

    func clearHistory() {
        store.clearHistory(keeping: Set(items.map(\.id)))
    }

    // MARK: - Diagnostics

    /// A report on the given files — every file when nil — and on the app,
    /// the Mac and the settings they were read with.
    func diagnosticReport(for ids: Set<UUID>? = nil, includingCrashLog: Bool) -> DiagnosticReport {
        Self.buildReport(reportSnapshot(for: ids, includingCrashLog: includingCrashLog))
    }

    /// The same report, gathered off the main thread: it stats every file,
    /// walks the models folder and reads the crash log.
    func diagnosticReport(for ids: Set<UUID>? = nil, includingCrashLog: Bool) async -> DiagnosticReport {
        let snapshot = reportSnapshot(for: ids, includingCrashLog: includingCrashLog)
        return await BlockingWork.run { Self.buildReport(snapshot) }
    }

    /// What the report needs from the view model, taken on the main actor.
    private struct ReportSnapshot: Sendable {
        var info: [String: String]
        var settings: OCRSettings
        var files: [(url: URL, summary: DiagnosticReport.FileSummary)]
        var crashLog: URL?
    }

    private func reportSnapshot(for ids: Set<UUID>?, includingCrashLog: Bool) -> ReportSnapshot {
        let info = Bundle.main.infoDictionary ?? [:]
        let files = items.filter { ids?.contains($0.id) ?? true }.map { item in
            (url: item.url, summary: DiagnosticReport.FileSummary(
                name: item.fileName,
                fileExtension: item.url.pathExtension,
                bytes: nil,
                pages: max(item.pages.count, item.pageCount),
                status: item.status,
                engine: item.engine,
                error: item.errorMessage,
                pageFailures: item.pages.flatMap(\.notes).compactMap { note in
                    guard case .pageFailed = note.reason else { return nil }
                    return note.message
                }))
        }
        return ReportSnapshot(
            info: ["version": info["CFBundleShortVersionString"] as? String ?? "?",
                   "build": info["CFBundleVersion"] as? String ?? "?"],
            settings: settingsSnapshot,
            files: files,
            crashLog: includingCrashLog ? crashLogFromLastSession : nil)
    }

    private nonisolated static func buildReport(_ snapshot: ReportSnapshot) -> DiagnosticReport {
        let system = DiagnosticReport.currentSystem
        let files = snapshot.files.map { file in
            var summary = file.summary
            summary.bytes = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            return summary
        }
        return DiagnosticReport(
            appVersion: snapshot.info["version"] ?? "?",
            build: snapshot.info["build"] ?? "?",
            system: system.version, machine: system.machine, memoryGB: system.memoryGB,
            settings: snapshot.settings,
            installedModels: DiagnosticReport.installedModels(in: PPModelStore.userModelsDirectory),
            files: files,
            crashLog: snapshot.crashLog.flatMap { LaunchSentinel.excerpt(of: $0) })
    }

    /// Puts a report on the given files on the clipboard, file names left out.
    func copyDiagnostics(for ids: Set<UUID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport(for: ids, includingCrashLog: false)
            .text(includingFileNames: false), forType: .string)
    }
}
