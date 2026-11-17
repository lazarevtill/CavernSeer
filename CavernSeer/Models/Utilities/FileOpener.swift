//
//  FileOpener.swift
//  CavernSeer
//
//  Created by Samuel Grush on 7/26/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import Foundation

enum OpenType: Equatable {
    case scan
    case project
}

final class FileOpener: ObservableObject {
    private let scanStore: ScanStore
    private let projStore: ProjectStore
    private let queue = DispatchQueue(label: "CavernSeer.file-import", qos: .userInitiated)

    @Published var showOpenResults = false
    @Published private(set) var openSuccesses: [URL: OpenType] = [:]
    @Published private(set) var openFailures: [URL: String] = [:]

    init(_ scanStore: ScanStore, _ projectStore: ProjectStore) {
        self.scanStore = scanStore
        self.projStore = projectStore
    }

    /// Call on the main queue (scene / SwiftUI). File coordination and decode
    /// run off the UI thread, and all observable state is published on main.
    func openURLs(urls: [URL]) {
        guard !urls.isEmpty else { return }

        queue.async { [self] in
            var successes: [URL: OpenType] = [:]
            var failures: [URL: String] = [:]
            for url in urls {
                autoreleasepool {
                    do {
                        let (destination, type) = try importURL(url)
                        successes[destination] = type
                    } catch FileOpenError.noFileInArchive {
                        failures[url] = "This file does not contain a supported scan or project."
                    } catch FileOpenError.unknownExtension(let ext) {
                        failures[url] = "Unsupported file type: \(ext). For backup ZIPs, unzip and open the .cavernseerscan file inside."
                    } catch FileSaveError.AlreadyExists {
                        failures[url] = "A file with this name already exists. The saved copy was not changed."
                    } catch {
                        failures[url] = error.localizedDescription
                    }
                }
            }
            let imported = successes
            let rejected = failures
            DispatchQueue.main.async { [self] in
                if !showOpenResults {
                    openSuccesses = [:]
                    openFailures = [:]
                }
                openSuccesses.merge(imported) { _, new in new }
                openFailures.merge(rejected) { _, new in new }
                if imported.values.contains(.scan) { scanStore.update() }
                showOpenResults = true
            }
        }
    }

    private func importURL(_ url: URL) throws -> (URL, OpenType) {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }

        let fileExtension = url.pathExtension.lowercased()
        let type: OpenType
        switch fileExtension {
        case ScanFile.fileExtension: type = .scan
        case ProjectFile.fileExtension: type = .project
        default: throw FileOpenError.unknownExtension(ext: fileExtension)
        }

        var coordinationError: NSError?
        var result: Result<URL, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result {
                switch type {
                case .scan: return try scanStore.importFile(from: source)
                case .project: return try projStore.importFile(from: source)
                }
            }
        }
        if let coordinationError = coordinationError { throw coordinationError }
        guard let result = result else { throw CocoaError(.fileReadUnknown) }
        return (try result.get(), type)
    }
}
