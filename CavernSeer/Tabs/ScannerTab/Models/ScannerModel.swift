//
//  ScannerModel.swift
//  CavernSeer
//
//  Created by Samuel Grush on 6/28/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import Foundation
import RealityKit /// ARView, SceneEvents
import ARKit /// other AR*, UIView, UIGestureRecognizer, NSLayoutConstraint
import Combine /// Cancellable

final class ScannerModel:
    UIGestureRecognizer, ARSessionDelegate, ObservableObject
{

    static let supportsScan =
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    static let supportsTorch = isTorchSupported()

    let clearingOptions: ARSession.RunOptions = [
        .resetSceneReconstruction,
        .removeExistingAnchors,
        .resetTracking,
        .stopTrackedRaycasts,
    ]

    #if !targetEnvironment(simulator)
    let showMeshOptions: ARView.DebugOptions = [
        .showSceneUnderstanding,
        .showWorldOrigin,
        .showAnchorGeometry,
        .showAnchorOrigins,
    ]
    #else
    let showMeshOptions: ARView.DebugOptions = []
    #endif

    /// the layer containing the AR render of the scan; owned by the `ScannerContainerView`
    weak var arView: ARView?
    /// the layer that can draw on top of the arView (e.g. for line drawing)
    weak var drawView: UIView?

    /// snapshot at the beginning of a scan
    var startSnapshot: SnapshotAnchor?
    /// the current state of survey scans
    var surveyStations: [SurveyStationEntity] = []
    /// state manager for survey lines, currently the only Drawables in the scene
    var surveyLines: DrawableContainer?

    var savedAnchors = ARMeshAnchorSet()

    var scanConfiguration: ARWorldTrackingConfiguration?

    private weak var scanStore: ScanStore?
    private let captureID = UUID()
    private let captureDate = Date()
    private let writeQueue = DispatchQueue(label: "CavernSeer.capture-write", qos: .utility)
    private var checkpointTimer: Timer?
    private var lifecycleSubscription: AnyCancellable?
    private var checkpointPolicy = CheckpointPolicy()
    private var meshRevision = 0
    private var checkpointInFlight = false
    private var finalSaveRequested = false
    private var trackingEnded = false
    private var onCheckpointStatus: ((String) -> Void)?

    struct CheckpointPolicy {
        static let interval: TimeInterval = 25
        private(set) var lastDate: Date?
        private(set) var anchorIDs: Set<UUID> = []
        private(set) var revision: Int?

        func shouldWrite(revision: Int, anchors: Set<UUID>, now: Date, urgent: Bool) -> Bool {
            guard !anchors.isEmpty, revision != self.revision, anchorIDs.isSubset(of: anchors) else {
                return false
            }
            return urgent || (lastDate.map { now.timeIntervalSince($0) >= Self.interval } ?? true)
        }

        mutating func didWrite(revision: Int, anchors: Set<UUID>, date: Date) {
            self.lastDate = date
            self.anchorIDs = anchors
            self.revision = revision
        }
    }

    /// A short OS background lease for an already assembled snapshot, not a
    /// promise that iOS will allow an in-progress write to finish.
    private final class CaptureWriteLease {
        private var id = UIBackgroundTaskIdentifier.invalid

        init() {
            id = UIApplication.shared.beginBackgroundTask(withName: "Save CavernSeer capture") { [weak self] in
                self?.finish()
            }
        }

        func finish() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    private var tapRecognizer: UITapGestureRecognizer?
    private var cancelBag = Set<AnyCancellable>()

    init(control: ScannerControlModel) {

        super.init(target: nil, action: nil)
        self.onCheckpointStatus = { [weak control] status in
            control?.updateCheckpointStatus(status)
        }

        control.$meshEnabled.sink {
            [weak self] (mesh) in self?.showMesh(mesh)
        }
        .store(in: &cancelBag)

        control.$debugEnabled.sink {
            [weak self] (dbg) in self?.showDebug(dbg)
        }
        .store(in: &cancelBag)

        control.$torchEnabled
            .dropFirst() /// ignore first so we don't default-on the torch
            .sink { (on) in Self.toggleTorch(on: on) }
            .store(in: &cancelBag)
    }

    func onViewAppear(arView: ARView, scanStore: ScanStore) {
        self.scanStore = scanStore
        let surveyLines = DrawableContainer()
        let drawView = DrawOverlay(frame: arView.frame, toDraw: surveyLines)

        self.arView = arView
        self.drawView = drawView
        self.surveyLines = surveyLines
        self.savedAnchors.clear()

        setupARView(arView: arView)
        setupDrawView(drawView: drawView, arView: arView)
        arView.scene.subscribe(
            to: SceneEvents.Update.self
        ) {
            [weak self] in self?.updateScene(on: $0)
        }
        .store(in: &cancelBag)

        setupScanConfig()

        self.startScan()

        #if !targetEnvironment(simulator)
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.checkpoint() }
        checkpointTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        lifecycleSubscription = NotificationCenter.default
            .publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.checkpoint(urgent: true) }
        #endif
    }

    func onViewDisappear() {
        checkpoint(urgent: true, refreshList: true)
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        lifecycleSubscription?.cancel()
        lifecycleSubscription = nil
        if Self.supportsTorch {
            Self.toggleTorch(on: false)
        }
        NSLayoutConstraint.deactivate(self.getConstraints())

        self.stopScan()

        self.cleanupGestures()

        self.drawView?.removeFromSuperview()

        #if !targetEnvironment(simulator)
        self.arView?.session.delegate = nil
        #endif
        self.arView?.scene.anchors.removeAll()
        self.arView = nil
        self.drawView = nil

        self.scanConfiguration = nil

        self.savedAnchors.clear()
        self.startSnapshot = nil
        self.surveyStations = []
        self.surveyLines = nil
    }

    private func getConstraints() -> [NSLayoutConstraint] {
        guard
            let arView = self.arView,
            let drawView = self.drawView
        else { return [] }

        return [
            drawView.topAnchor.constraint(equalTo: arView.topAnchor),
            drawView.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            drawView.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            drawView.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
        ]
    }


    private func showDebug(_ show: Bool) {
        if show {
            arView?.debugOptions.insert(.showStatistics)
        } else {
            arView?.debugOptions.remove(.showStatistics)
        }
    }

    private func showMesh(_ show: Bool) {
        if show {
            arView?.debugOptions.formUnion(showMeshOptions)
        } else {
            arView?.debugOptions.subtract(showMeshOptions)
        }
    }

    /// Rolling, independently reopenable native backup per capture. Never
    /// replace it with a snapshot that has lost previously committed anchors.
    private func checkpoint(urgent: Bool = false, refreshList: Bool = false) {
        #if !targetEnvironment(simulator)
        guard !finalSaveRequested, !checkpointInFlight, let scanStore = scanStore,
              let arView = arView, let surveyLines = surveyLines else { return }
        let anchors = savedAnchors.snapshot
        let ids = Set(anchors.map(\.identifier))
        let revision = meshRevision
        let now = Date()
        guard checkpointPolicy.shouldWrite(revision: revision, anchors: ids, now: now, urgent: urgent) else {
            if !checkpointPolicy.anchorIDs.isSubset(of: ids) {
                onCheckpointStatus?("Tracking changed. The earlier recovery copy was kept.")
            }
            return
        }

        let lease = CaptureWriteLease()
        let name = ScanFile.makeDefaultBaseName(with: captureDate, as: ScanFile.dateFormatter)
        guard let file = ScanFile.captured(
            meshAnchors: anchors, startSnap: startSnapshot,
            endSnap: urgent ? SnapshotAnchor(capturing: arView.session, suffix: "end") : nil,
            date: captureDate, stations: surveyStations,
            lines: surveyLines.drawables.compactMap { $0 as? SurveyLineEntity },
            name: "Recovery • " + name + " [" + String(captureID.uuidString.prefix(8)) + "]"
        ) else { lease.finish(); return }
        checkpointInFlight = true
        let baseName = "recovery_" + captureID.uuidString
        writeQueue.async { [weak self] in
            let result = Result { try scanStore.saveRecoveryCheckpoint(file: file, baseName: baseName) }
            DispatchQueue.main.async { [weak self] in
                defer { lease.finish() }
                self?.checkpointInFlight = false
                switch result {
                case .success:
                    self?.checkpointPolicy.didWrite(revision: revision, anchors: ids, date: Date())
                    let savedAt = Date().formatted(date: .omitted, time: .standard)
                    if self?.trackingEnded == true {
                        self?.onCheckpointStatus?("Tracking ended. Recovery copy saved at \(savedAt).")
                    } else {
                        self?.onCheckpointStatus?("Recovery copy saved at \(savedAt).")
                    }
                    if refreshList || self?.arView == nil { scanStore.update() }
                case .failure:
                    self?.onCheckpointStatus?("Recovery write failed. Previous recovery copies are unchanged.")
                }
            }
        }
        #endif
    }

    /// Snapshot geometry on the session delegate queue, then write off the UI thread.
    /// Keep the live mesh until a persistent save succeeds so errors are retryable.
    func saveScan(
        scanStore: ScanStore,
        message: @escaping (_: String) -> Void,
        done: @escaping (_: Bool) -> Void
    ) {
        #if !targetEnvironment(simulator)
        guard let arView = self.arView, let surveyLines = self.surveyLines else {
            message("The scanner is not ready yet.")
            done(false)
            return
        }

        let anchors = savedAnchors.snapshot
        guard !anchors.isEmpty else {
            message("No mesh captured yet. Move slowly along a well-lit surface and try again.")
            done(false)
            return
        }

        message("Saving…")
        finalSaveRequested = true
        let lease = CaptureWriteLease()
        let endSnapshot = SnapshotAnchor(capturing: arView.session, suffix: "end")
        pause()

        let lines = surveyLines.drawables.compactMap { $0 as? SurveyLineEntity }
        guard let scanFile = ScanFile.captured(
            meshAnchors: anchors,
            startSnap: startSnapshot,
            endSnap: endSnapshot,
            date: captureDate,
            stations: surveyStations,
            lines: lines
        ) else {
            finalSaveRequested = false
            lease.finish()
            resumeScan()
            message("No usable mesh captured. Continue scanning and try again.")
            done(false)
            return
        }

        let selfCaptureID = captureID.uuidString
        writeQueue.async { [weak self] in
            do {
                _ = try scanStore.saveFile(file: scanFile, baseName: scanFile.name + "_" + selfCaptureID)
                DispatchQueue.main.async {
                    lease.finish()
                    message("Scan saved.")
                    scanStore.update { _ in done(true) }
                }
            } catch {
                let description = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    lease.finish()
                    self?.finalSaveRequested = false
                    self?.resumeScan()
                    self?.checkpoint(urgent: true)
                    message("Couldn't save: \(description). Your scan is still open; try again.")
                    done(false)
                }
            }
        }
        #else
        message("LiDAR capture is unavailable in the simulator.")
        done(false)
        #endif
    }

    private func pause() {
        #if !targetEnvironment(simulator)
        arView?.session.pause()
        #endif
    }

    private func resumeScan() {
        #if !targetEnvironment(simulator)
        guard !trackingEnded, let arView = self.arView, let configuration = scanConfiguration else { return }
        arView.session.run(configuration)
        #endif
    }

    /// Start a new scan with `scanConfiguration`
    private func startScan() {
        guard ScannerModel.supportsScan else { return }
        guard
            let arView = self.arView,
            let scanConfiguration = self.scanConfiguration
        else { return }

        #if !targetEnvironment(simulator)
        arView.environment.sceneUnderstanding.options = [
            .occlusion
        ]
        arView.session.delegateQueue = .main
        arView.session.delegate = self
        arView.session.run(
            scanConfiguration,
            options: self.clearingOptions
        )
        #endif

        setupGestures(arView: arView)
    }

    /// transfer to passive-mode, clearing the current state
    func stopScan() {
        guard
            let arView = self.arView,
            let drawView = self.drawView,
            let surveyLines = self.surveyLines
        else { return }

        self.pause()

        arView.scene.anchors.removeAll()
        surveyStations.removeAll()
        surveyLines.drawables.removeAll()
        drawView.setNeedsDisplay()
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !trackingEnded, !meshes.isEmpty else { return }
        if startSnapshot == nil {
            startSnapshot = SnapshotAnchor(capturing: session, suffix: "start")
        }
        savedAnchors.update(meshes)
        meshRevision += 1
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !trackingEnded, !meshes.isEmpty else { return }
        savedAnchors.update(meshes)
        meshRevision += 1
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !trackingEnded, !meshes.isEmpty else { return }
        savedAnchors.remove(meshes)
        meshRevision += 1
    }

    func sessionWasInterrupted(_ session: ARSession) {
        trackingEnded = true
        checkpoint(urgent: true)
        onCheckpointStatus?("Capture interrupted. Save this segment and start a new scan.")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Don't mix new geometry after a loss of the original coordinate frame.
        if trackingEnded { session.pause() }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        trackingEnded = true
        checkpoint(urgent: true)
        onCheckpointStatus?("Tracking stopped. Save this segment before starting again.")
    }

    private func setupScanConfig() {
        scanConfiguration = ARWorldTrackingConfiguration()
        scanConfiguration!.sceneReconstruction = .mesh
        scanConfiguration!.environmentTexturing = .none
        scanConfiguration!.worldAlignment = .gravityAndHeading
    }

    private func setupARView(arView: ARView) {
        #if !targetEnvironment(simulator)
        arView.automaticallyConfigureSession = false
        arView.renderOptions = [
            .disablePersonOcclusion,
            .disableDepthOfField,
            .disableHDR,
            .disableMotionBlur,
        ]
        #endif
    }

    private func setupDrawView(drawView: DrawOverlay, arView: ARView) {
        drawView.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(drawView)

        drawView.backgroundColor = UIColor.clear

        NSLayoutConstraint.activate(self.getConstraints())
    }



    private func updateScene(on event: SceneEvents.Update) {
        guard
            let arView = self.arView,
            let drawView = self.drawView,
            let surveyLines = self.surveyLines,
            !surveyLines.drawables.isEmpty
        else { return }

        print("updating scene...")

        surveyLines.drawables.forEach {
            line in line.prepareToDraw(arView: arView)
        }
        drawView.setNeedsDisplay()
    }

    private static func toggleTorch(on: Bool) {
        guard
            supportsTorch,
            let device = AVCaptureDevice.default(for: .video)
        else { return }

        do {
            guard device.isTorchActive != on else { return }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
        } catch {
            // The torch may become temporarily unavailable under thermal load or
            // during camera interruption. Never crash and discard the capture.
            debugPrint("Torch unavailable:", error.localizedDescription)
        }
    }

    private static func isTorchSupported() -> Bool {
        guard let device = AVCaptureDevice.default(for: .video)
        else { return false }

        return device.hasTorch && device.isTorchModeSupported(.on)
    }
}


/// +gestures
extension ScannerModel {
    func setupGestures(arView: ARView) {
        let tapRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTap(_:))
        )
        arView.addGestureRecognizer(tapRecognizer)
        self.tapRecognizer = tapRecognizer
    }

    func cleanupGestures() {
        if
            let arView = self.arView,
            let tapRecog = self.tapRecognizer
        {
            arView.removeGestureRecognizer(tapRecog)
        }
        self.tapRecognizer = nil
    }

    @objc
    func handleTap(_ sender: UITapGestureRecognizer) {
        guard !trackingEnded, !finalSaveRequested, let arView = self.arView else { return }

        let tapLoc = sender.location(in: arView)

        let hitResult: [CollisionCastHit] = arView.hitTest(tapLoc)
        if let hitFirst = hitResult.first {
            tappedOnEntity(hitFirst: hitFirst)
            return
        } else {
            tappedOnNonentity(tapLoc: tapLoc)
        }


    }

    private func tappedOnEntity(hitFirst: CollisionCastHit) {
        let entity = hitFirst.entity
        if let stationEntity = entity as? SurveyStationEntity {
            stationEntity.highlight(true)
        }
    }

    private func tappedOnNonentity(tapLoc: CGPoint) {
        #if !targetEnvironment(simulator)
        guard
            let arView = self.arView,
            let surveyLines = self.surveyLines,
            let raycast = arView.raycast(
                from: tapLoc,
                allowing: .estimatedPlane,
                alignment: .any
            ).first
        else {
            return ///  no surface detected
        }

        let lastEntity = self.surveyStations.last

        let result = SurveyStationEntity(worldTransform: raycast.worldTransform)
        self.surveyStations.append(result)
        meshRevision += 1
        arView.scene.addAnchor(result)
        arView.installGestures(for: result)

        if lastEntity != nil {
            let line = lastEntity!.lineTo(result)
            surveyLines.drawables.append(line)
            line.updateProjections(arView: arView)
        }
        #endif
    }
}
