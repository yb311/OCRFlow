import Foundation

/// Notices when the last session ended without quitting.
///
/// A marker is written at launch and removed on a normal quit. Finding it at
/// the next launch means the app crashed or was killed; macOS writes a crash
/// log for the former, and only that case is worth asking the user about —
/// a force-quit is something they did themselves.
struct LaunchSentinel {

    let marker: URL
    let crashLogFolder: URL

    init(directory: URL,
         crashLogFolder: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)) {
        self.marker = directory.appendingPathComponent("running")
        self.crashLogFolder = crashLogFolder
    }

    /// Records this launch, and returns the crash log the previous session
    /// left, if it ended in a crash.
    func begin(processName: String = ProcessInfo.processInfo.processName) -> URL? {
        let previousLaunch = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        try? Data().write(to: marker)
        guard let previousLaunch else { return nil }
        return newestCrashLog(for: processName, since: previousLaunch)
    }

    /// Records a normal quit.
    func end() {
        try? FileManager.default.removeItem(at: marker)
    }

    private func newestCrashLog(for processName: String, since date: Date) -> URL? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: crashLogFolder, includingPropertiesForKeys: Array(keys))) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(processName) && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { file -> (URL, Date)? in
                guard let modified = (try? file.resourceValues(forKeys: keys))?.contentModificationDate,
                      modified >= date else { return nil }
                return (file, modified)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// A crash log ready to send: the home folder replaced by `~`, so the
    /// user's account name does not travel with it, and capped in length.
    /// The exception and the crashed thread come first in the file.
    static func excerpt(of log: URL, limit: Int = 24_000) -> String? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let anonymised = text.replacingOccurrences(of: home, with: "~")
        return anonymised.count > limit ? String(anonymised.prefix(limit)) + "\n…" : anonymised
    }
}
