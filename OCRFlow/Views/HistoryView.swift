import SwiftUI

/// Every document read, searchable by what it says, whether or not it is
/// still in the list.
struct HistoryView: View {
    static let windowID = "history"

    @EnvironmentObject private var vm: OCRViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var entries: [HistoryIndex.Entry] = []
    @State private var selection: UUID?
    @State private var selectedText: String?
    @State private var confirmsClear = false

    private var selected: HistoryIndex.Entry? {
        entries.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(entries, selection: $selection) { entry in
                HistoryRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu { actions(for: entry) }
            }
            .overlay { if entries.isEmpty { emptyState } }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .onDeleteCommand { if let selected { forget(selected) } }
        } detail: {
            if let selected {
                detail(selected)
            } else {
                Text("Select a document")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search names and text")
        .toolbar {
            ToolbarItem {
                Button("Clear History…", systemImage: "trash") { confirmsClear = true }
                    .disabled(entries.isEmpty && query.isEmpty)
            }
        }
        .confirmationDialog("Clear the whole history?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) {
                vm.clearHistory()
                selection = nil
                Task { await reload() }
            }
        } message: {
            Text("Results of files no longer in the list are deleted, along with the recognition cache. Files still in the list stay.")
        }
        // Searching as the user types, a moment after they pause.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 200))
            guard !Task.isCancelled else { return }
            await reload()
        }
        // Results landing while the window is open show up in it.
        .onChange(of: vm.completedCount) { Task { await reload() } }
        .task(id: selection) {
            guard let id = selection else { selectedText = nil; return }
            let history = vm.store.history
            selectedText = await Task.detached { history.text(for: id) }.value
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    private func reload() async {
        let history = vm.store.history
        let query = self.query
        entries = await Task.detached { history.search(query) }.value
        if let selection, !entries.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    @ViewBuilder
    private var emptyState: some View {
        if query.isEmpty {
            ContentUnavailableView("No History", systemImage: "clock",
                                   description: Text("Documents appear here once they have been recognized, and stay after they leave the list."))
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func detail(_ entry: HistoryIndex.Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.title3.weight(.semibold))
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.path)
                HStack(spacing: 6) {
                    Text(entry.recognizedAt, format: .dateTime)
                    if let engine = entry.engine { Text(verbatim: "·"); Text(engine.shortLabel) }
                    if entry.pages > 1 { Text(verbatim: "·"); Text("\(entry.pages) pages") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Show in List") {
                        vm.openFromHistory(entry)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Copy Text") { copy(entry) }
                    Button("Show in Finder") { reveal(entry) }
                        .disabled(!FileManager.default.fileExists(atPath: entry.path))
                }
                .padding(.top, 6)
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(selectedText ?? "")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    @ViewBuilder
    private func actions(for entry: HistoryIndex.Entry) -> some View {
        Button("Show in List") {
            vm.openFromHistory(entry)
            dismiss()
        }
        Button("Copy Text") { copy(entry) }
        Button("Show in Finder") { reveal(entry) }
            .disabled(!FileManager.default.fileExists(atPath: entry.path))
        Divider()
        Button("Delete from History", role: .destructive) { forget(entry) }
    }

    private func copy(_ entry: HistoryIndex.Entry) {
        guard let text = vm.store.history.text(for: entry.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func reveal(_ entry: HistoryIndex.Entry) {
        NSWorkspace.shared.selectFile(entry.path, inFileViewerRootedAtPath: "")
    }

    private func forget(_ entry: HistoryIndex.Entry) {
        vm.forgetHistory([entry.id])
        entries.removeAll { $0.id == entry.id }
        if selection == entry.id { selection = nil }
    }
}

private struct HistoryRow: View {
    let entry: HistoryIndex.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.name).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(entry.recognizedAt, format: .dateTime.month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(highlighted(entry.snippet))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The snippet with the match in bold, its marks taken out.
    private func highlighted(_ snippet: String) -> AttributedString {
        let (open, close) = HistoryIndex.snippetMarks
        var result = AttributedString()
        var rest = Substring(snippet.replacingOccurrences(of: "\n", with: " "))
        while let start = rest.range(of: open) {
            result += AttributedString(rest[..<start.lowerBound])
            rest = rest[start.upperBound...]
            let end = rest.range(of: close) ?? rest.endIndex..<rest.endIndex
            var match = AttributedString(rest[..<end.lowerBound])
            match[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] = .stronglyEmphasized
            match[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .primary
            result += match
            rest = rest[end.upperBound...]
        }
        return result + AttributedString(rest)
    }
}
