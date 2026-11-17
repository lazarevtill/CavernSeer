//  ObjSerializer.swift
//  Copyright © 2020 Samuel K. Grush. All rights reserved.

import Foundation
import SwiftUI
import CryptoKit

final class ObjSerializer: ObservableObject {
    static func writeMesh(scan: ScanFile, to destination: URL) throws {
        let slices = scan.meshAnchors.filter { $0.faces.count > 0 }
        guard !slices.isEmpty else { throw ObjSerializationError.EmptyMesh }

        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".partial")
        guard manager.createFile(atPath: staging.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: staging) }

        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        func emit(_ line: String) throws {
            buffer.append(contentsOf: line.utf8)
            if buffer.count >= 256 * 1024 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        try emit("# CavernSeer triangle mesh; meters; ARKit capture coordinates, +Y up\n")
        var base = 0
        for (i, slice) in slices.enumerated() {
            try Task.checkCancellation()
            try emit("g tile_\(i + 1)\n")
            try slice.writeOBJ(vertexBase: base, emit: emit)
            base += slice.vertices.count
        }
        try handle.write(contentsOf: buffer)
        try handle.close()
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: destination)
    }

    enum Output {
        case mesh, native, backup
    }

    /// Returns a complete, temporary sharing artifact. Until the ZIP is ready,
    /// nothing is passed to the share sheet; the original is always untouched.
    nonisolated static func prepare(_ output: Output, model: SavedScanModel) async throws -> URL {
        let manager = FileManager.default
        let identifier = UUID()
        let root = manager.temporaryDirectory.appendingPathComponent("CavernSeer-Export-" + identifier.uuidString, isDirectory: true)
        let stamp = ISO8601DateFormatter.string(
            from: model.scan.timestamp, timeZone: TimeZone(secondsFromGMT: 0)!,
            formatOptions: [.withFullDate, .withTime, .withTimeZone, .withDashSeparatorInDate]
        )
        let name = "CavernSeer-\(stamp)-\(identifier.uuidString.prefix(8))"
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            // The on-disk archive is the source of truth, including for OBJ-only.
            // A displayed recovery preview may represent a prior rolling revision.
            if output == .mesh {
                let mesh = root.appendingPathComponent(name + ".obj")
                let current = try SavedScanModel(url: model.url).scan
                try writeMesh(scan: current, to: mesh)
                return mesh
            }

            if output == .native {
                let native = root.appendingPathComponent(name + ".cavernseerscan")
                try Task.checkCancellation()
                try manager.copyItem(at: model.url, to: native)
                try Task.checkCancellation()
                return native
            }

            let files = root.appendingPathComponent("CavernSeer-Backup", isDirectory: true)
            try manager.createDirectory(at: files, withIntermediateDirectories: false)
            let native = files.appendingPathComponent(name + ".cavernseerscan")
            let mesh = files.appendingPathComponent("mesh.obj")
            try manager.copyItem(at: model.url, to: native)
            // Derive the mesh from the exact bytes being backed up; an in-memory
            // model could represent an earlier revision of the rolling checkpoint.
            let portableScan = try SavedScanModel(url: native).scan
            try writeMesh(scan: portableScan, to: mesh)

            let metadata = Metadata(
                schemaVersion: 1,
                capturedAt: portableScan.timestamp,
                originalFilename: model.url.lastPathComponent,
                nativeArchiveFilename: native.lastPathComponent,
                nativeFormatVersion: portableScan.encodingVersion,
                meshUnits: "meters",
                meshCoordinates: "Local ARKit capture coordinates, +Y up. Not georeferenced.",
                vertexCount: portableScan.meshAnchors.filter { $0.faces.count > 0 }.reduce(0) { $0 + $1.vertices.count },
                triangleCount: portableScan.meshAnchors.reduce(0) { $0 + $1.faces.count }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let metadataURL = files.appendingPathComponent("metadata.json")
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
            var sums = ""
            for file in [native, mesh, metadataURL] {
                sums += "\(try sha256(file))  \(file.lastPathComponent)\n"
            }
            try Data(sums.utf8).write(to: files.appendingPathComponent("SHA256SUMS"), options: .atomic)
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(name + ".zip")
            try zip(directory: files, to: destination)
            try Task.checkCancellation()
            try manager.removeItem(at: files)
            return destination
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func zip(directory: URL, to destination: URL) throws {
        // Foundation snapshots the directory as a ZIP for .forUploading.
        // Its URL is valid only for the duration of the accessor.
        var coordinationError: NSError?
        var copyError: Error?
        var copied = false
        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: .forUploading, error: &coordinationError
        ) { archive in
            do {
                try FileManager.default.copyItem(at: archive, to: destination)
                copied = true
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        guard copied else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04])
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    private struct Metadata: Encodable {
        let schemaVersion: Int
        let capturedAt: Date
        let originalFilename: String
        let nativeArchiveFilename: String
        let nativeFormatVersion: Int32
        let meshUnits: String
        let meshCoordinates: String
        let vertexCount: Int
        let triangleCount: Int
    }
}
