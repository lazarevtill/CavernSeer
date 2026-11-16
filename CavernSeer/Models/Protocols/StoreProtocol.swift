//
//  StoreProtocol.swift
//  CavernSeer
//
//  Created by Samuel Grush on 7/22/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import Foundation

/**
 * Abstracts the storage and handling of files and their caches.
 *
 * The definitive file list is defined by the `dataDirectory`, but the cache files in the `cacheDirectory`
 * are the ones kept in memory.
 */
protocol StoreProtocol : ObservableObject {
    associatedtype ModelType: SavedStoredFileProtocol

    typealias FileType = ModelType.FileType
    typealias CacheType = FileType.CacheType
    typealias CacheComparator = CacheSortComparator<CacheType>

    /** basename of directories used for stored files and previews */
    var directoryName: String { get }
    var filePrefix: String { get }
    var fileExtension: String { get }
    var dataDirectory: URL! { get }
    var cacheDirectory: URL! { get }

    var fileManager: FileManager { get }
    var dateFormatter: ISO8601DateFormatter { get }

    var modelDataInMemory: [ModelType] { get set }

    var caches: [CacheType] { get set }

    var cacheComparator: CacheComparator { get }

    func makeErrorCacheInstance(_ url: URL, error: Error) -> CacheType
}


extension StoreProtocol {

    static var MaxInMemoryModels: Int { 2 }

    func sortCaches(_ comparator: CacheComparator? = nil) {
        let cmp = comparator ?? self.cacheComparator
        self.caches.sort(using: cmp)
    }

    /**
     * Try to get a model from a baseName; first try the cache, then try the file
     *  otherwise throws from the `ModelType` constructor.
     */
    func getModel(url: URL) throws -> ModelType {
        if let model = modelDataInMemory.first(where: { $0.url == url }) {
            return model
        }

        let model = try ModelType(url: url)

        let cacheToRemove = modelDataInMemory.count - Self.MaxInMemoryModels + 1
        if cacheToRemove > 0 {
            modelDataInMemory.removeFirst(cacheToRemove)
        }
        modelDataInMemory.append(model)

        return model
    }

    /**
     * Save a file to the store directory.
     *
     * - Parameter file: the `FileType` instance being saved
     * - Parameter baseName: an optional base name to use for the saved file. Otherwise `url.lastPathComponent`.
     */
    func saveFile(file: FileType, baseName: String? = nil, replaceExisting: Bool = false) throws -> URL {
        let base = baseName ?? file.name
        guard !base.isEmpty, base != ".", base != "..",
              !base.contains("/"), !base.contains("\0")
        else { throw CocoaError(.fileWriteInvalidFileName) }

        let data = try NSKeyedArchiver.archivedData(withRootObject: file, requiringSecureCoding: true)
        if replaceExisting {
            // This path is reserved for rolling checkpoints. Replacing the prior
            // archive atomically leaves either the old or the new copy intact.
            let destination = baseNameToURL(base: base)
            try data.write(to: destination, options: .atomic)
            let cache = file.createCacheFile(thisFileURL: destination)
            saveCacheBestEffort(cache, at: cache.getCacheURL(cacheDir: cacheDirectory))
            return destination
        }

        let stagingURL = dataDirectory.appendingPathComponent(".pending-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stagingURL) }
        try data.write(to: stagingURL, options: .atomic)

        // A hard link publishes an already complete file on the same filesystem,
        // and refuses to replace an existing destination even for concurrent saves.
        var destination = baseNameToURL(base: base)
        while true {
            do {
                try fileManager.linkItem(at: stagingURL, to: destination)
                break
            } catch {
                guard fileManager.fileExists(atPath: destination.path) else { throw error }
                if baseName != nil { throw FileSaveError.AlreadyExists }
                destination = baseNameToURL(base: "\(base)-\(UUID().uuidString.lowercased())")
            }
        }

        // A preview is disposable; the write above is authoritative.
        let cache = file.createCacheFile(thisFileURL: destination)
        saveCacheBestEffort(cache, at: cache.getCacheURL(cacheDir: cacheDirectory))
        return destination
    }

    private func saveCacheBestEffort(_ cache: CacheType, at url: URL) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try NSKeyedArchiver.archivedData(withRootObject: cache, requiringSecureCoding: true)
            try data.write(to: url, options: .atomic)
        } catch {
            debugPrint("Could not persist disposable preview:", error.localizedDescription)
        }
    }

    /**
     * Update the `caches` and `modelDataInMemory` based on the files in `dataDirectory`.
     *
     * Work is done async as utility, then data is updated back on main thread.
     * If `completion` is provided, it is called in that main thread.
     */
    func update(completion: ((Error?)->())? = nil) {
        let previousCaches = Dictionary(caches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        DispatchQueue.global(qos: .utility).async {
            do {
                let urls = try self.getStoreDirectoryURLs()
                let newCaches = urls.map { url in
                    let id = url.deletingPathExtension().lastPathComponent
                    do {
                        return try previousCaches[id] ?? self.getCacheFile(realFileURL: url)
                    } catch {
                        return self.makeErrorCacheInstance(url, error: error)
                    }
                }

                DispatchQueue.main.async {
                    let existingURLs = Set(urls)
                    self.modelDataInMemory.removeAll { !existingURLs.contains($0.url) }
                    self.caches = newCaches
                    self.sortCaches()
                    completion?(nil)
                }
            } catch {
                // Don't hide existing entries or crash if the directory cannot be read.
                DispatchQueue.main.async { completion?(error) }
            }
        }
    }

    func deleteFile(id: String) {
        let cacheIndex = caches.firstIndex { $0.id == id }
        let modelIndex = modelDataInMemory.firstIndex { $0.id == id }

        if cacheIndex != nil {
            let cache = caches[cacheIndex!]
            let dataUrl = self.getNormalizedRealUrl(cache: cache)
            let cacheUrl = cache.getCacheURL(cacheDir: cacheDirectory)
            do {
                try fileManager.removeItem(at: cacheUrl)
            } catch {
                debugPrint("Deleting cacheUrl failed but that's okay", cacheUrl)
            }
            do {
                try fileManager.removeItem(at: dataUrl)
            } catch {
                fatalError("Deletion failed: \(error.localizedDescription)")
            }
            caches.remove(at: cacheIndex!)
        } else {
            fatalError("Model not found in modelData")
        }

        if modelIndex != nil {
            modelDataInMemory.remove(at: modelIndex!)
        }
    }

    func importFile(model: ModelType) throws -> URL {
        if caches.contains(where: { $0.id == model.id }) {
            throw FileSaveError.AlreadyExists
        }

        let file = model.getFile()
        return try saveFile(file: file, baseName: model.id)
    }

    func clearCaches() throws {
        try fileManager.removeItem(at: cacheDirectory)
        caches.removeAll()
        modelDataInMemory.removeAll()
        _ = getOrCreateDirectories()
    }

    internal func DANGEROUSLY_deleteAllFiles() throws {
        try fileManager.removeItem(at: dataDirectory)
        try clearCaches()
    }

    internal func getSaveURL(file: FileType, baseName: String? = nil) -> URL {
        let base = baseName ?? file.name

        return baseNameToURL(base: base)
    }

    internal func baseNameToURL(base: String) -> URL {
        return dataDirectory
            .appendingPathComponent(base)
            .appendingPathExtension(fileExtension)
    }

    internal func getNormalizedRealUrl(cache: CacheType) -> URL {
        if cache.realFileURL == nil {
            cache.realFileURL
                = dataDirectory
                    .appendingPathComponent(cache.id)
                    .appendingPathExtension(fileExtension)
        }
        return cache.realFileURL!
    }

    /**
     * Tries to get the cache file associated with a real file.
     * If the cache file doesn't exist but the real file does, generate the cache file and save it too.
     */
    internal func getCacheFile(realFileURL: URL) throws -> CacheType {
        let id = realFileURL.deletingPathExtension().lastPathComponent

        let cacheFileURL =
            cacheDirectory
                .appendingPathComponent(id)
                .appendingPathExtension(CacheType.fileExtension)

        if let data = try? Data(contentsOf: cacheFileURL),
           let cache = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CacheType.self, from: data),
           cache.id == id {
            cache.realFileURL = realFileURL
            return cache
        }

        // A missing, stale, corrupt or unwritable cache must not hide a valid file.
        let model = try ModelType(url: realFileURL)
        let cache = model.getFile().createCacheFile(thisFileURL: realFileURL)
        saveCacheBestEffort(cache, at: cacheFileURL)
        return cache
    }

    /**
     * Create the file and cache directories, and return them as a tuple.
     * Returns `(fileDirectory, cacheDirectory)`
     */
    internal func getOrCreateDirectories() -> (URL, URL) {
        do {
            let fileDirectory = try
                fileManager
                    .url(for: .documentDirectory,
                         in: .userDomainMask,
                         appropriateFor: nil,
                         create: true)
                .appendingPathComponent(directoryName, isDirectory: true)
            let cacheBase = (try? fileManager.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? fileManager.temporaryDirectory
            let cacheDirectory = cacheBase.appendingPathComponent(directoryName, isDirectory: true)

            try fileManager.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

            return (fileDirectory, cacheDirectory)
        } catch {
            fatalError("Could not resolve file dataDirectory URL; " +
                       "\(error.localizedDescription)")
        }
    }

    internal func getStoreDirectoryURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: dataDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == fileExtension }
        .sorted { $0.path < $1.path }
    }
}
