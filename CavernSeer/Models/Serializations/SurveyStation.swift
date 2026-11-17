//
//  SurveyStation.swift
//  CavernSeer
//
//  Created by Samuel Grush on 7/4/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import Foundation
import ARKit /// float4x4, UIColor, SCN*

final class SurveyStation: NSObject, NSSecureCoding {
    typealias Identifier = UUID
    static var supportsSecureCoding: Bool { true }

    let name: String
    let identifier: Identifier
    let transform: float4x4

    init?(entity: SurveyStationEntity, name: String? = nil) {
        guard
            let anchor = entity.anchor,
            let identifier = anchor.anchorIdentifier
        else {
            return nil
        }

        self.name = name ?? identifier.uuidString
        self.identifier = identifier
        self.transform = entity.transform.matrix
    }

    init(rename other: SurveyStation, to: String) {

        self.name = to
        self.identifier = other.identifier
        self.transform = other.transform
    }

    required init?(coder decoder: NSCoder) {
        guard let identifier = decoder.decodeObject(of: NSUUID.self, forKey: PropertyKeys.identifier) else { return nil }
        self.identifier = identifier as UUID
        self.transform =
            decoder.decode_simd_float4x4(prefix: PropertyKeys.transform)
        if decoder.containsValue(forKey: PropertyKeys.name) {
            guard let name = decoder.decodeObject(of: NSString.self, forKey: PropertyKeys.name) else { return nil }
            self.name = name as String
        } else {
            self.name = self.identifier.uuidString
        }
    }

    func encode(with coder: NSCoder) {
        coder.encode(identifier as NSUUID, forKey: PropertyKeys.identifier)
        coder.encode(transform, forPrefix: PropertyKeys.transform)
        if name != identifier.uuidString {
            coder.encode(name as NSString, forKey: PropertyKeys.name)
        }
    }
}

extension SurveyStation {
    func toSCNNode() -> SCNNode {
        let geo = SCNSphere(radius: 0.1)
        let material = SCNMaterial()
        material.isDoubleSided = false
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.gray
        geo.materials = [material]

        let node = SCNNode(geometry: geo)
        node.name = self.name
        node.simdTransform = self.transform
        return node
    }
}

fileprivate struct PropertyKeys {
    static let name = "name"
    static let identifier = "identifier"
    static let transform = "transform"
}
