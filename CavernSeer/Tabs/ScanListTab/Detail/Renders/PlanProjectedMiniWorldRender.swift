//
//  PlanProjectedMiniWorldRender.swift
//  CavernSeer
//
//  Created by Samuel Grush on 7/11/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import SwiftUI /// View
import SceneKit /// SCN*

struct PlanProjectedMiniWorldRender: View {

    @EnvironmentObject
    var imageSharer: ShareSheetUtility

    var scan: ScanFile
    var settings: SettingsStore

    var selection: SurveyStation? = nil

    var overlays: [SCNDrawSubview]? = nil

    var showUI: Bool = true

    var initialHeight: Int? = nil

    @State
    private var scaleBarModel = ScaleBarModel()

    @State
    private var height: Int = 0

    @StateObject
    private var snapshotModel = SnapshotExportModel()

    @StateObject
    private var renderModel = GeneralRenderModel()

    var body: some View {
        VStack {
            PlanProjectedMiniWorldRenderController(
                height: $height,
                renderModel: renderModel,
                snapshotModel: snapshotModel,
                selection: selection,
                overlays: overlays,
                scaleBarModel: scaleBarModel,
                showUI: self.showUI
            )
            if self.showUI {
                HStack {
                    Stepper(stepperLabel, value: $height)
                        .frame(maxWidth: 150)
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
        .onAppear(perform: self.onAppear)
        .onDisappear(perform: self.onDisappear)
    }

    private func onAppear() {
        if (self.initialHeight != nil) {
            self.height = self.initialHeight!
        }
        self.renderModel.updateScanAndSettings(scan: scan, settings: settings)
    }

    private func onDisappear() {
        self.renderModel.dismantle()
    }

    private var stepperLabel: String {
        var preferred = settings.UnitsLength.fromMetric(Double(height))
        preferred.value = preferred.value.roundedTo(places: 1)

        return "Height: \(preferred.description)"
    }
}

class SCNDrawSubview : UIView {
    func parentMade(view: SCNView) {}
    func parentUpdated(view: SCNView) {}
    func parentRender(renderer: SCNSceneRenderer) {}
    func parentDismantled(view: SCNView) {}
}


private struct PlanProjectedMiniWorldRenderController: BaseProjectedMiniWorldRenderController {

    let showUI: Bool

    var overlays: [SCNDrawSubview]?

    @Binding
    var height: Int
    var selectedStation: SurveyStation?
    let scaleBarModel: ScaleBarModel
    let snapshotModel: SnapshotExportModel
    let renderModel: GeneralRenderModel

    init(
        height: Binding<Int>,
        renderModel: GeneralRenderModel,
        snapshotModel: SnapshotExportModel,
        selection: SurveyStation?,
        overlays: [SCNDrawSubview]?,
        scaleBarModel: ScaleBarModel,
        showUI: Bool
    ) {
        self._height = height
        self.renderModel = renderModel
        self.snapshotModel = snapshotModel
        self.selectedStation = selection
        self.overlays = overlays
        self.scaleBarModel = scaleBarModel
        self.showUI = showUI
    }


    func postSceneAttachment(sceneView: SCNView) {
        sceneView.allowsCameraControl = true
        sceneView.defaultCameraController.interactionMode = .pan
        self.overlays?.forEach { $0.parentMade(view: sceneView) }
    }

    func viewUpdater(uiView: SCNView) {
        if let pov = uiView.pointOfView {
            let pos = pov.position
            let move = SCNAction.moveBy(
                x: 0,
                y: CGFloat(Float(height) - pos.y),
                z: 0, duration: 0.5
            )
            pov.runAction(move)

            pov.camera?.fieldOfView = uiView.frame.size.width
        }

        self.snapshotModel.viewUpdaterHandler(
            scnView: uiView,
            overlay: self.scaleBarModel.scene
        )

        self.overlays?.forEach { $0.parentUpdated(view: uiView) }
    }

    func makeaCamera() -> SCNNode {
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1
        camera.projectionDirection = .horizontal
        camera.zNear = 0.1
        camera.zFar = 1000

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 0)
        cameraNode.eulerAngles = SCNVector3Make(.pi / -2, 0, 0)

        return cameraNode
    }
}
