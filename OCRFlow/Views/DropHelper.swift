import Foundation
import AppKit
import UniformTypeIdentifiers
import os

enum DropHelper {
    /// Extracts file URLs from NSItemProviders (Finder drag-and-drop).
    /// Uses loadDataRepresentation instead of loadItem to avoid NSSecureCoding/XPC warnings.
    @discardableResult
    static func handle(providers: [NSItemProvider], vm: OCRViewModel) -> Bool {
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        let urls = OSAllocatedUnfairLock(initialState: [URL]())

        for provider in providers {
            group.enter()
            // loadDataRepresentation returns raw bytes without going through NSCoding,
            // avoiding the "NSObject allowed class" XPC warning from loadItem.
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data,
                      let fileURL = URL(dataRepresentation: data, relativeTo: nil) else { return }

                // Folders are handed over as they are: the view model walks
                // them, subfolders included, and remembers each one as the
                // root its files' export paths are relative to.
                urls.withLock { $0.append(fileURL) }
            }
        }

        group.notify(queue: .main) {
            let dropped = urls.withLock { $0 }
            MainActor.assumeIsolated { vm.addImages(urls: dropped) }
        }
        return true
    }
}
