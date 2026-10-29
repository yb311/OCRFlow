import SwiftUI
import UniformTypeIdentifiers

/// Gathers what a bug report needs and hands it to the user to send. Nothing
/// leaves the Mac from here on its own: the report is copied, saved, or
/// pasted into an issue by the user.
struct ReportProblemView: View {
    static let windowID = "report-problem"

    @Environment(OCRViewModel.self) private var vm
    @State private var includeFileNames = false
    @State private var includeCrashLog = true
    @State private var isSaving = false
    @State private var saveError: String?

    private var report: String {
        vm.diagnosticReport(includingCrashLog: includeCrashLog && vm.crashLogFromLastSession != nil)
            .text(includingFileNames: includeFileNames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe what happened in the issue, and paste this report below it. It lists your Mac, your settings, the downloaded models and which files failed — never what the files say.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Include file names", isOn: $includeFileNames)
            if vm.crashLogFromLastSession != nil {
                Toggle("Include the crash log from the last unexpected quit", isOn: $includeCrashLog)
            }

            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Report")

            HStack {
                Button("Save…") { isSaving = true }
                Spacer()
                Button("Copy", action: copy)
                Button("Copy and Open GitHub Issue") {
                    copy()
                    NSWorkspace.shared.open(DiagnosticReport.issuesURL)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .fileExporter(isPresented: $isSaving, item: report, contentTypes: [.utf8PlainText],
                      defaultFilename: "OCRFlow Report.txt") { result in
            if case let .failure(error) = result { saveError = error.localizedDescription }
        }
        .alert("The report couldn't be saved", isPresented: Binding(get: { saveError != nil },
                                                                  set: { if !$0 { saveError = nil } })) {
        } message: {
            Text(saveError ?? "")
        }
        // Offered once: whatever the user does here, the next launch does not
        // ask about the same crash again.
        .onDisappear { vm.crashLogFromLastSession = nil }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
