//
//  ScannerControlModel.swift
//  CavernSeer
//
//  Created by Samuel Grush on 1/16/21.
//  Copyright © 2021 Samuel K. Grush. All rights reserved.
//

import Foundation

class ScannerControlModel : ObservableObject {

    /** The active scanner model. Only accessible while scanning is enabled. */
    @Published
    public private(set) var model: ScannerModel?

    /** Controls if the `ActiveARViewContainer` will render. */
    @Published
    public private(set) var renderingARView = false

    /** Controls if the `PassiveCameraViewContainer` will render. */
    @Published
    public private(set) var renderingPassiveView = true

    /** Indicates that the UI should show us as being in scan-mode */
    @Published
    public private(set) var scanEnabled = false

    @Published
    public private(set) var isSaving = false

    /** Indicates that the torch (onboard-light) is engaged. */
    @Published
    public private(set) var torchEnabled = false

    /** Indicates that the ARView debug should render. */
    @Published
    public private(set) var debugEnabled = false

    /** Indicates that the scene-understanding mesh should render. */
    @Published
    public private(set) var meshEnabled = false

    /** The user-facing message string. */
    @Published
    public private(set) var message = ""

    @Published
    private(set) var checkpointStatus = ""

    func updateCheckpointStatus(_ status: String) {
        guard checkpointStatus != status else { return }
        checkpointStatus = status
    }

    /** If we even have access to the camera. `nil` if not yet checked. */
    public private(set) var cameraEnabled: Bool?

    /**
     * Stop the passive camera, construct a `ScannerModel` and start the active AR camera.
     */
    func startScan() {
        guard cameraEnabled == true else {
            message = "Enable camera access in Settings to start a scan."
            return
        }
        guard model == nil, !renderingARView else { return }

        self.message = ""
        self.checkpointStatus = "Waiting for first recovery copy…"

        self.renderingPassiveView = false

        self.model = ScannerModel(control: self)

        self.renderingARView = true
        self.scanEnabled = true

        /// now we wait for `model.onViewAppear` which will start the scan
    }

    /**
     * Simply stops rendering the ARView, triggering the `ActiveARViewContainer` to
     * disappear, subsequently calling `scanDisappearing`.
     *
     * Does  not save the scan.
     */
    func cancelScan() {
        if self.renderingARView {
            self.renderingARView = false
        }
        if self.scanEnabled {
            self.scanEnabled = false
        }
    }

    /**
     * Handler for when the active scan view is being dismantled.
     *
     * Calls the model's `onViewDisappear`, stops rendering the scan,
     * and enables the passive camera.
     */
    func scanDisappearing() {
        self.model?.onViewDisappear()

        self.cancelScan() /// should've been called already but just make sure

        self.model = nil
        self.isSaving = false
        self.torchEnabled = false

        self.renderingPassiveView = true
    }

    /**
     * Call `saveScan` on the model, updating `message` as appropriate,
     * and cancel scan (returning to passive) when done.
     */
    func saveScan(scanStore: ScanStore) {
        guard !isSaving, let model = self.model else { return }
        isSaving = true

        model.saveScan(
            scanStore: scanStore,
            message: { [weak self, weak model] msg in
                guard let self = self, let model = model, self.model === model else { return }
                self.message = msg
            },
            done: { [weak self, weak model] saved in
                guard let self = self, let model = model, self.model === model else { return }
                self.isSaving = false
                if saved { self.cancelScan() }
            }
        )
    }

    func toggleTorch(_ enable: Bool) {
        self.torchEnabled = enable
    }

    func toggleDebug(_ enable: Bool) {
        self.debugEnabled = enable
    }

    func toggleMesh(_ enable: Bool) {
        self.meshEnabled = enable
    }

    func updateCameraAccess(hasAccess: Bool) {
        self.cameraEnabled = hasAccess
    }
}
