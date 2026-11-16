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
}
