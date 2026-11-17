//
//  BaseProjectedMiniWorldRender.swift
//  CavernSeer
//
//  Created by Samuel Grush on 11/7/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import SwiftUI /// UIViewRepresentable
import SceneKit /// SCN*

// SwiftUI requires a value type for UIViewRepresentable. SceneKit's delegate is
// weak, so retain its reference-type owner in the representable coordinator.
protocol BaseProjectedMiniWorldRenderController: UIViewRepresentable
    where UIViewType == SCNView, Coordinator == ProjectedRenderCoordinator {

    var showUI: Bool { get }
    var selectedStation: SurveyStation? { get }
    var scaleBarModel: ScaleBarModel { get }
    var renderModel: GeneralRenderModel { get }
    var overlays: [SCNDrawSubview]? { get }
    var observer: SCNRenderObserver? { get }

    func postSceneAttachment(sceneView: SCNView)
    func viewUpdater(uiView: SCNView)
    func makeaCamera() -> SCNNode
}

final class ProjectedRenderCoordinator: NSObject, SCNSceneRendererDelegate {
    let scaleBar: ScaleBarModel?
    let overlays: [SCNDrawSubview]
    weak var observer: SCNRenderObserver?
    var previousSelection: SurveyStation?
    private let frameLock = NSLock()
    private var framePending = false

    init(scaleBar: ScaleBarModel?, overlays: [SCNDrawSubview], observer: SCNRenderObserver?) {
        self.scaleBar = scaleBar
        self.overlays = overlays
        self.observer = observer
    }

    func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        // SceneKit calls this on its rendering thread. Avoid touching any UIKit
        // or SpriteKit state there; queue at most one outstanding refresh.
        frameLock.lock()
        if framePending {
            frameLock.unlock()
            return
        }
        framePending = true
        frameLock.unlock()
        DispatchQueue.main.async { [weak self, weak rendererView = renderer as? SCNView] in
            guard let self = self else { return }
            defer { self.clearPendingFrame() }
            guard let view = rendererView, view.delegate === self else { return }
            self.updateOverlays(renderer: view)
        }
    }

    private func clearPendingFrame() {
        frameLock.lock()
        framePending = false
        frameLock.unlock()
    }

    @MainActor private func updateOverlays(renderer: SCNSceneRenderer) {
        if let scaleBar = scaleBar, let camera = renderer.pointOfView?.camera,
           scaleBar.scene.size.width > 0 {
            let orthoScale = camera.orthographicScale
            if orthoScale.isFinite && orthoScale > 0 && orthoScale != scaleBar.prevOrthoScale {
                scaleBar.prevOrthoScale = orthoScale
                scaleBar.update(renderer: renderer)
            }
        }
        overlays.forEach { $0.parentRender(renderer: renderer) }
        observer?.renderObserver(renderer: renderer)
    }
}

private final class ProjectedSceneView: SCNView {
    var didLayout: ((CGRect) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?(bounds)
    }
}

extension BaseProjectedMiniWorldRenderController {
    var overlays: [SCNDrawSubview]? { nil }
    var observer: SCNRenderObserver? { nil }

    func makeCoordinator() -> ProjectedRenderCoordinator {
        ProjectedRenderCoordinator(scaleBar: showUI ? scaleBarModel : nil, overlays: overlays ?? [], observer: observer)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: ProjectedRenderCoordinator) {
        uiView.isPlaying = false
        uiView.delegate = nil
        uiView.overlaySKScene = nil
        (uiView as? ProjectedSceneView)?.didLayout = nil
        coordinator.overlays.forEach { $0.parentDismantled(view: uiView) }
    }

    func makeUIView(context: Context) -> SCNView {
        let sceneView = ProjectedSceneView(frame: .zero)
        sceneView.backgroundColor = .systemBackground

        let (scene, cameraNode) = makeaScene()
        sceneView.scene = scene
        sceneView.pointOfView = cameraNode

        if showUI {
            sceneView.overlaySKScene = scaleBarModel.scene
            sceneView.didLayout = { [weak scaleBarModel] bounds in
                guard bounds.width > 0, bounds.height > 0,
                      let scaleBar = scaleBarModel, scaleBar.scene.size != bounds.size
                else { return }
                scaleBar.updateOverlay(bounds: bounds)
                scaleBar.prevOrthoScale = 0
            }
        }

        sceneView.delegate = context.coordinator
        postSceneAttachment(sceneView: sceneView)
        sceneView.autoenablesDefaultLighting = true
        sceneView.isPlaying = true
        sceneView.loops = true

        return sceneView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        viewUpdater(uiView: uiView)
        renderModel.viewUpdateHandler(scnView: uiView)

        // RenderModel may have just replaced station nodes, so recolor after
        // updating geometry rather than before it.
        let previous = context.coordinator.previousSelection
        if let previous = previous, previous != selectedStation {
            uiView.scene?.rootNode.childNode(withName: previous.identifier.uuidString, recursively: false)?
                .geometry?.firstMaterial?.diffuse.contents = UIColor.gray
        }
        if let selected = selectedStation {
            uiView.scene?.rootNode.childNode(withName: selected.identifier.uuidString, recursively: false)?
                .geometry?.firstMaterial?.diffuse.contents = UIColor.blue
        }
        context.coordinator.previousSelection = selectedStation
    }

    func makeaScene() -> (SCNScene, SCNNode) {
        let scene = SCNScene()

        let cameraNode = self.makeaCamera()
        cameraNode.name = GeneralRenderModel.cameraNodeName

        scene.rootNode.addChildNode(cameraNode)

        renderModel.sceneNodes.forEach {
            node in
                // node.geometry?.firstMaterial?.diffuse.contents = UIColor.green
                scene.rootNode.addChildNode(node)
        }

        let ambientLightNode = makeAmbientLight()
        scene.rootNode.addChildNode(ambientLightNode)

        return (scene, cameraNode)
    }

    func makeAmbientLight() -> SCNNode {
        let ambientLightNode = SCNNode()
        ambientLightNode.name = GeneralRenderModel.ambientLightNodeName
        ambientLightNode.light = SCNLight()
        ambientLightNode.light!.type = .ambient
        if let ambientColor = renderModel.ambientColor {
            ambientLightNode.light!.color = ambientColor
        }
        return ambientLightNode
    }
}
