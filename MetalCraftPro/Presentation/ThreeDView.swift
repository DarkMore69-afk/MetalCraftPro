//
//  ThreeDView.swift
//  MetalCraftPro
//
//  3D-Ansicht aus der freigegebenen parametrischen 2D-Geometrie: Bauteile werden
//  aus dem Profilquerschnitt entlang der Kontur erzeugt (Mesh-Berechnung im
//  Hintergrund), drehen/zoomen/verschieben per Geste, vier Ansichtsmodi und
//  Explosionsschieberegler. Metal-Rendering über SceneKit.
//

import SwiftUI
import SceneKit

// MARK: - Sitzung

@MainActor
@Observable
final class ThreeDSession {

    enum ViewMode: CaseIterable {
        case front, side, top, iso
        var label: String {
            switch self {
            case .front: return "Vorderansicht"
            case .side: return "Seitenansicht"
            case .top: return "Draufsicht"
            case .iso: return "Isometrie"
            }
        }
    }

    let project: MCProject

    private(set) var builtParts: [BuiltPart] = []
    private(set) var drilledHoles: [CADDrillMarker] = []
    private(set) var modelRevision = 0
    private(set) var isBuilding = true
    private(set) var problem: String?
    private(set) var massKg: Double = 0
    private(set) var modelCenter = Vec3.zero
    private(set) var modelExtent: Double = 1000

    var selectedPartID: UUID?
    var explodeFraction: Double = 0
    var viewMode: ViewMode = .iso { didSet { applyPreset() } }

    // Kamera-Steuerung (Gesten)
    var yawDeg: Double = 40
    var pitchDeg: Double = 32
    var distanceFactor: Double = 1
    var panOffset = Vec3.zero
    var animateCamera = false

    private var buildTask: Task<Void, Never>?

    init(project: MCProject) {
        self.project = project
        rebuild()
    }

    /// Momentaufnahme der Projektdaten – eine Geometriequelle, keine Kopie im Modell.
    static func input(for project: MCProject) -> ThreeDInput {
        ThreeDInput(
            widthMm: project.widthMm,
            heightMm: project.heightMm,
            profile: project.profileSpec,
            parts: project.parts.map { part in
                ThreeDPartInput(id: part.id, name: part.name, positionNumber: part.positionNumber,
                                quantity: part.quantity, role: part.role,
                                profile: part.profileSpec ?? project.profileSpec)
            }
        )
    }

    func rebuild() {
        buildTask?.cancel()
        isBuilding = true
        massKg = (try? DerivationService.totalPartWeightKg(of: project)) ?? 0
        let input = Self.input(for: project)
        let drilling = ThreeDModelBuilder.drillMarkers(drawing: project.cadDrawing ?? CADDrawing(), for: input)
        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let instances = try ThreeDModelBuilder.placements(for: input)
                let built = try ThreeDModelBuilder.build(instances)
                try Task.checkCancellation()
                await MainActor.run {
                    var low = Vec3(x: .infinity, y: .infinity, z: .infinity)
                    var high = Vec3(x: -.infinity, y: -.infinity, z: -.infinity)
                    for part in built {
                        if let box = part.mesh.boundingBox() {
                            low = Vec3(x: min(low.x, box.min.x), y: min(low.y, box.min.y), z: min(low.z, box.min.z))
                            high = Vec3(x: max(high.x, box.max.x), y: max(high.y, box.max.y), z: max(high.z, box.max.z))
                        }
                    }
                    self.modelCenter = Vec3(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2, z: (low.z + high.z) / 2)
                    self.modelExtent = max(400, max(high.x - low.x, max(high.y - low.y, high.z - low.z)))
                    self.builtParts = built
                    self.drilledHoles = drilling
                    self.modelRevision += 1
                    self.isBuilding = false
                    self.problem = nil
                }
            } catch {
                await MainActor.run {
                    self.isBuilding = false
                    self.problem = "3D-Modell konnte nicht berechnet werden: \(error.localizedDescription)"
                }
            }
        }
    }

    func applyPreset() {
        switch viewMode {
        case .front: yawDeg = 0; pitchDeg = 0
        case .side: yawDeg = 90; pitchDeg = 0
        case .top: yawDeg = 0; pitchDeg = 88
        case .iso: yawDeg = 40; pitchDeg = 32
        }
        distanceFactor = 1
        panOffset = .zero
        animateCamera = true
    }

    func resetCamera() {
        applyPreset()
    }

    func consumeCameraAnimation() -> Bool {
        defer { animateCamera = false }
        return animateCamera
    }

    /// Ein Beobachtungsschlüssel, damit SwiftUI jede Kamera-/Modell-Änderung sieht.
    var sceneStamp: Int {
        var hasher = Hasher()
        hasher.combine(yawDeg)
        hasher.combine(pitchDeg)
        hasher.combine(distanceFactor)
        hasher.combine(panOffset.x)
        hasher.combine(panOffset.y)
        hasher.combine(panOffset.z)
        hasher.combine(modelRevision)
        hasher.combine(explodeFraction)
        hasher.combine(selectedPartID)
        return hasher.finalize()
    }
}

// MARK: - Ansicht

struct ThreeDView: View {
    @Environment(\.dismiss) private var dismiss
    let project: MCProject
    @State private var session: ThreeDSession

    init(project: MCProject) {
        self.project = project
        _session = State(initialValue: ThreeDSession(project: project))
    }

    var body: some View {
        VStack(spacing: 12) {
            topBar
            modeBar
            sceneArea
            bottomControls
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Theme.appBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: project.widthMm) { _, _ in session.rebuild() }
        .onChange(of: project.heightMm) { _, _ in session.rebuild() }
        .onChange(of: project.profileSpecData) { _, _ in session.rebuild() }
        .onChange(of: project.parts.count) { _, _ in session.rebuild() }
        .onChange(of: project.cadData) { _, _ in session.rebuild() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
            .accessibilityLabel("Zurück")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(project.name) – 3D").font(.headline).lineLimit(1)
                Text("\(project.number) · Revision \(project.revisionLabel)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Kamera zurücksetzen", systemImage: "arrow.counterclockwise") { session.resetCamera() }
                Button("Neu berechnen", systemImage: "arrow.triangle.2.circlepath") { session.rebuild() }
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 32)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
            .accessibilityLabel("3D-Aktionen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var modeBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(ThreeDSession.ViewMode.allCases.enumerated()), id: \.offset) { index, mode in
                Button {
                    session.viewMode = mode
                } label: {
                    VStack(spacing: 5) {
                        ViewModeGlyph(mode: mode)
                            .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                            .frame(width: 30, height: 20)
                        Text(mode.label).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(session.viewMode == mode ? Theme.accent : Color.clear,
                                in: RoundedRectangle(cornerRadius: 13))
                    .foregroundStyle(session.viewMode == mode ? Color.black : Color(white: 0.72))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.label)
                if index < ThreeDSession.ViewMode.allCases.count - 1 {
                    Divider().frame(height: 34).opacity(0.25)
                }
            }
        }
        .padding(5)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var sceneArea: some View {
        SceneHost(session: session)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { sceneOverlays }
    }

    @ViewBuilder private var sceneOverlays: some View {
        if !project.isGeometryApproved {
            VStack(alignment: .leading, spacing: 3) {
                Label("Geometrie noch nicht freigegeben", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                Text("Die 3D-Ansicht ist unverbindlich, bis die Maßkontrolle bestanden ist.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(Theme.accent)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.08).opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.4), lineWidth: 0.8) }
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        if session.isBuilding {
            ProgressView("3D-Modell wird berechnet …")
                .padding(16)
                .background(Color(white: 0.09).opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        }
        if let problem = session.problem {
            Label(problem, systemImage: "exclamationmark.octagon")
                .font(.footnote).foregroundStyle(.red)
                .padding(12).background(Color(white: 0.09).opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                .padding(10)
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                partsCard
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").font(.title3)
                        Text("Masse: \(DeFormat.number(session.massKg, maxFractionDigits: 1)) kg")
                            .font(.subheadline).monospacedDigit()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            HStack(spacing: 12) {
                Text("Explodieren").font(.headline)
                Slider(value: $session.explodeFraction).tint(Theme.accent)
                Text("\(Int((session.explodeFraction * 100).rounded())) %")
                    .font(.subheadline).monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var partsCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bauteile").font(.headline)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 5)
            ScrollView(showsIndicators: true) {
                VStack(spacing: 2) {
                    ForEach(project.parts.sorted { $0.positionNumber < $1.positionNumber }) { part in
                        let selected = session.selectedPartID == part.id
                        Button {
                            session.selectedPartID = selected ? nil : part.id
                        } label: {
                            HStack(spacing: 10) {
                                PartGlyph(role: part.role, type: part.profileSpec?.type ?? project.profileSpec.type)
                                    .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                    .frame(width: 28, height: 18)
                                Text(part.name).font(.subheadline).lineLimit(1)
                                Spacer()
                                Text("\(part.positionNumber)").font(.subheadline).monospacedDigit()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(selected ? .black : .primary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        .accessibilityLabel("Pos. \(part.positionNumber) \(part.name)")
                    }
                }
            }
            .frame(maxHeight: 104)
        }
        .padding(.bottom, 8)
        .frame(width: 240)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Liest den Sitzungs-Zustand, damit SwiftUI jede Änderung an die Szene weiterreicht.
private struct SceneHost: View {
    let session: ThreeDSession

    var body: some View {
        let stamp = session.sceneStamp
        return ThreeDSceneView(session: session)
            .onAppear { _ = stamp }
    }
}

// MARK: - SceneKit

private struct ThreeDSceneView: UIViewRepresentable {
    @MainActor let session: ThreeDSession

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.makeScene()
        view.backgroundColor = UIColor(white: 0.05, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.sync(view: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor private static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(white: 0.05, alpha: 1)

        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 1
        camera.zFar = 100_000
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 320
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .omni
        key.intensity = 1100
        key.castsShadow = true
        key.shadowRadius = 9
        key.shadowColor = UIColor(white: 0, alpha: 0.55)
        let keyNode = SCNNode()
        keyNode.name = "keyLight"
        keyNode.light = key
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .omni
        fill.intensity = 420
        let fillNode = SCNNode()
        fillNode.name = "fillLight"
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)

        let floor = SCNFloor()
        floor.reflectivity = 0
        let floorMaterial = SCNMaterial()
        floorMaterial.diffuse.contents = UIColor(white: 0.07, alpha: 1)
        floorMaterial.lightingModel = .lambert
        floor.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "floor"
        scene.rootNode.addChildNode(floorNode)

        let modelRoot = SCNNode()
        modelRoot.name = "modelRoot"
        scene.rootNode.addChildNode(modelRoot)
        return scene
    }
}

@MainActor
final class Coordinator {
    private let session: ThreeDSession
    private var builtRevision = -1
    private var lastStamp = 0
    private var lastScale: CGFloat = 1

    init(session: ThreeDSession) { self.session = session }

    func sync(view: SCNView) {
        guard let scene = view.scene else { return }
        if builtRevision != session.modelRevision {
            rebuildContent(in: scene)
            builtRevision = session.modelRevision
        }
        applySelectionAndExplode(in: scene)
        updateLightsAndFloor(in: scene)
        updateCamera(in: scene, animated: session.consumeCameraAnimation())
    }

    private func rebuildContent(in scene: SCNScene) {
        guard let root = scene.rootNode.childNode(withName: "modelRoot", recursively: false) else { return }
        root.childNodes.forEach { $0.removeFromParentNode() }
        for built in session.builtParts {
            var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
            vertices.reserveCapacity(built.mesh.positions.count)
            for point in built.mesh.positions { vertices.append(vec(point)) }
            for normal in built.mesh.normals { normals.append(vec(normal)) }
            let vertexSource = SCNGeometrySource(vertices: vertices)
            let normalSource = SCNGeometrySource(normals: normals)
            let element = SCNGeometryElement(indices: built.mesh.indices.map { Int32($0) }, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
            let node = SCNNode(geometry: geometry)
            node.name = "part-\(built.partID.uuidString)"
            root.addChildNode(node)
        }
        for drilled in session.drilledHoles {
            guard let owner = root.childNode(withName: "part-\(drilled.partID.uuidString)", recursively: false) else { continue }
            let ring = SCNTube(innerRadius: CGFloat(drilled.radiusMm),
                               outerRadius: CGFloat(drilled.radiusMm + 0.8), height: 0.45)
            let ringMaterial = SCNMaterial()
            ringMaterial.diffuse.contents = UIColor(white: 0.82, alpha: 1)
            ringMaterial.metalness.contents = 0.72
            ringMaterial.roughness.contents = 0.28
            ring.materials = [ringMaterial]
            let ringNode = SCNNode(geometry: ring)
            ringNode.name = "drill-ring-\(drilled.id.uuidString)"
            ringNode.eulerAngles.x = .pi / 2
            ringNode.position = vec(drilled.center)
            owner.addChildNode(ringNode)

            let bore = SCNCylinder(radius: CGFloat(max(0.2, drilled.radiusMm - 0.15)), height: 0.16)
            let boreMaterial = SCNMaterial()
            boreMaterial.diffuse.contents = UIColor(white: 0.025, alpha: 1)
            boreMaterial.lightingModel = .constant
            bore.materials = [boreMaterial]
            let boreNode = SCNNode(geometry: bore)
            boreNode.name = "drill-bore-\(drilled.id.uuidString)"
            boreNode.eulerAngles.x = .pi / 2
            boreNode.position = SCNVector3(Float(drilled.center.x), Float(drilled.center.y), Float(drilled.center.z + 0.01))
            owner.addChildNode(boreNode)
        }
        root.position = vec(session.modelCenter * -1)
    }

    private func applySelectionAndExplode(in scene: SCNScene) {
        guard let root = scene.rootNode.childNode(withName: "modelRoot", recursively: false) else { return }
        let offsetDistance = session.modelExtent * 0.45 * session.explodeFraction
        for node in root.childNodes {
            guard let name = node.name, name.hasPrefix("part-"),
                  let id = UUID(uuidString: String(name.dropFirst(5))) else { continue }
            let direction = session.builtParts.first { $0.partID == id }?.explodeDirection ?? Vec3.zero
            node.position = vec(direction * (offsetDistance))
            let selected = session.selectedPartID == id
            if let material = node.geometry?.firstMaterial {
                material.diffuse.contents = selected ? UIColor(Theme.accent) : UIColor(white: 0.76, alpha: 1)
                material.emission.contents = selected ? UIColor(Theme.accent).withAlphaComponent(0.28) : UIColor.black
            }
        }
    }

    private func updateLightsAndFloor(in scene: SCNScene) {
        let center = session.modelCenter
        let extent = session.modelExtent
        if let key = scene.rootNode.childNode(withName: "keyLight", recursively: false) {
            key.position = SCNVector3(Float(center.x + extent * 0.9), Float(center.y + extent * 1.1), Float(center.z + extent * 1.2))
        }
        if let fill = scene.rootNode.childNode(withName: "fillLight", recursively: false) {
            fill.position = SCNVector3(Float(center.x - extent), Float(center.y + extent * 0.4), Float(center.z - extent * 0.8))
        }
        if let floor = scene.rootNode.childNode(withName: "floor", recursively: false) {
            floor.position = SCNVector3(Float(center.x), Float(center.y - extent * 0.08), Float(center.z))
        }
    }

    private func updateCamera(in scene: SCNScene, animated: Bool) {
        guard let cameraNode = scene.rootNode.childNode(withName: "camera", recursively: false) else { return }
        let target = session.modelCenter + session.panOffset
        let distance = session.modelExtent * 2.1 * session.distanceFactor
        let yaw = session.yawDeg * .pi / 180
        let pitch = session.pitchDeg * .pi / 180
        let direction = Vec3(x: sin(yaw) * cos(pitch), y: sin(pitch), z: cos(yaw) * cos(pitch))
        let position = target + direction * distance
        let up: SCNVector3 = session.pitchDeg > 80 ? SCNVector3(0, 0, -1) : SCNVector3(0, 1, 0)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.45 : 0
        cameraNode.position = vec(position)
        cameraNode.look(at: vec(target), up: up, localFront: SCNVector3(0, 0, -1))
        SCNTransaction.commit()
    }

    private func vec(_ value: Vec3) -> SCNVector3 {
        SCNVector3(Float(value.x), Float(value.y), Float(value.z))
    }

    // MARK: Gesten

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view)
        if gesture.numberOfTouches >= 2 {
            let scale = session.modelExtent / 600
            let yaw = session.yawDeg * .pi / 180
            let right = Vec3(x: cos(yaw), y: 0, z: -sin(yaw))
            session.panOffset = session.panOffset + right * (-Double(translation.x) * scale) + Vec3(x: 0, y: 1, z: 0) * (Double(translation.y) * scale)
        } else {
            session.yawDeg += Double(translation.x) * 0.35
            session.pitchDeg = min(88, max(-25, session.pitchDeg + Double(translation.y) * 0.3))
        }
        gesture.setTranslation(.zero, in: view)
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began: lastScale = 1
        case .changed:
            let delta = gesture.scale / max(0.0001, lastScale)
            lastScale = gesture.scale
            session.distanceFactor = min(4, max(0.25, session.distanceFactor / max(0.05, delta)))
        default: lastScale = 1
        }
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? SCNView else { return }
        let hits = view.hitTest(gesture.location(in: view), options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
        if let node = hits.first(where: { $0.node.name?.hasPrefix("part-") == true })?.node,
           let name = node.name, let id = UUID(uuidString: String(name.dropFirst(5))) {
            session.selectedPartID = session.selectedPartID == id ? nil : id
        } else {
            session.selectedPartID = nil
        }
    }
}

// MARK: - Mini-Glyphen

struct ViewModeGlyph: Shape {
    let mode: ThreeDSession.ViewMode

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        switch mode {
        case .front:
            path.addRoundedRect(in: CGRect(x: 1, y: 1, width: w - 2, height: h - 2), cornerSize: CGSize(width: 2, height: 2))
            for index in 1...4 {
                let x = w * CGFloat(index) / 5
                path.move(to: CGPoint(x: x, y: 3))
                path.addLine(to: CGPoint(x: x, y: h - 3))
            }
        case .side:
            path.addRoundedRect(in: CGRect(x: w / 2 - 4, y: 1, width: 8, height: h - 2), cornerSize: CGSize(width: 2, height: 2))
        case .top:
            path.addRoundedRect(in: CGRect(x: 1, y: h / 2 - 3.5, width: w - 2, height: 7), cornerSize: CGSize(width: 2, height: 2))
        case .iso:
            let midX = w / 2
            path.move(to: CGPoint(x: midX, y: 1))
            path.addLine(to: CGPoint(x: w - 2, y: h * 0.3))
            path.addLine(to: CGPoint(x: w - 2, y: h * 0.7))
            path.addLine(to: CGPoint(x: midX, y: h - 1))
            path.addLine(to: CGPoint(x: 2, y: h * 0.7))
            path.addLine(to: CGPoint(x: 2, y: h * 0.3))
            path.closeSubpath()
            path.move(to: CGPoint(x: 2, y: h * 0.3))
            path.addLine(to: CGPoint(x: midX, y: h * 0.6))
            path.addLine(to: CGPoint(x: w - 2, y: h * 0.3))
            path.move(to: CGPoint(x: midX, y: h * 0.6))
            path.addLine(to: CGPoint(x: midX, y: h - 1))
        }
        return path
    }
}

struct PartGlyph: Shape {
    let role: String?
    let type: ProfileType

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        switch role {
        case "rahmen_oben", "rahmen_unten":
            path.move(to: CGPoint(x: 1, y: h / 2 - 2.5)); path.addLine(to: CGPoint(x: w - 1, y: h / 2 - 2.5))
            path.move(to: CGPoint(x: 1, y: h / 2 + 2.5)); path.addLine(to: CGPoint(x: w - 1, y: h / 2 + 2.5))
        case "rahmen_links", "rahmen_rechts":
            path.move(to: CGPoint(x: w / 2 - 2.5, y: 1)); path.addLine(to: CGPoint(x: w / 2 - 2.5, y: h - 1))
            path.move(to: CGPoint(x: w / 2 + 2.5, y: 1)); path.addLine(to: CGPoint(x: w / 2 + 2.5, y: h - 1))
        case "strebe":
            for index in 0..<3 {
                let x = w * CGFloat(index + 1) / 4
                path.move(to: CGPoint(x: x, y: 1)); path.addLine(to: CGPoint(x: x, y: h - 1))
            }
        default:
            switch type {
            case .rundrohr, .rundstahl:
                path.addEllipse(in: CGRect(x: w / 2 - 5, y: h / 2 - 5, width: 10, height: 10))
            default:
                path.move(to: CGPoint(x: 1, y: h / 2)); path.addLine(to: CGPoint(x: w - 1, y: h / 2))
            }
        }
        return path
    }
}
