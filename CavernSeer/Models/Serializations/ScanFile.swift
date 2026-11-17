//
//  ScanFile.swift
//  CavernSeer
//
//  Created by Samuel Grush on 6/21/20.
//  Copyright © 2021 Samuel K. Grush. All rights reserved.
//

import Foundation
import ARKit /// simd_float3, ARMeshAnchor, ARWorldMap

final class ScanFile : NSObject, NSSecureCoding, StoredFileProtocol {
    typealias CacheType = ScanCacheFile
    static let filePrefix = "scan"
    static let fileExtension = "cavernseerscan"
    static let supportsSecureCoding: Bool = true
    static let dateFormatter = getDefaultDateFormatter()
    /**
     * # V2 IS STILL EXPERIMENTAL
     *
     * v2 changed:
     *  - `meshAnchors` from `ARMeshAnchor` to `CSMeshSlice`
     *  - `*Snapshot`s from `SnapshotAnchor` to `CSMeshSnapshot`
     */
    static let currentEncodingVersion: Int32 = 2

    /// the version this ScanFile was encoded for. Note that it must still have the current structure.
    let encodingVersion: Int32

    /// Timestamp, including timezone, of the original scan.
    let timestamp: Date
    /// Name for the scan, encoded into the file and distinct from the filename. Initially `scan_\(timestamp)`
    let name: String
    let center: simd_float3
    let extent: simd_float3
    let meshAnchors: [CSMeshSlice]
    let startSnapshot: CSMeshSnapshot?
    let endSnapshot: CSMeshSnapshot?

    let stations: [SurveyStation]
    let lines: [SurveyLine]

    let location: CSLocation?

    let stationPositionDict: [SurveyStation.Identifier: simd_float3]

    /// Build a portable scan directly from captured geometry. Saving a mesh no
    /// longer depends on ARKit being able to produce a relocalizable world map.
    static func captured(
        meshAnchors: [ARMeshAnchor],
        startSnap: SnapshotAnchor?,
        endSnap: SnapshotAnchor?,
        date: Date,
        stations: [SurveyStationEntity],
        lines: [SurveyLineEntity],
        name: String? = nil
    ) -> ScanFile? {
        let meshes = meshAnchors.map { CSMeshSlice(anchor: $0) }
        var bounds = CaptureBounds()
        for mesh in meshes where mesh.faces.count > 0 {
            let vertices = mesh.vertices
            bounds.includeVertices(
                vertices.data, count: vertices.count, offset: vertices.offset,
                stride: vertices.stride, transform: mesh.transform
            )
        }
        guard let box = bounds.box else { return nil }

        let completedStations = stations.compactMap { SurveyStation(entity: $0) }
        let stationIDs = Set(completedStations.map(\.identifier))
        let completedLines = lines.compactMap { SurveyLine(entity: $0) }.filter {
            stationIDs.contains($0.startIdentifier) && stationIDs.contains($0.endIdentifier)
        }
        return ScanFile(
            name: name ?? Self.makeDefaultBaseName(with: date, as: Self.dateFormatter),
            timestamp: date,
            center: box.center,
            extent: box.extent,
            meshAnchors: meshes,
            startSnapshot: startSnap.map { CSMeshSnapshot(snapshot: $0) },
            endSnapshot: endSnap.map { CSMeshSnapshot(snapshot: $0) },
            stations: completedStations,
            lines: completedLines,
            location: nil
        )
    }

    struct CaptureBounds {
        private var low: SIMD3<Float>?
        private var high: SIMD3<Float>?

        mutating func includeVertices(
            _ data: Data, count: Int, offset: Int, stride: Int, transform: simd_float4x4
        ) {
            let size = MemoryLayout<Float>.size
            let xyzSize = 3 * size
            guard count > 0, offset >= 0, offset <= data.count,
                  stride >= xyzSize, data.count - offset >= xyzSize,
                  count - 1 <= (data.count - offset - xyzSize) / stride
            else { return }

            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for i in 0 ..< count {
                    let p = offset + i * stride
                    let x = bytes.loadUnaligned(fromByteOffset: p, as: Float.self)
                    let y = bytes.loadUnaligned(fromByteOffset: p + size, as: Float.self)
                    let z = bytes.loadUnaligned(fromByteOffset: p + 2 * size, as: Float.self)
                    let world = transform * SIMD4<Float>(x, y, z, 1)
                    let vertex = SIMD3<Float>(world.x, world.y, world.z)
                    guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else { continue }
                    low = simd_min(low ?? vertex, vertex)
                    high = simd_max(high ?? vertex, vertex)
                }
            }
        }

        var box: (center: SIMD3<Float>, extent: SIMD3<Float>)? {
            guard let low = low, let high = high else { return nil }
            return ((low + high) * 0.5, high - low)
        }
    }

    required init?(coder: NSCoder) {

        let decoder = Decode(coder: coder)
        self.encodingVersion = decoder.version
        guard self.encodingVersion == 1 || self.encodingVersion == Self.currentEncodingVersion else { return nil }

        do {
            self.timestamp = try decoder.timestamp()
            self.name = try decoder.name(timestamp: self.timestamp)
            self.center = decoder.center()
            self.extent = decoder.extent()
            guard center.x.isFinite, center.y.isFinite, center.z.isFinite,
                  extent.x.isFinite, extent.y.isFinite, extent.z.isFinite,
                  extent.x >= 0, extent.y >= 0, extent.z >= 0
            else { throw DecodeError.castFailure(property: "bounds") }
            self.meshAnchors = try decoder.meshAnchors()
            self.startSnapshot =
                try decoder.snapshot(key: PropertyKeys.startSnapshot)
            self.endSnapshot =
                try decoder.snapshot(key: PropertyKeys.endSnapshot)
            self.stations = try decoder.stations()
            self.lines = try decoder.lines()
            self.location = try decoder.location()
        } catch DecodeError.badVersion {
            debugPrint("Bad version \(decoder.version)")
            return nil
        } catch DecodeError.castFailure(let property) {
            debugPrint("Failed to cast \(property)")
            return nil
        } catch DecodeError.missingMandatory(let property) {
            debugPrint("Missing mandatory key \(property)")
            return nil
        } catch {
            debugPrint("Unknown failure encoding; \(error)")
            return nil
        }

        self.stationPositionDict = Self.generateStationDict(self.stations)
    }


    internal init(
        name: String,
        timestamp: Date,
        center: simd_float3,
        extent: simd_float3,
        meshAnchors: [CSMeshSlice],
        startSnapshot: CSMeshSnapshot?,
        endSnapshot: CSMeshSnapshot?,
        stations: [SurveyStation],
        lines: [SurveyLine],
        location: CSLocation?
    ) {
        self.encodingVersion = ScanFile.currentEncodingVersion
        self.timestamp = timestamp
        self.name = name
        self.center = center
        self.extent = extent
        self.meshAnchors = meshAnchors
        self.startSnapshot = startSnapshot
        self.endSnapshot = endSnapshot
        self.stations = stations
        self.lines = lines
        self.location = location

        self.stationPositionDict = Self.generateStationDict(self.stations)
    }

    func encode(with coder: NSCoder) {
        coder.encode(Self.currentEncodingVersion, forKey: PropertyKeys.version)
        coder.encode(name, forKey: PropertyKeys.name)
        coder.encode(timestamp, forKey: PropertyKeys.timestamp)
        coder.encode(center, forPrefix: PropertyKeys.center)
        coder.encode(extent, forPrefix: PropertyKeys.extent)
        coder.encode(meshAnchors as NSArray, forKey: PropertyKeys.meshAnchors)
        if let startSnapshot { coder.encode(startSnapshot, forKey: PropertyKeys.startSnapshot) }
        if let endSnapshot { coder.encode(endSnapshot, forKey: PropertyKeys.endSnapshot) }

        coder.encode(stations as NSArray, forKey: PropertyKeys.stations)
        coder.encode(lines as NSArray, forKey: PropertyKeys.lines)

        coder.encode(location, forKey: PropertyKeys.location)
    }

    #if DEBUG
    /** DEBUG only constructor */
    init(debugInit: Any?) {
        self.encodingVersion = ScanFile.currentEncodingVersion

        self.timestamp = Date()
        self.name = ScanFile.dateFormatter.string(from: self.timestamp)
        self.center = simd_make_float3(0)
        self.extent = simd_make_float3(0)
        self.meshAnchors = []
        self.startSnapshot = nil
        self.endSnapshot = nil

        self.lines = []
        self.stations = []

        self.location = nil

        self.stationPositionDict = Self.generateStationDict(self.stations)

        super.init()
    }
    #endif

    /**
     * Create a `ScanCacheFile` describing this `ScanFile`.
     * Image is compressed before storing.
     */
    func createCacheFile(thisFileURL: URL) -> ScanCacheFile {
        // compress the image if we can
        var img = startSnapshot?.imageData
        if img != nil {
            let uiImg = UIImage(data: img!)
            // in case UIImage processing or compression fails, fall back to img
            img = uiImg?.jpegData(compressionQuality: 0.2) ?? img
        }
        return ScanCacheFile(
            realFileURL: thisFileURL,
            timestamp: timestamp,
            displayName: name,
            img: img
        )
    }

    func getDistance(line: SurveyLine, lengthPref: LengthPreference) -> String {
        return line.getDistance(
            stationDict: stationPositionDict,
            lengthPref: lengthPref
        )
    }

    private static func generateStationDict(
        _ stations: [SurveyStation]
    ) -> [SurveyStation.Identifier: simd_float3] {
        var dict = [SurveyStation.Identifier: simd_float3]()
        stations.forEach {
            dict[$0.identifier] = $0.transform.toPosition()
        }
        return dict
    }
}

extension ScanFile {
    struct PropertyKeys {
        static let version = "version"
        static let name = "name"
        static let timestamp = "timestamp"
        static let center = "center"
        static let extent = "extent"
        static let meshAnchors = "meshAnchors"
        static let startSnapshot = "startSnapshot"
        static let endSnapshot = "endSnapshot"
        static let stations = "stations"
        static let lines = "lines"
        static let location = "location"
    }


    /**
     * Property decoders for `ScanFile`.
     *
     * Initializer stores the coder and decodes/stores the version for use in other decoders.
     * Decoder methods can throw `DecodeError`s.
     */
    struct Decode {
        let version: Int32
        let decoder: NSCoder

        init(coder: NSCoder) {
            decoder = coder
            version =
                decoder.containsValue(forKey: PropertyKeys.version)
                    ? decoder.decodeInt32(forKey: PropertyKeys.version)
                    : 1
        }

        func name(timestamp: Date) throws -> String {
            if decoder.containsValue(forKey: PropertyKeys.name) {
                if
                    let name = decoder.decodeObject(
                        of: NSString.self,
                        forKey: PropertyKeys.name
                    ) as String?
                {
                    return name
                } else {
                    throw DecodeError.castFailure(property: "name")
                }
            } else {
                let name = ScanFile.makeDefaultBaseName(
                    with: timestamp,
                    as: ScanFile.dateFormatter
                )
                debugPrint("ScanFile \(name) missing name in archive")
                return name
            }
        }

        func timestamp() throws -> Date {
            try throwIfMissing(key: PropertyKeys.timestamp)
            if
                let date = decoder.decodeObject(
                    of: NSDate.self,
                    forKey: PropertyKeys.timestamp
                ) as Date?
            {
                return date
            } else {
                throw DecodeError.castFailure(property: "date")
            }
        }

        func center() -> simd_float3 {
            return decoder.decode_simd_float3(prefix: PropertyKeys.center)
        }

        func extent() -> simd_float3 {
            decoder.decode_simd_float3(prefix: PropertyKeys.extent)
        }

        func meshAnchors() throws -> [CSMeshSlice] {
            try throwIfMissing(key: PropertyKeys.meshAnchors)
            switch version {
                case 1:
                    if let meshes = decoder.decodeObject(
                        of: [NSArray.self, ARMeshAnchor.self],
                        forKey: PropertyKeys.meshAnchors
                    ) as? [ARMeshAnchor] {
                        return meshes.map { CSMeshSlice(anchor: $0) }
                    } else {
                        throw DecodeError.castFailure(property: "meshes")
                    }

                case 2:
                    if let meshes = decoder.decodeObject(
                        of: [NSArray.self, CSMeshSlice.self],
                        forKey: PropertyKeys.meshAnchors
                    ) as? [CSMeshSlice] {
                        return meshes
                    } else {
                        throw DecodeError.castFailure(property: "meshes")
                    }
                default:
                    throw DecodeError.badVersion
            }
        }

        func snapshot(key: String) throws -> CSMeshSnapshot? {
            if decoder.containsValue(forKey: key) {
                let snapshot: CSMeshSnapshot?
                switch version {
                    case 1:
                        snapshot = decoder.decodeObject(
                            of: SnapshotAnchor.self,
                            forKey: key
                        ).map { CSMeshSnapshot(snapshot: $0) }
                    case 2:
                        snapshot = decoder.decodeObject(
                            of: CSMeshSnapshot.self,
                            forKey: key
                        )
                    default:
                        throw DecodeError.badVersion
                }
                // Earlier writers encoded an explicit nil for optional photos.
                // NSKeyedUnarchiver still reports such a key as present.
                return snapshot
            } else {
                return nil
            }
        }

        func stations() throws -> [SurveyStation] {
            if decoder.containsValue(forKey: PropertyKeys.stations) {
                if
                    let stations = decoder.decodeObject(
                        of: [NSArray.self, SurveyStation.self],
                        forKey: PropertyKeys.stations
                    ) as? [SurveyStation]
                {
                    return stations
                } else {
                    throw DecodeError.castFailure(property: "stations")
                }
            } else {
                return []
            }
        }

        func lines() throws -> [SurveyLine] {
            if decoder.containsValue(forKey: PropertyKeys.lines) {
                if
                    let lines = decoder.decodeObject(
                        of: [NSArray.self, SurveyLine.self],
                        forKey: PropertyKeys.lines
                    ) as? [SurveyLine]
                {
                    return lines
                } else {
                    throw DecodeError.castFailure(property: "lines")
                }
            } else {
                return []
            }
        }

        func location() throws -> CSLocation? {
            if decoder.containsValue(forKey: PropertyKeys.location) {
                return decoder.decodeObject(
                    of: CSLocation.self,
                    forKey: PropertyKeys.location
                )
            } else {
                return nil
            }
        }

        private func throwIfMissing(key: String) throws {
            if !decoder.containsValue(forKey: key) {
                throw DecodeError.missingMandatory(property: key)
            }
        }
    }

    enum DecodeError : Error {
        case castFailure(property: String)
        case missingMandatory(property: String)
        case badVersion
    }
}
