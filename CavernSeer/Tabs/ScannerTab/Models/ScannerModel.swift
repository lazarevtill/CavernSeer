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
    private var activeCheckpoint: RecoveryWrite?
    private var pendingCheckpoint: RecoveryWrite?
    private var activeRetryLease: CaptureWriteLease?
    private var previousIdleTimerDisabled: Bool?
    private var trackingStatus = ""
    private weak var scannerControl: ScannerControlModel?
    private var finalSaveRequested = false
    private var trackingEnded = false

    struct CheckpointPolicy {
        struct Version: Equatable {
            let generation: UUID
            let revision: Int
            let anchors: Set<UUID>
        }

        static let interval: TimeInterval = 25
        private(set) var lastDate: Date?
        private(set) var anchorIDs: Set<UUID> = []
        private(set) var revision: Int?
        private var committedGeneration: UUID?

        /// The newest issued revision, including a pending write, determines the
        /// destination. A reduced anchor set must never replace a broader file.
        func nextVersion(
            revision: Int, anchors: Set<UUID>, now: Date, urgent: Bool,
            outstanding: Version?, initialGeneration: UUID, nextGeneration: () -> UUID = { UUID() }
        ) -> Version? {
            let precedingRevision = outstanding?.revision ?? self.revision
            guard !anchors.isEmpty, precedingRevision.map({ revision > $0 }) ?? true,
                  urgent || (lastDate.map { now.timeIntervalSince($0) >= Self.interval } ?? true)
            else { return nil }
            let coverage = outstanding?.anchors ?? anchorIDs
            let destination = coverage.isSubset(of: anchors)
                ? (outstanding?.generation ?? committedGeneration ?? initialGeneration)
                : nextGeneration()
            return Version(generation: destination, revision: revision, anchors: anchors)
        }

        /// A write that uses the original destination must retain its coverage.
        func shouldWrite(revision: Int, anchors: Set<UUID>, now: Date, urgent: Bool) -> Bool {
            !anchors.isEmpty && revision != self.revision && anchorIDs.isSubset(of: anchors)
                && (urgent || (lastDate.map { now.timeIntervalSince($0) >= Self.interval } ?? true))
        }

        mutating func didWrite(revision: Int, anchors: Set<UUID>, date: Date, generation: UUID? = nil) {
            self.lastDate = date
            self.anchorIDs = anchors
            self.revision = revision
            self.committedGeneration = generation
        }
    }

    private struct RecoveryWrite {
        let file: ScanFile
        let version: CheckpointPolicy.Version
        let lease: CaptureWriteLease
        var isRetry = false
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
        self.scannerControl = control

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
        #if !targetEnvironment(simulator)
        if previousIdleTimerDisabled == nil {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        #endif
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
        checkpoint(urgent: true)
        if let previous = previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previous
            previousIdleTimerDisabled = nil
        }
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

    private func reportRecovery(_ status: String) {
        guard let control = scannerControl,
              control.model == nil || control.model === self else { return }
        control.updateCheckpointStatus(status)
    }

    /// Keep one writer and at most one pending snapshot. Urgent callers freeze
    /// bytes before dismantling AR; repeated callbacks replace only the pending
    /// candidate (never a committed file).
    private func checkpoint(urgent: Bool = false) {
        #if !targetEnvironment(simulator)
        guard !finalSaveRequested, urgent || activeCheckpoint == nil, let scanStore = scanStore,
              let arView = arView, let surveyLines = surveyLines else { return }
        if urgent, pendingCheckpoint == nil, let active = activeCheckpoint,
           active.version.revision == meshRevision {
            // The in-flight file already contains these bytes. Keep one
            // conditional retry through teardown instead of writing twice.
            if !active.isRetry, activeRetryLease == nil { activeRetryLease = CaptureWriteLease() }
            return
        }
        let anchors = savedAnchors.snapshot
        let baseline = pendingCheckpoint?.version ?? activeCheckpoint?.version
        guard let version = checkpointPolicy.nextVersion(
            revision: meshRevision, anchors: Set(anchors.map(\.identifier)), now: Date(),
            urgent: urgent, outstanding: baseline, initialGeneration: captureID
        ) else { return }

        let lease = CaptureWriteLease()
        let name = ScanFile.makeDefaultBaseName(with: captureDate, as: ScanFile.dateFormatter)
        guard let file = ScanFile.captured(
            meshAnchors: anchors, startSnap: startSnapshot,
            endSnap: urgent ? SnapshotAnchor(capturing: arView.session, suffix: "end") : nil,
            date: captureDate, stations: surveyStations,
            lines: surveyLines.drawables.compactMap { $0 as? SurveyLineEntity },
            name: "Recovery • " + name + " [" + String(version.generation.uuidString.prefix(8)) + "]"
        ) else { lease.finish(); return }

        let write = RecoveryWrite(file: file, version: version, lease: lease)
        if activeCheckpoint != nil {
            pendingCheckpoint?.lease.finish()
            pendingCheckpoint = write
        } else {
            writeCheckpoint(write, to: scanStore)
        }
        #endif
    }

    private func writeCheckpoint(_ write: RecoveryWrite, to scanStore: ScanStore) {
        activeCheckpoint = write
        let version = write.version
        // Keep the model alive until the pending checkpoint drains, including
        // when switching away has already dismantled the view.
        writeQueue.async { [self] in
            let result = Result {
                try scanStore.saveRecoveryCheckpoint(
                    file: write.file, baseName: "recovery_" + version.generation.uuidString
                )
            }
            DispatchQueue.main.async { [self] in
                activeCheckpoint = nil
                let retryLease = activeRetryLease
                activeRetryLease = nil
                write.lease.finish()
                switch result {
                case .success:
                    let now = Date()
                    checkpointPolicy.didWrite(
                        revision: version.revision, anchors: version.anchors,
                        date: now, generation: version.generation
                    )
                    if !finalSaveRequested {
                        let savedAt = now.formatted(date: .omitted, time: .standard)
                        reportRecovery("Recovery copy saved at \(savedAt).")
                    }
                    if arView == nil { scanStore.update() }
                case .failure:
                    if let retryLease, pendingCheckpoint == nil {
                        writeCheckpoint(RecoveryWrite(
                            file: write.file, version: write.version, lease: retryLease, isRetry: true
                        ), to: scanStore)
                        return
                    }
                    if !finalSaveRequested {
                        reportRecovery("Recovery write failed. Previous recovery copies are unchanged.")
                    }
                }
                retryLease?.finish()
                if let next = pendingCheckpoint {
                    pendingCheckpoint = nil
                    writeCheckpoint(next, to: scanStore)
                }
            }
        }
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
                // The normal final write can fail after UI teardown. Reuse
                // the exact assembled mesh; do not depend on a surviving AR
                // view or let this fallback overwrite another recovery file.
                let fallbackID = UUID()
                let recovery = ScanFile(
                    name: "Recovery • " + scanFile.name + " [" + String(fallbackID.uuidString.prefix(8)) + "]",
                    timestamp: scanFile.timestamp, center: scanFile.center, extent: scanFile.extent,
                    meshAnchors: scanFile.meshAnchors, startSnapshot: scanFile.startSnapshot,
                    endSnapshot: scanFile.endSnapshot, stations: scanFile.stations,
                    lines: scanFile.lines, location: scanFile.location
                )
                let fallbackSucceeded = (try? scanStore.saveRecoveryCheckpoint(
                    file: recovery, baseName: "recovery_" + fallbackID.uuidString
                )) != nil
                DispatchQueue.main.async { [weak self] in
                    lease.finish()
                    self?.finalSaveRequested = false
                    self?.resumeScan()
                    if fallbackSucceeded {
                        self?.reportRecovery("Recovery copy saved. Try saving the full scan again.")
                        scanStore.update()
                    } else {
                        self?.checkpoint(urgent: true)
                    }
                    let hint = fallbackSucceeded
                        ? "A recovery copy was saved."
                        : "Try saving again before leaving the scanner."
                    message("Couldn't save the full scan: \(description). \(hint)")
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
        reportTracking("Capture interrupted. Save this segment and start a new scan.")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Don't mix new geometry after a loss of the original coordinate frame.
        if trackingEnded { session.pause() }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        trackingEnded = true
        checkpoint(urgent: true)
        reportTracking("Tracking stopped: \(error.localizedDescription). Save this segment before starting again.")
    }

    private func reportTracking(_ status: String) {
        guard trackingStatus != status else { return }
        trackingStatus = status
        guard let control = scannerControl, control.model === self else { return }
        control.updateTrackingStatus(status)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard !trackingEnded, !finalSaveRequested else { return }
        switch camera.trackingState {
        case .normal:
            reportTracking("")
        case .notAvailable:
            reportTracking("Tracking unavailable. Hold still and check lighting before moving.")
        case .limited(let reason):
            switch reason {
            case .initializing:
                reportTracking("Starting tracking…")
            case .excessiveMotion:
                reportTracking("Tracking limited: move more slowly.")
            case .insufficientFeatures:
                reportTracking("Tracking limited: add light or aim at a textured surface.")
            case .relocalizing:
                reportTracking("Tracking limited: hold still and check familiar surroundings.")
            @unknown default:
                reportTracking("Tracking limited. Move slowly and check lighting.")
            }
        }
    }

    private func setupScanConfig() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        configuration.environmentTexturing = .none
        // Vertically aligned and measured in meters; horizontal coordinates
        // are local, not magnetic north (unreliable near metal and underground).
        configuration.worldAlignment = .gravity
        scanConfiguration = configuration
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
