import XCTest
@testable import CavernSeer

final class ScanExportTests: XCTestCase {
    private func fixture() throws -> SavedScanModel {
        let bundled = Bundle(for: type(of: self)).url(
            forResource: "green_v2", withExtension: "cavernseerscan"
        )
        return try SavedScanModel(url: XCTUnwrap(bundled))
    }

    func testOBJPreservesMeshAndValidGlobalIndexes() throws {
        let model = try fixture()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".obj")
        defer { try? FileManager.default.removeItem(at: path) }
        try ObjSerializer.writeMesh(scan: model.scan, to: path)
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        let vertices = lines.filter { $0.hasPrefix("v ") }
        let faces = lines.filter { $0.hasPrefix("f ") }
        XCTAssertEqual(vertices.count, model.scan.meshAnchors.map { $0.vertices.count }.reduce(0, +))
        XCTAssertEqual(faces.count, model.scan.meshAnchors.map { $0.faces.count }.reduce(0, +))
        for face in faces {
            let indices = face.split(separator: " ").dropFirst().compactMap { Int($0) }
            XCTAssertEqual(indices.count, 3)
            XCTAssertTrue(indices.allSatisfy { (1...vertices.count).contains($0) })
        }
        XCTAssertGreaterThan(faces.count, 0)
        XCTAssertTrue(faces.dropFirst(GreenV2.mesh0Faces).allSatisfy { face in
            face.split(separator: " ").dropFirst().allSatisfy { (Int($0) ?? 0) > GreenV2.mesh0Vertices }
        })
    }

    func testBackupProducesZIPAndLeavesOriginalUnchanged() async throws {
        let model = try fixture()
        let checksum = try ObjSerializer.sha256(model.url)
        let url = try await ObjSerializer.prepare(.backup, model: model)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let payload = try Data(contentsOf: url)
        XCTAssertEqual(Array(payload.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        for filename in [url.deletingPathExtension().lastPathComponent + ".cavernseerscan", "mesh.obj", "metadata.json", "SHA256SUMS"] {
            XCTAssertNotNil(payload.range(of: Data(filename.utf8)), filename)
        }
        XCTAssertEqual(try ObjSerializer.sha256(model.url), checksum)
    }

    func testExportsFollowLatestDiskRevisionRatherThanDisplayedModel() async throws {
        let fixture = try fixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("recovery.cavernseerscan")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture.url, to: source)
        let stale = try SavedScanModel(url: source)
        let original = stale.scan
        XCTAssertGreaterThan(original.meshAnchors.count, 1)
        let latest = ScanFile(name: "Latest", timestamp: original.timestamp,
            center: original.center, extent: original.extent,
            meshAnchors: Array(original.meshAnchors.prefix(1)),
            startSnapshot: nil, endSnapshot: nil, stations: [], lines: [], location: nil)
        let currentBytes = try NSKeyedArchiver.archivedData(withRootObject: latest, requiringSecureCoding: true)
        try currentBytes.write(to: source, options: .atomic)

        let exportedOBJ = try await ObjSerializer.prepare(.mesh, model: stale)
        defer { try? FileManager.default.removeItem(at: exportedOBJ.deletingLastPathComponent()) }
        let lines = try String(contentsOf: exportedOBJ, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("f ") }.count, latest.meshAnchors[0].faces.count)

        let exportedNative = try await ObjSerializer.prepare(.native, model: stale)
        defer { try? FileManager.default.removeItem(at: exportedNative.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: exportedNative), currentBytes)
        XCTAssertEqual(try SavedScanModel(url: exportedNative).scan.name, "Latest")
        XCTAssertEqual(try Data(contentsOf: source), currentBytes)
    }

    func testSHA256MatchesKnownVector() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: path, options: .atomic)
        defer { try? FileManager.default.removeItem(at: path) }
        XCTAssertEqual(try ObjSerializer.sha256(path),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

extension ScanExportTests {
    func testRecoveryRotatesDestinationWithoutDiscardingEarlierCoverage() throws {
        var policy = ScannerModel.CheckpointPolicy()
        let initial = UUID()
        let fresh = UUID()
        let retained = UUID()
        let removed = UUID()
        let now = Date(timeIntervalSince1970: 200)
        policy.didWrite(
            revision: 9, anchors: [retained, removed], date: now, generation: initial
        )

        let rotated = try XCTUnwrap(policy.nextVersion(
            revision: 10, anchors: [retained], now: now, urgent: true,
            outstanding: nil, initialGeneration: initial, nextGeneration: { fresh }
        ))
        XCTAssertEqual(rotated.generation, fresh)
        XCTAssertEqual(policy.anchorIDs, [retained, removed])

        let next = try XCTUnwrap(policy.nextVersion(
            revision: 11, anchors: [retained], now: now, urgent: true,
            outstanding: rotated, initialGeneration: initial
        ))
        XCTAssertEqual(next.generation, rotated.generation)
        XCTAssertEqual(next.revision, 11)
        XCTAssertNil(policy.nextVersion(
            revision: 11, anchors: [retained], now: now, urgent: true,
            outstanding: next, initialGeneration: initial
        ))
    }

    func testRecoveryDoesNotReplaceInFlightGenerationWithReducedCoverage() throws {
        let policy = ScannerModel.CheckpointPolicy()
        let initial = UUID()
        let fresh = UUID()
        let a = UUID()
        let b = UUID()
        let now = Date(timeIntervalSince1970: 200)
        let inFlight = try XCTUnwrap(policy.nextVersion(
            revision: 1, anchors: [a, b], now: now, urgent: false,
            outstanding: nil, initialGeneration: initial
        ))
        let urgent = try XCTUnwrap(policy.nextVersion(
            revision: 2, anchors: [b], now: now, urgent: true,
            outstanding: inFlight, initialGeneration: initial, nextGeneration: { fresh }
        ))
        XCTAssertEqual(inFlight.generation, initial)
        XCTAssertEqual(urgent.generation, fresh)
        XCTAssertNil(policy.nextVersion(
            revision: 3, anchors: [], now: now, urgent: true,
            outstanding: urgent, initialGeneration: initial
        ))
    }
}
