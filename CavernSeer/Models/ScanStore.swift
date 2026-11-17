//
//  ScanStore.swift
//  CavernSeer
//
//  Created by Samuel Grush on 6/27/20.
//  Copyright © 2021 Samuel K. Grush. All rights reserved.
//

import Foundation
import Combine

final class ScanStore : StoreProtocol {

    private var cancelBag = Set<AnyCancellable>()

    typealias FileType = ScanFile
    typealias ModelType = SavedScanModel
    typealias CacheType = ScanCacheFile

    let settings: SettingsStore

    let directoryName: String = "scans"
    let filePrefix: String = FileType.filePrefix
    let fileExtension: String = FileType.fileExtension
    var dataDirectory: URL!
    var cacheDirectory: URL!

    var modelDataInMemory: [SavedScanModel] = []

    var cacheComparator: CacheComparator { self.settings.sortComparator }

    @Published
    var caches = [ScanCacheFile]()

    @Published
    var selection = Set<String>()

    @Published
    var visibleScan: String?

    internal var fileManager = FileManager.default
    internal var dateFormatter = ISO8601DateFormatter()

    init(settings: SettingsStore) {
        self.settings = settings
        (self.dataDirectory, self.cacheDirectory) = getOrCreateDirectories()

        self.settings.$sortComparator.sink { comparator in
            self.sortCaches(comparator)
        }.store(in: &cancelBag)
    }

    /**
     * Try to set the visible scan in the list.
     *
     * - Parameters:
     *   - visible: the URL of the scan to set as the visible option.
     *   - updateFirst: if we should update the store before setting visible, e.g. if `visible` is
     *      not currently loaded.
     *   - onError: only necessary if `updateFirst` is true. Callback in case `update` fails.
     */
    func setVisible(
        visible: URL,
        updateFirst: Bool = false,
        onError: ((Error)->())? = nil
    ) {
        let nextVisibleScanId =
            visible.deletingPathExtension().lastPathComponent

        /// try clearing the current selection and wait for the view to handle that
        self.visibleScan = nil
        DispatchQueue.main.async {
            /// if we're updating, wait for the callback, otherwise just set the `visibleScan`
            if updateFirst {
                self.update() {
                    err in
                    if err == nil {
                        /// if the update was successful, again asynchronously set the `visibleScan`
                        DispatchQueue.main.async {
                            self.visibleScan = nextVisibleScanId
                        }
                    } else {
                        onError?(err!)
                    }
                }
            } else {
                self.visibleScan = nextVisibleScanId
            }
        }
    }

    func getSelectionModels() -> [SavedScanModel] {
        do {
            return try self.selection
                .compactMap {
                    id in
                    self.caches.first { $0.id == id }?.realFileURL
                }
                .map {
                    try self.getModel(url: $0)
                }
        } catch {
            fatalError(
                "Failed to get selected models: \(error.localizedDescription)"
            )
        }
    }

    /// Trash is under Documents/scans so a move is on the same filesystem and
    /// the files survive cache eviction and app restarts. There is no purge.
    struct TrashedScan: Identifiable {
        let archiveURL: URL
        var id: URL { archiveURL }
        var name: String { archiveURL.deletingPathExtension().lastPathComponent }
    }

    private var trashDirectory: URL {
        dataDirectory.appendingPathComponent(".trash", isDirectory: true)
    }

    private func isRegularArchive(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return url.pathExtension == fileExtension && values.isRegularFile == true && values.isSymbolicLink != true
    }

    /// Move the selected ID only. Preview and in-memory state are disposable;
    /// the original scan is not removed until the move succeeds.
    @discardableResult
    func trashScan(id: String) throws -> TrashedScan {
        guard !id.isEmpty, id != ".", id != "..",
              !id.contains("/"), !id.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let source = baseNameToURL(base: id)
        guard try isRegularArchive(source) else { throw CocoaError(.fileReadUnknown) }

        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try checkTrashDirectory()
        let directory = trashDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)

        if let cache = caches.first(where: { $0.id == id }) {
            try? fileManager.removeItem(at: cache.getCacheURL(cacheDir: cacheDirectory))
        }
        caches.removeAll { $0.id == id }
        modelDataInMemory.removeAll { $0.id == id }
        selection.remove(id)
        if visibleScan == id { visibleScan = nil }
        return TrashedScan(archiveURL: destination)
    }

    /// A batch can partially succeed. Surface every failure and never try
    /// deleting a different item merely because the backing list changed.
    func trashScans(ids: Set<String>) -> [String] {
        ids.sorted().compactMap { id in
            do {
                try trashScan(id: id)
                return nil
            } catch {
                return "\(id): \(error.localizedDescription)"
            }
        }
    }

    func trashAllScans() throws -> [String] {
        let ids = try getStoreDirectoryURLs().map { $0.deletingPathExtension().lastPathComponent }
        return trashScans(ids: Set(ids))
    }

    private func checkTrashDirectory() throws {
        let values = try trashDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    func trashedScans() throws -> [TrashedScan] {
        guard fileManager.fileExists(atPath: trashDirectory.path) else { return [] }
        try checkTrashDirectory()
        let directories = try fileManager.contentsOfDirectory(
            at: trashDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var result: [TrashedScan] = []
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let files = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for url in files where try isRegularArchive(url) {
                result.append(TrashedScan(archiveURL: url))
            }
        }
        return result.sorted { ($0.name, $0.id.path) < ($1.name, $1.id.path) }
    }

    @discardableResult
    func restoreScan(_ item: TrashedScan) throws -> URL {
        try checkTrashDirectory()
        let source = item.archiveURL
        let directory = source.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL.path == trashDirectory.standardizedFileURL.path,
              UUID(uuidString: directory.lastPathComponent) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              try isRegularArchive(source) else {
            throw CocoaError(.fileReadNoPermission)
        }

        // The hard link publishes the exact original bytes without overwriting a
        // scan that was imported under the same name since this one was trashed.
        var destination = baseNameToURL(base: item.name)
        do {
            try fileManager.linkItem(at: source, to: destination)
        } catch {
            guard fileManager.fileExists(atPath: destination.path) else { throw error }
            destination = baseNameToURL(base: "restored-\(UUID().uuidString.lowercased())")
            try fileManager.linkItem(at: source, to: destination)
        }
        // If this unlink fails, keep the visible restored copy and surface the
        // error; both links are safe, and neither should be removed on retry.
        try fileManager.removeItem(at: source)
        if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? fileManager.removeItem(at: directory)
        }
        return destination
    }

    /// Rebuild disposable previews without first hiding every scan row.
    func rebuildScanPreviews(completion: @escaping (Error?) -> Void) {
        do {
            if fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.removeItem(at: cacheDirectory)
            }
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            update(rebuildPreviews: true, completion: completion)
        } catch {
            completion(error)
        }
    }

    /// Replace only the rolling recovery file for this capture, never a finished scan.
    func saveRecoveryCheckpoint(file: ScanFile, baseName: String) throws -> URL {
        let prefix = "recovery_"
        guard baseName.hasPrefix(prefix),
              UUID(uuidString: String(baseName.dropFirst(prefix.count))) != nil
        else { throw CocoaError(.fileWriteInvalidFileName) }
        return try saveFile(file: file, baseName: baseName, replaceExisting: true)
    }

    func copySaveFile(scanFile: ScanFile, name: String, withLocation: Bool) throws -> URL {
        let newScan = ScanFile(
            name: name,
            timestamp: scanFile.timestamp,
            center: scanFile.center,
            extent: scanFile.extent,
            meshAnchors: scanFile.meshAnchors,
            startSnapshot: scanFile.startSnapshot,
            endSnapshot: scanFile.endSnapshot,
            stations: scanFile.stations,
            lines: scanFile.lines,
            location: withLocation ? scanFile.location : nil
        )

        let newUrl = try self.saveFile(file: newScan)

        return newUrl
    }

    func makeErrorCacheInstance(_ url: URL, error: Error) -> ScanCacheFile {
        return ScanCacheFile(
            realFileURL: url,
            timestamp: Date.distantFuture,
            displayName: "Error! \(url.deletingPathExtension().lastPathComponent)",
            img: nil,
            error: error
        )
    }
}


#if DEBUG

let dummySavedScans: [SavedScanModel] = [
    .init(id: "hat"),
    .init(id: "bat"),
    .init(id: "tat"),
]

let dummyScanCaches: [ScanCacheFile] = [
    .init(id: "hat"),
    .init(id: "bat"),
    .init(id: "tat"),
]

#endif
