//
//  ElevationProjectedMiniWorldRender.swift
//  CavernSeer
//
//  Created by Samuel Grush on 11/7/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import SwiftUI /// View
import SceneKit /// SCN*

protocol SCNRenderObserver : AnyObject {
    func renderObserver(renderer: SCNSceneRenderer)
}

struct ElevationProjectedMiniWorldRender: View {

    @EnvironmentObject
    var imageSharer: ShareSheetUtility

    var scan: ScanFile
    var settings: SettingsStore

    var barSubview: AnyView? = nil

    var depthOfField: Double? = nil

    var selection: SurveyStation?

    var observer: SCNRenderObserver?

    var showUI: Bool = true

    @State
    private var scaleBarModel = ScaleBarModel()

    /**
     * The rotation of the perspective, in degrees in the local capture frame.
     *
     * Doing manual rotation rather than leaving it up to a value-binding seems to provide
     * more consistently, especially since we want to clamp the rotation to `[0, 360)`.
     */
    @State
    private var rotation: Int = 0

    /**
     * Communicate to the controller to step forward / backward by this many meters
     */
    @State
    private var fly: Int = 0

    @StateObject
    private var snapshotModel = SnapshotExportModel()
    @StateObject
    private var renderModel = GeneralRenderModel()

    var body: some View {
        VStack {
            ZStack {
                ElevationProjectedMiniWorldRenderController(
                    rotation: $rotation,
                    depthOfField: depthOfField,
                    fly: $fly,
                    renderModel: renderModel,
                    snapshotModel: snapshotModel,
                    selection: selection,
                    observer: observer,
                    scaleBarModel: scaleBarModel,
                    showUI: showUI
                )
            }

            if self.showUI {
                HStack {
                    Spacer()

                    HStack {
                        RotationControls(rotation: $rotation)
                    }

                    Spacer()

                    HStack {
                        Button(action: { fly += 1 }) {
                            Image(systemName: "arrow.up.square")
                        }
                        Text("depth")
                        Button(action: { fly -= 1 }) {
                            Image(systemName: "arrow.down.square")
                        }
                    }

                    Spacer()

                    barSubview

                    Spacer()
                }.padding(.bottom, 8)
            }
        }
        .snapshotMenus(for: _snapshotModel)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                snapshotModel.promptButton(scan: scan, sharer: imageSharer)
                renderModel.doubleSidedButton()
            }
        }
        .onAppear(perform: self.appeared)
        .onDisappear(perform: self.disappeared)
    }

    private func appeared() {
        self.renderModel.updateScanAndSettings(scan: scan, settings: settings)
    }
    private func disappeared() {
        self.renderModel.dismantle()
    }
}

private struct ElevationProjectedMiniWorldRenderController: BaseProjectedMiniWorldRenderController {

    private static let DefaultDepthOfField: Double = 1000

    let showUI: Bool

    var depthOfField: Double?
    @Binding
    var rotation: Int
    @Binding
    var fly: Int
    var selectedStation: SurveyStation?
    let scaleBarModel: ScaleBarModel
    let snapshotModel: SnapshotExportModel
    let renderModel: GeneralRenderModel
    var observer: SCNRenderObserver?

    init(
        rotation: Binding<Int>,
        depthOfField: Double?,
        fly: Binding<Int>,
        renderModel: GeneralRenderModel,
        snapshotModel: SnapshotExportModel,
        selection: SurveyStation?,
        observer: SCNRenderObserver?,
        scaleBarModel: ScaleBarModel,
        showUI: Bool
    ) {
        self.depthOfField = depthOfField
        self._rotation = rotation
        self._fly = fly
        self.renderModel = renderModel
        self.snapshotModel = snapshotModel
        self.selectedStation = selection
        self.observer = observer
        self.scaleBarModel = scaleBarModel
        self.showUI = showUI
    }

    func viewUpdater(uiView: SCNView) {
        if let pov = uiView.pointOfView {
            let rotation = CGFloat(self.rotation)
            let angleRads = CGFloat.pi * rotation / 180

            let move = SCNAction.rotateTo(
                x: 0,
                y: -angleRads,
                z: 0,
                duration: 0.5,
                usesShortestUnitArc: true
            )
            pov.runAction(move)

            let flyDist = CGFloat(self.fly)
            if flyDist != 0 {
                let by = SCNVector3(
                    flyDist * sin(angleRads),
                    0,
                    -flyDist * cos(angleRads)
                )
                let flyMove = SCNAction.move(by: by, duration: 0.5)
                pov.runAction(flyMove)

                DispatchQueue.main.async {
                    self.fly = 0
                }
            }
            
            pov.camera?.zFar = depthOfField ?? Self.DefaultDepthOfField
            pov.camera?.fieldOfView = uiView.frame.size.width
        }

        self.snapshotModel.viewUpdaterHandler(
            scnView: uiView,
            overlay: self.scaleBarModel.scene
        )
    }

    func makeaCamera() -> SCNNode {
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1
        camera.projectionDirection = .horizontal
        camera.zNear = 0.1
        camera.zFar = depthOfField ?? Self.DefaultDepthOfField

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 0)

        return cameraNode
    }

    func postSceneAttachment(sceneView: SCNView) {
        sceneView.allowsCameraControl = true
        sceneView.defaultCameraController.interactionMode = .pan
    }
}
