import Foundation
import AppKit
import UniformTypeIdentifiers

enum DropHelper {
    /// Extracts file URLs from NSItemProviders (Finder drag-and-drop).
    /// Uses loadDataRepresentation instead of loadItem to avoid NSSecureCoding/XPC warnings.
    @discardableResult
    static func handle(providers: [NSItemProvider], vm: OCRViewModel) -> Bool {
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            // loadDataRepresentation returns raw bytes without going through NSCoding,
            // avoiding the "NSObject allowed class" XPC warning from loadItem.
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data,
                      let fileURL = URL(dataRepresentation: data, relativeTo: nil) else { return }

                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)

                lock.lock()
                if isDir.boolValue {
                    let children = (try? FileManager.default.contentsOfDirectory(
                        at: fileURL, includingPropertiesForKeys: nil,
                        options: .skipsHiddenFiles)) ?? []
                    urls.append(contentsOf: children)
                } else {
                    urls.append(fileURL)
                }
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            Task { @MainActor in vm.addImages(urls: urls) }
        }
        return true
    }
}
