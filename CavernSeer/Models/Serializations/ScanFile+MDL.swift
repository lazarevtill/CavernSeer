// Geometry conversion for scan interchange.
// Copyright © 2020 Samuel K. Grush. All rights reserved.

import ARKit
import Foundation

extension CSMeshSlice {
    /// Stream an ARKit mesh in capture/world coordinates. Export must honor the
    /// recorded stride, byte offset and index width, including for older scans.
    func writeOBJ(vertexBase: Int, emit: (String) throws -> Void) throws {
        let width = faces.bytesPerIndex
        guard vertices.format == .float3, vertices.count > 0,
              vertices.offset >= 0, vertices.offset <= vertices.data.count,
              vertices.stride >= 12, vertices.data.count - vertices.offset >= 12,
              vertices.count - 1 <= (vertices.data.count - vertices.offset - 12) / vertices.stride,
              faces.primitiveType == .triangles, faces.indexCountPerPrimitive == 3,
              (width == 2 || width == 4), faces.count > 0,
              faces.count <= faces.data.count / (3 * width),
              vertexBase <= Int.max - vertices.count
        else { throw ObjSerializationError.InvalidMesh }

        try vertices.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for i in 0..<vertices.count {
                if i.isMultiple(of: 1024) { try Task.checkCancellation() }
                let offset = vertices.offset + i * vertices.stride
                let x = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let y = bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                let z = bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                let p = transform * SIMD4<Float>(x, y, z, 1)
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                    throw ObjSerializationError.InvalidMesh
                }
                try emit("v \(p.x) \(p.y) \(p.z)\n")
            }
        }

        try faces.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func index(_ offset: Int) throws -> Int {
                let value = width == 2
                    ? Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
                    : Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                guard value < vertices.count else { throw ObjSerializationError.InvalidMesh }
                return vertexBase + value + 1
            }
            for i in 0..<faces.count {
                if i.isMultiple(of: 1024) { try Task.checkCancellation() }
                let start = i * width * 3
                let a = try index(start)
                let b = try index(start + width)
                let c = try index(start + width * 2)
                try emit("f \(a) \(b) \(c)\n")
            }
        }
    }
}
