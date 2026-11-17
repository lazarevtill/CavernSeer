//
//  PassiveCameraViewContainer.swift
//  CavernSeer
//
//  Created by Samuel Grush on 1/18/21.
//  Copyright © 2021 Samuel K. Grush. All rights reserved.
//

import SwiftUI
import AVFoundation
import Combine

struct PassiveCameraViewContainer: UIViewRepresentable {
    @ObservedObject var control: ScannerControlModel

    private static let cameraQueue = DispatchQueue(label: "CavernSeer.passive-camera")

    /// Combine delivers the stop request synchronously to the camera queue when
    /// the control removes the preview. Start AR only after that stop has run.
    static func afterPreviewStops(_ action: @escaping () -> Void) {
        cameraQueue.async { DispatchQueue.main.async(execute: action) }
    }

    func makeUIView(context: Context) -> PassiveCameraView {
        PassiveCameraView(control: control)
    }

    func updateUIView(_ uiView: PassiveCameraView, context: Context) {}

    final class PassiveCameraView: UIView {
        private let captureSession = AVCaptureSession()
        private var passiveCamEnabledSub: AnyCancellable?

        init(control: ScannerControlModel) {
            super.init(frame: .zero)
            let session = captureSession
            passiveCamEnabledSub = control.$renderingPassiveView.sink { enabled in
                if !enabled { Self.enqueueStop(session) }
            }
        }

        required init?(coder: NSCoder) { nil }

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            let session = captureSession
            let preview = layer as? AVCaptureVideoPreviewLayer
            if superview == nil {
                Self.enqueueStop(session)
                preview?.session = nil
                return
            }

            preview?.session = session
            preview?.videoGravity = .resizeAspect
            cameraQueue.async {
                if session.inputs.isEmpty {
                    guard let device = AVCaptureDevice.default(for: .video),
                          let input = try? AVCaptureDeviceInput(device: device),
                          session.canAddInput(input) else { return }
                    session.beginConfiguration()
                    session.addInput(input)
                    session.commitConfiguration()
                }
                if !session.isRunning { session.startRunning() }
            }
        }

        private static func enqueueStop(_ session: AVCaptureSession) {
            cameraQueue.async {
                if session.isRunning { session.stopRunning() }
            }
        }
    }
}
