import Foundation
import AppKit

extension OCRViewModel {

    // MARK: - History

    /// Writes a history row for every finished file that has none — results
    /// read before the history existed, or whose row was lost.
    func recordMissingHistory() {
        let finished = items.filter(\.isExportable)
        let store = self.store
        Task.detached(priority: .utility) {
            let recorded = store.history.recorded(among: finished.map(\.id))
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
        let url = URL(fileURLWithPath: entry.path)
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
        let info = Bundle.main.infoDictionary ?? [:]
        let system = DiagnosticReport.currentSystem
        let files = items.filter { ids?.contains($0.id) ?? true }.map { item in
            DiagnosticReport.FileSummary(
                name: item.fileName,
                fileExtension: item.url.pathExtension,
                bytes: (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init),
                pages: max(item.pages.count, item.pageCount),
                status: item.status,
                engine: item.engine,
                error: item.errorMessage,
                pageFailures: item.pages.flatMap(\.notes).compactMap { note in
                    guard case .pageFailed = note.reason else { return nil }
                    return note.message
                })
        }
        return DiagnosticReport(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            system: system.version, machine: system.machine, memoryGB: system.memoryGB,
            settings: settingsSnapshot,
            installedModels: DiagnosticReport.installedModels(in: PPModelStore.userModelsDirectory),
            files: files,
            crashLog: includingCrashLog ? crashLogFromLastSession.flatMap { LaunchSentinel.excerpt(of: $0) } : nil)
    }

    /// Puts a report on the given files on the clipboard, file names left out.
    func copyDiagnostics(for ids: Set<UUID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport(for: ids, includingCrashLog: false)
            .text(includingFileNames: false), forType: .string)
    }
}
