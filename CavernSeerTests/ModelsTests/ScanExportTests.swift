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

    func testSHA256MatchesKnownVector() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: path, options: .atomic)
        defer { try? FileManager.default.removeItem(at: path) }
        XCTAssertEqual(try ObjSerializer.sha256(path),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
