//
//  CavernSeerTests.swift
//  CavernSeerTests
//
//  Created by Samuel Grush on 6/27/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import XCTest
import simd
@testable import CavernSeer

class CavernSeerTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

    func testCaptureBoundsUnionTransformedAndPaddedVertices() throws {
        var bounds = ScanFile.CaptureBounds()
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(0, 1, 0, 0)
        transform.columns.1 = SIMD4<Float>(-1, 0, 0, 0)
        transform.columns.3 = SIMD4<Float>(10, 20, 30, 1)

        let padded: [Float] = [-99, 1, 2, 3, 99, 4, 5, 6, 99]
        bounds.includeVertices(
            padded.withUnsafeBytes { Data($0) },
            count: 2, offset: 4, stride: 16, transform: transform
        )
        let other: [Float] = [2, 30, 40]
        bounds.includeVertices(
            other.withUnsafeBytes { Data($0) },
            count: 1, offset: 0, stride: 12, transform: matrix_identity_float4x4
        )

        let box = try XCTUnwrap(bounds.box)
        XCTAssertEqual(box.center, SIMD3<Float>(5, 25.5, 36.5))
        XCTAssertEqual(box.extent, SIMD3<Float>(6, 9, 7))
    }

    func testCaptureBoundsRejectsTruncatedOrNonFiniteVertices() {
        var bounds = ScanFile.CaptureBounds()
        let input: [Float] = [.infinity, 2, 3]
        let data = input.withUnsafeBytes { Data($0) }
        bounds.includeVertices(data, count: 2, offset: 0, stride: 12, transform: matrix_identity_float4x4)
        bounds.includeVertices(data, count: 1, offset: 0, stride: 12, transform: matrix_identity_float4x4)
        bounds.includeVertices(data, count: 1, offset: -1, stride: 12, transform: matrix_identity_float4x4)
        XCTAssertNil(bounds.box)
    }
    func testCheckpointRequiresChangesAndPreservesEarlierCoverage() {
        var policy = ScannerModel.CheckpointPolicy()
        let first = UUID()
        let second = UUID()
        let t = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(policy.shouldWrite(revision: 0, anchors: [], now: t, urgent: true))
        XCTAssertTrue(policy.shouldWrite(revision: 1, anchors: [first], now: t, urgent: false))
        policy.didWrite(revision: 1, anchors: [first], date: t)
        XCTAssertFalse(policy.shouldWrite(revision: 1, anchors: [first], now: t, urgent: true))
        XCTAssertFalse(policy.shouldWrite(revision: 2, anchors: [first, second], now: t, urgent: false))
        XCTAssertTrue(policy.shouldWrite(revision: 2, anchors: [first, second], now: t, urgent: true))
        XCTAssertTrue(policy.shouldWrite(revision: 2, anchors: [first, second], now: t.addingTimeInterval(26), urgent: false))
        XCTAssertFalse(policy.shouldWrite(revision: 3, anchors: [second], now: t, urgent: true))
    }
}

extension CavernSeerTests {
    func testTrashKeepsBytesAndRestoresWithoutReplacingExistingFile() throws {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scans = scratch.appendingPathComponent("scans", isDirectory: true)
        let previews = scratch.appendingPathComponent("previews", isDirectory: true)
        try files.createDirectory(at: scans, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }

        func makeStore() -> ScanStore {
            let store = ScanStore(settings: SettingsStore())
            store.dataDirectory = scans
            store.cacheDirectory = previews
            return store
        }
        let store = makeStore()
        let alpha = store.baseNameToURL(base: "alpha")
        let beta = store.baseNameToURL(base: "beta")
        let alphaBytes = Data("different unused scan".utf8)
        let betaBytes = Data("selected scan's original bytes".utf8)
        try alphaBytes.write(to: alpha)
        try betaBytes.write(to: beta)
        store.caches = [
            ScanCacheFile(realFileURL: alpha, timestamp: Date(), displayName: "Not a match", img: nil),
            ScanCacheFile(realFileURL: beta, timestamp: Date(), displayName: "Filtered target", img: nil)
        ]
        store.selection = ["beta"]
        store.visibleScan = "beta"

        XCTAssertEqual(store.trashScans(ids: ["beta"]), [])
        XCTAssertEqual(try Data(contentsOf: alpha), alphaBytes)
        XCTAssertFalse(files.fileExists(atPath: beta.path))
        XCTAssertEqual(store.caches.map(\.id), ["alpha"])
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertNil(store.visibleScan)
        XCTAssertThrowsError(try store.trashScan(id: "../alpha"))

        let nextLaunch = makeStore()
        let trashed = try XCTUnwrap(nextLaunch.trashedScans().first)
        XCTAssertEqual(trashed.name, "beta")
        XCTAssertEqual(try Data(contentsOf: trashed.archiveURL), betaBytes)
        let laterBytes = Data("new scan uses the same ID".utf8)
        try laterBytes.write(to: beta)
        let restored = try nextLaunch.restoreScan(trashed)
        XCTAssertNotEqual(restored, beta)
        XCTAssertEqual(try Data(contentsOf: beta), laterBytes)
        XCTAssertEqual(try Data(contentsOf: restored), betaBytes)
        XCTAssertTrue(try nextLaunch.trashedScans().isEmpty)
    }

    func testNameSortingUsesBothDisplayNamesAndSettingsUseRawKeys() {
        let a = ScanCacheFile(realFileURL: URL(fileURLWithPath: "/z-file.cavernseerscan"), timestamp: Date(),
                              displayName: "Alpha", img: nil)
        let b = ScanCacheFile(realFileURL: URL(fileURLWithPath: "/a-file.cavernseerscan"), timestamp: Date(),
                              displayName: "Beta", img: nil)
        let comparator = CacheSortComparator<ScanCacheFile>(.name)
        XCTAssertEqual(comparator.compare(a, b), .orderedAscending)
        XCTAssertEqual(comparator.compare(b, a), .orderedDescending)
        XCTAssertEqual(Set(getSettingsDefaultDictionary().keys), Set(SettingsKey.allCases.map(\.rawValue)))
    }
}
