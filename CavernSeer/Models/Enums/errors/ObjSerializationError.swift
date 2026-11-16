//  ObjSerializationError.swift
//  Copyright © 2020 Samuel K. Grush. All rights reserved.

import Foundation

enum ObjSerializationError: LocalizedError {
    case EmptyMesh
    case InvalidMesh

    var errorDescription: String? {
        switch self {
        case .EmptyMesh: return "This scan does not contain a triangle mesh."
        case .InvalidMesh: return "The scan contains invalid or unsupported mesh data."
        }
    }
}
