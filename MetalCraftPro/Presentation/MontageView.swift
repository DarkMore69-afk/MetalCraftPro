//
//  MontageView.swift
//  MetalCraftPro
//
//  Interaktive Schritt-für-Schritt-Montageanleitung: 3D-Ansicht mit animiertem
//  Einsetzen, Explosionsansicht, Schnittansicht, Einzelteil hervorheben,
//  Transparenz, bearbeitbarer Reihenfolge und Sollwert-Prüfungen pro Schritt.
//

import SwiftUI
import SceneKit

// MARK: - Sitzung

@MainActor
@Observable
final class MontageSession {
    private(set) var builtParts: [BuiltPart] = []
    private(set) var modelRevision = 0
    private(set) var isBuilding = true
    private(set) var problem: String?
    var modelCenter: Vec3 = .zero
    var modelExtent: Double = 800

    var yawDeg: Double = 32
    var pitchDeg: Double = 16
    var distanceFactor: Double = 1
    var panOffset: Vec3 = .zero
    var animateCamera = false

    var exploded = false
    var sectionView = false
    var isolate = false
    var ghostFuture = true

    var stepPartIDs: [[UUID]] = []
    var statuses: [UUID: String] = [:]
    var stepIndex = 0
    var replayToken = 0

    private var buildTask: Task<Void, Never>?

    func load(input: ThreeDInput) {
        buildTask?.cancel()
        isBuilding = true
        problem = nil
        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let placements = try ThreeDModelBuilder.placements(for: input)
                let built = try ThreeDModelBuilder.build(placements)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.builtParts = built
                    self.modelRevision += 1
                    self.isBuilding = false
                    var low = Vec3(x: .infinity, y: .infinity, z: .infinity)
                    var high = Vec3(x: -.infinity, y: -.infinity, z: -.infinity)
                    for part in built {
                        guard let box = part.mesh.boundingBox() else { continue }
                        low = Vec3(x: min(low.x, box.min.x), y: min(low.y, box.min.y), z: min(low.z, box.min.z))
                        high = Vec3(x: max(high.x, box.max.x), y: max(high.y, box.max.y), z: max(high.z, box.max.z))
                    }
                    if low.x.isFinite {
                        self.modelCenter = Vec3(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2, z: (low.z + high.z) / 2)
                        self.modelExtent = max(high.x - low.x, high.y - low.y, high.z - low.z, 400)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isBuilding = false
                    self.problem = "3D-Vorschau konnte nicht berechnet werden: \(error.localizedDescription)"
                }
            }
        }
    }

    func clampIndex() {
        guard !stepPartIDs.isEmpty else { stepIndex = 0; return }
        stepIndex = max(0, min(stepIndex, stepPartIDs.count - 1))
    }

    var currentPartIDs: Set<UUID> {
        guard stepPartIDs.indices.contains(stepIndex) else { return [] }
        return Set(stepPartIDs[stepIndex])
    }

    var installedPartIDs: Set<UUID> {
        var installed: Set<UUID> = []
        for index in 0..<stepIndex where stepPartIDs.indices.contains(index) {
            guard stepPartIDs.indices.contains(index) else { continue }
            installed.formUnion(stepPartIDs[index])
        }
        return installed
    }

    var sceneStamp: Int {
        var hasher = Hasher()
        hasher.combine(modelRevision)
        hasher.combine(exploded); hasher.combine(sectionView)
        hasher.combine(isolate); hasher.combine(ghostFuture)
        hasher.combine(stepIndex); hasher.combine(replayToken)
        hasher.combine(yawDeg); hasher.combine(pitchDeg)
        hasher.combine(distanceFactor)
        hasher.combine(panOffset.x); hasher.combine(panOffset.y); hasher.combine(panOffset.z)
        hasher.combine(stepPartIDs.count)
        for (id, status) in statuses { hasher.combine(id); hasher.combine(status) }
        return hasher.finalize()
    }
}

// MARK: - Ansicht

struct MontageView: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject
    @State private var session = MontageSession()
    @State private var showOrder = false
    @State private var measuredText = ""
    @State private var toleranceText = "1,0"
    @State private var checkResult: CheckResult?
    @State private var checkLogged = false
    @State private var problem: String?

    var body: some View {
        let stamp = session.sceneStamp
        return VStack(spacing: 12) {
            topBar
            progressDots
            sceneArea
            if let step = currentStep { stepCards(step) }
            navigationBar
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
        .background(Theme.appBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { prepare() }
        .onChange(of: steps.map(\.id)) { _, _ in
            syncSession()
            resetCheck()
        }
        .onChange(of: session.stepIndex) { _, _ in resetCheck() }
        .onChange(of: project.widthMm) { _, _ in rebuild() }
        .onChange(of: project.heightMm) { _, _ in rebuild() }
        .onChange(of: project.profileSpecData) { _, _ in rebuild() }
        .onChange(of: project.parts.count) { _, _ in rebuild() }
        .sheet(isPresented: $showOrder) { StepOrderSheet(project: project) }
        .alert("Nicht gespeichert", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .onAppear { _ = stamp }
    }

    // MARK: Daten

    private var rootAssembly: MCAssembly? {
        project.assemblies
            .filter { $0.parentAssemblyID == nil }
            .sorted { $0.positionNumber < $1.positionNumber }
            .first ?? project.assemblies.first
    }
    private var steps: [MCAssemblyStep] { rootAssembly?.orderedSteps ?? [] }
    private var currentStep: MCAssemblyStep? {
        steps.indices.contains(session.stepIndex) ? steps[session.stepIndex] : nil
    }
    private func parts(for step: MCAssemblyStep) -> [MCPart] {
        step.allPartIDs.compactMap { partID in project.parts.first(where: { $0.id == partID }) }
    }
    private var atEnd: Bool { session.stepIndex >= steps.count - 1 }

    private func syncSession() {
        let ids = steps.map { $0.allPartIDs }
        if ids != session.stepPartIDs {
            session.stepPartIDs = ids
            session.clampIndex()
        }
    }

    private func prepare() {
        syncSession()
        do { try store.ensureAssemblySteps(project) } catch { problem = error.localizedDescription }
        syncSession()
        if session.builtParts.isEmpty { rebuild() }
    }

    private func rebuild() {
        syncSession()
        let input = ThreeDInput(
            widthMm: project.widthMm, heightMm: project.heightMm, profile: project.profileSpec,
            parts: project.parts.map { part in
                ThreeDPartInput(id: part.id, name: part.name, positionNumber: part.positionNumber,
                                quantity: part.quantity, role: part.role,
                                profile: part.profileSpec ?? project.profileSpec)
            })
        session.load(input: input)
    }

    private func resetCheck() {
        measuredText = ""
        checkResult = nil
        checkLogged = false
    }

    private func markCurrent(_ status: String) {
        if let step = currentStep { session.statuses[step.id] = status }
    }

    private func advance() {
        markCurrent("erledigt")
        if atEnd { dismiss() } else { session.stepIndex += 1 }
    }

    // MARK: Kopf

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Zurück")
            VStack(spacing: 2) {
                Text("Montage").font(.title3.weight(.semibold))
                Text(steps.isEmpty ? "Noch keine Schritte" : "Schritt \(session.stepIndex + 1) von \(steps.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            Button { showOrder = true } label: {
                Image(systemName: "list.bullet").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Reihenfolge bearbeiten")
        }
    }

    private var progressDots: some View {
        HStack(spacing: 9) {
            ForEach(steps.indices, id: \.self) { index in
                let stepID = steps[index].id
                Circle()
                    .fill(dotColor(index: index, stepID: stepID))
                    .frame(width: index == session.stepIndex ? 11 : 8,
                           height: index == session.stepIndex ? 11 : 8)
            }
        }
        .frame(minHeight: 14)
    }
    private func dotColor(index: Int, stepID: UUID) -> Color {
        if index == session.stepIndex { return Theme.accent }
        switch session.statuses[stepID] {
        case "erledigt": return Theme.accent.opacity(0.75)
        case "übersprungen": return Color(white: 0.35)
        default: return Color(white: 0.28)
        }
    }

    // MARK: 3D-Bereich

    private var sceneArea: some View {
        ZStack {
            MontageSceneView(session: session)
            if session.isBuilding {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Montagemodell wird vorbereitet …").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16).background(Color(white: 0.08).opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
            }
            if let problem = session.problem {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
                    .padding(12).background(Color(white: 0.08).opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                    .padding(12)
            }
            if steps.isEmpty, !session.isBuilding {
                Text("Die Montageabfolge entsteht aus der Baugruppe.").font(.footnote).foregroundStyle(.secondary)
                    .padding(12).background(Color(white: 0.08).opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(spacing: 10) {
                Spacer()
                HStack(spacing: 0) {
                    sceneButton("cube", active: session.exploded, label: "Explosionsansicht") { session.exploded.toggle() }
                    sceneButton("square.split.2x1", active: session.sectionView, label: "Schnittansicht") { session.sectionView.toggle() }
                    sceneButton("cube.transparent", active: session.isolate, label: "Einzelteil hervorheben") { session.isolate.toggle() }
                    sceneButton("circle.lefthalf.filled", active: session.ghostFuture, label: "Transparenz") { session.ghostFuture.toggle() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 240, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
    private func sceneButton(_ icon: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .light))
                .frame(width: 44, height: 44)
                .foregroundStyle(active ? .black : .white)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(active ? Theme.accent : .white)
        .accessibilityLabel(label)
    }

    // MARK: Schritt-Karten

    private func stepCards(_ step: MCAssemblyStep) -> some View {
        VStack(spacing: 10) {
            infoCard(step)
            checkCard(step)
        }
    }

    private func infoCard(_ step: MCAssemblyStep) -> some View {
        let stepParts = parts(for: step)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(step.title).font(.title3.weight(.semibold))
                Spacer()
                Button {
                    session.replayToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
                .accessibilityLabel("Schritt wiederholen")
            }
            .padding(.bottom, 10)
            infoRow("Position:", positionText(step: step, parts: stepParts))
            Divider().padding(.vertical, 7)
            infoRow("Verbindung:", step.connection.isEmpty ? "–" : step.connection)
            Divider().padding(.vertical, 7)
            infoRow("Werkzeug:", step.tool.isEmpty ? "–" : step.tool)
            Divider().padding(.vertical, 7)
            infoRow("Maß:", measureText(parts: stepParts))
            if !step.note.isEmpty {
                Divider().padding(.vertical, 7)
                infoRow("Hinweis:", step.note)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(cornerRadius: 22))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func positionText(step: MCAssemblyStep, parts: [MCPart]) -> String {
        if parts.count == 1, let role = parts[0].role {
            return AssemblySequenceBuilder.positionNote(for: role, quantity: max(1, parts[0].quantity), heightMm: project.heightMm)
        }
        return step.positionNote.isEmpty ? "wie Zeichnung" : step.positionNote
    }

    private func measureText(parts: [MCPart]) -> String {
        guard !parts.isEmpty else { return "–" }
        let labels = parts.map { $0.profileSpec?.dimensionLabel ?? project.profileSpec.dimensionLabel }
        let unique = Array(Set(labels)).sorted()
        let profile = unique.count == 1 ? unique[0] : unique.joined(separator: " · ")
        let quantity = parts.reduce(0) { $0 + max(1, $1.quantity) }
        let length = parts.map(\.lengthMm).max() ?? 0
        guard length > 0 else { return "Profil \(profile)" }
        let count = quantity > 1 ? "\(quantity) × " : ""
        return "Profil \(profile), Länge \(count)\(DeFormat.number(length, maxFractionDigits: 0)) mm"
    }

    // MARK: Prüfkarte

    private var currentCheck: StepCheck? {
        guard let step = currentStep else { return nil }
        let stepParts = parts(for: step)
        guard !stepParts.isEmpty else { return nil }
        let roles = stepParts.compactMap(\.role)
        let hasTop = roles.contains("rahmen_oben")
        let laterHasTop = steps.dropFirst(session.stepIndex + 1).contains { later in
            parts(for: later).compactMap(\.role).contains("rahmen_oben")
        }
        if hasTop && !laterHasTop {
            let diagonal = (project.widthMm * project.widthMm + project.heightMm * project.heightMm).squareRoot()
            return StepCheck(title: "Diagonalen prüfen", targetMm: diagonal, toleranceMm: tolerance)
        }
        let length = stepParts.map(\.lengthMm).max() ?? 0
        guard length > 0 else { return nil }
        return StepCheck(title: "Länge prüfen", targetMm: length, toleranceMm: tolerance)
    }

    private var tolerance: Double { DeFormat.parse(toleranceText) ?? 1.0 }

    private func checkCard(_ step: MCAssemblyStep) -> some View {
        Group {
            if let check = currentCheck {
                VStack(alignment: .leading, spacing: 10) {
                    Text(check.title).font(.title3.weight(.semibold))
                    HStack {
                        Text("Sollwert \(DeFormat.number(check.targetMm, maxFractionDigits: 2)) mm")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        HStack(spacing: 4) {
                            Text("Toleranz ±").font(.subheadline).foregroundStyle(.secondary)
                            TextField("1,0", text: $toleranceText)
                                .font(.subheadline).multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad).monospacedDigit()
                                .frame(width: 44)
                            Text("mm").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        TextField("Messwert eingeben", text: $measuredText)
                            .font(.subheadline).keyboardType(.decimalPad)
                        Text("mm").font(.subheadline).foregroundStyle(.secondary)
                        Button("Prüfen") { evaluate(check) }
                            .font(.subheadline.weight(.semibold))
                            .disabled(DeFormat.parse(measuredText) == nil)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                    if let result = checkResult {
                        HStack(spacing: 8) {
                            Image(systemName: result.withinTolerance ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.withinTolerance ? .green : .red)
                            Text(result.withinTolerance
                                 ? "Innerhalb der definierten Toleranz"
                                 : "Außerhalb der Toleranz · Abweichung \(DeFormat.number(result.deviationMm, maxFractionDigits: 2)) mm")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(result.withinTolerance ? .green : .red)
                        }
                        if checkLogged {
                            Text("Im Projektprotokoll gespeichert.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card(cornerRadius: 22))
                .accessibilityIdentifier("montageCheck")
            }
        }
    }

    private func evaluate(_ check: StepCheck) {
        guard let measured = DeFormat.parse(measuredText) else { return }
        do {
            checkResult = try store.recordAssemblyCheck(
                project, stepTitle: currentStep?.title ?? "", checkTitle: check.title,
                measuredMm: measured, targetMm: check.targetMm, toleranceMm: check.toleranceMm)
            checkLogged = true
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Navigation

    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button {
                if session.stepIndex > 0 { session.stepIndex -= 1 }
            } label: {
                Image(systemName: "chevron.left").font(.body).frame(width: 44, height: 48)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
            .disabled(session.stepIndex == 0).opacity(session.stepIndex == 0 ? 0.4 : 1)
            .accessibilityLabel("Zurück")

            Button { advance() } label: {
                Text(atEnd ? "Fertig" : "Weiter")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
            .disabled(steps.isEmpty)
            .accessibilityIdentifier("montageNext")

            Button {
                markCurrent("übersprungen")
                if atEnd { dismiss() } else { session.stepIndex += 1 }
            } label: {
                Image(systemName: "chevron.right").font(.body).frame(width: 44, height: 48)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
            .disabled(steps.isEmpty)
            .accessibilityLabel("Schritt überspringen")
        }
    }
}

// MARK: - Reihenfolge bearbeiten

private struct StepOrderSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject
    @State private var problem: String?

    private var assembly: MCAssembly? {
        project.assemblies
            .filter { $0.parentAssemblyID == nil }
            .sorted { $0.positionNumber < $1.positionNumber }
            .first ?? project.assemblies.first
    }
    private var steps: [MCAssemblyStep] { assembly?.orderedSteps ?? [] }

    var body: some View {
        NavigationStack {
            List {
                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title).font(.body.weight(.medium))
                        Text("\(step.allPartIDs.count) Bauteil\(step.allPartIDs.count == 1 ? "" : "e") · \(movementLabel(step.movement))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        if let index = steps.firstIndex(where: { $0.id == step.id }), index > 0 {
                            Button("Mit vorherigem Schritt zusammenfassen") {
                                do { try store.mergeAssemblyStep(project, step: step) } catch { problem = error.localizedDescription }
                            }
                        }
                    }
                }
                .onMove { sources, destination in
                    guard let source = sources.first, steps.indices.contains(source) else { return }
                    do { try store.moveAssemblyStep(project, step: steps[source], to: destination) }
                    catch { problem = error.localizedDescription }
                }
                Section {
                    Button("Neu aus der Baugruppe erzeugen") {
                        do { try store.regenerateAssemblySteps(project) } catch { problem = error.localizedDescription }
                    }
                    Text("Die Abfolge wird aus den Bauteilrollen abgeleitet: Basis, Seiten, Querstreben, Rahmenabschluss, Zukaufteile.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Reihenfolge").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { EditButton() }
            }
            .alert("Nicht gespeichert", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
        }
    }

    private func movementLabel(_ movement: String) -> String {
        switch movement {
        case "ablegen": return "ablegen"
        case "aufsetzen": return "aufsetzen"
        case "einschieben": return "einschieben"
        case "montieren": return "montieren"
        default: return "ansetzen"
        }
    }
}

// MARK: - 3D-Szene

private struct MontageSceneView: UIViewRepresentable {
    let session: MontageSession

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.makeScene()
        view.backgroundColor = UIColor(white: 0.055, alpha: 1)
        view.antialiasingMode = .multisampling4X
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let scene = view.scene else { return }
        context.coordinator.sync(view: view, scene: scene, session: session)
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    static func makeScene() -> SCNScene {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 1
        camera.zFar = 100_000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 320; ambient.light?.color = UIColor(white: 1, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.name = "keyLight"
        key.light = SCNLight(); key.light?.type = .omni
        key.light?.intensity = 750; key.light?.castsShadow = true
        key.light?.shadowRadius = 8; key.light?.shadowColor = UIColor(white: 0, alpha: 0.55)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.name = "fillLight"
        fill.light = SCNLight(); fill.light?.type = .omni
        fill.light?.intensity = 280; fill.light?.color = UIColor(white: 0.85, alpha: 1)
        scene.rootNode.addChildNode(fill)

        let floor = SCNFloor()
        floor.reflectivity = 0
        let floorMaterial = SCNMaterial()
        floorMaterial.diffuse.contents = UIColor(white: 0.05, alpha: 1)
        floor.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "floor"
        scene.rootNode.addChildNode(floorNode)
        return scene
    }

    @MainActor
    final class Coordinator {
        let session: MontageSession
        private var builtRevision = -1
        private var lastStamp = 0
        private var lastStepKey = ""
        private var lastScale: CGFloat = 1

        init(session: MontageSession) { self.session = session }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            if gesture.numberOfTouches >= 2 {
                let scale = session.modelExtent / 700
                let yaw = session.yawDeg * .pi / 180
                let right = Vec3(x: cos(yaw), y: 0, z: -sin(yaw))
                session.panOffset = session.panOffset + right * (-translation.x * Double(scale)) + Vec3(x: 0, y: 1, z: 0) * (translation.y * Double(scale))
            } else {
                session.yawDeg += Double(translation.x) * 0.35
                session.pitchDeg = min(86, max(-14, session.pitchDeg + Double(translation.y) * 0.3))
            }
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .changed else { return }
            let delta = gesture.scale / lastScale
            lastScale = gesture.scale
            session.distanceFactor = min(4, max(0.3, session.distanceFactor / delta))
        }

        func sync(view: SCNView, scene: SCNScene, session: MontageSession) {
            let stamp = session.sceneStamp
            guard stamp != lastStamp else { return }
            lastStamp = stamp

            let root = scene.rootNode.childNode(withName: "modelRoot", recursively: false)
                ?? {
                    let node = SCNNode(); node.name = "modelRoot"; scene.rootNode.addChildNode(node); return node
                }()
            if builtRevision != session.modelRevision {
                builtRevision = session.modelRevision
                root.childNodes.filter { $0.name?.hasPrefix("part-") == true }
                    .forEach { $0.removeFromParentNode() }
                for part in session.builtParts { root.addChildNode(node(for: part)) }
                root.position = vec(session.modelCenter * -1)
                if let floor = scene.rootNode.childNode(withName: "floor", recursively: false) {
                    floor.position = SCNVector3(session.modelCenter.x, session.modelCenter.y - session.modelExtent * 0.62, session.modelCenter.z)
                }
                updateLights(scene: scene)
            }

            let currentIDs = session.currentPartIDs
            let installedIDs = session.installedPartIDs
            for node in root.childNodes where node.name?.hasPrefix("part-") == true {
                guard let text = node.name?.dropFirst(5), let id = UUID(uuidString: String(text)) else { continue }
                let isCurrent = currentIDs.contains(id)
                let isInstalled = installedIDs.contains(id)
                node.geometry?.firstMaterial = isCurrent ? Self.amberMaterial() : (isInstalled || !session.ghostFuture ? Self.metalMaterial() : Self.ghostMaterial())
                node.isHidden = session.isolate && !isCurrent
                let offset = session.exploded ? explosionOffset(for: id) : Vec3.zero
                node.position = vec(offset)
            }
            updateArrow(in: root, currentIDs: currentIDs)
            if !session.exploded { playInsertion(root: root, currentIDs: currentIDs) }
            updateSectionPlane(in: root, visible: session.sectionView)
            updateCamera(scene: scene, animated: session.animateCamera)
            session.animateCamera = false
        }

        private func node(for part: BuiltPart) -> SCNNode {
            var positions: [SCNVector3] = [], normals: [SCNVector3] = []
            for point in part.mesh.positions { positions.append(vec(point)) }
            for normal in part.mesh.normals { normals.append(vec(normal)) }
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                elements: [SCNGeometryElement(indices: part.mesh.indices.map { Int32($0) }, primitiveType: .triangles)])
            geometry.firstMaterial = Self.metalMaterial()
            let node = SCNNode(geometry: geometry)
            node.name = "part-\(part.partID.uuidString)"
            return node
        }

        private func explosionOffset(for partID: UUID) -> Vec3 {
            guard let part = session.builtParts.first(where: { $0.partID == partID }) else { return .zero }
            return part.explodeDirection * (session.modelExtent * 0.38)
        }

        private func updateArrow(in root: SCNNode, currentIDs: Set<UUID>) {
            var arrow = root.childNode(withName: "arrow", recursively: false)
            if arrow == nil {
                arrow = Self.makeArrow()
                root.addChildNode(arrow!)
            }
            guard let arrowNode = arrow else { return }
            let first = session.builtParts.first(where: { currentIDs.contains($0.partID) })
            guard let part = first else {
                arrowNode.isHidden = true
                return
            }
            arrowNode.isHidden = false
            let direction = part.explodeDirection.normalized() ?? Vec3(x: 0, y: 1, z: 0)
            let center = (part.start + part.end) * 0.5
            let standOff = session.modelExtent * 0.30 + (session.exploded ? session.modelExtent * 0.38 : 0)
            let anchor = center + direction * standOff
            let target = center + direction * (standOff * 0.4)
            arrowNode.position = vec(anchor)
            arrowNode.look(at: vec(target), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        }

        private static func makeArrow() -> SCNNode {
            let amber = SCNMaterial()
            amber.lightingModel = .constant
            amber.diffuse.contents = UIColor(Theme.accent)
            amber.emission.contents = UIColor(Theme.accent)
            let shaft = SCNCylinder(radius: 5, height: 55)
            shaft.materials = [amber]
            let shaftNode = SCNNode(geometry: shaft)
            shaftNode.position = SCNVector3(0, -8, 0)
            let tip = SCNCone(topRadius: 0, bottomRadius: 11, height: 32)
            tip.materials = [amber]
            let tipNode = SCNNode(geometry: tip)
            tipNode.position = SCNVector3(0, 28, 0)
            let group = SCNNode()
            group.name = "arrow"
            group.addChildNode(shaftNode)
            group.addChildNode(tipNode)
            return group
        }

        private func updateSectionPlane(in root: SCNNode, visible: Bool) {
            var plane = root.childNode(withName: "sectionPlane", recursively: false)
            if plane == nil {
                let geometry = SCNPlane(width: 1, height: 1)
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = UIColor(Theme.accent.opacity(0.14))
                material.isDoubleSided = true
                geometry.materials = [material]
                let node = SCNNode(geometry: geometry)
                node.name = "sectionPlane"
                node.eulerAngles = SCNVector3(0, Float.pi / 2, 0)
                root.addChildNode(node)
                plane = node
            }
            guard let planeNode = plane else { return }
            planeNode.isHidden = !visible
            let size = Float(session.modelExtent * 1.25)
            planeNode.scale = SCNVector3(size, size, 1)
            planeNode.position = vec(session.modelCenter)
        }

        private func updateLights(scene: SCNScene) {
            let extent = max(session.modelExtent, 400)
            scene.rootNode.childNode(withName: "keyLight", recursively: false)?.position =
                SCNVector3(session.modelCenter.x + extent, session.modelCenter.y + extent * 1.2, session.modelCenter.z + extent * 1.3)
            scene.rootNode.childNode(withName: "fillLight", recursively: false)?.position =
                SCNVector3(session.modelCenter.x - extent, session.modelCenter.y + extent * 0.4, session.modelCenter.z - extent)
        }

        private func updateCamera(scene: SCNScene, animated: Bool) {
            guard let cameraNode = scene.rootNode.childNode(withName: "camera", recursively: false) else { return }
            let target = session.modelCenter + session.panOffset
            let distance = max(session.modelExtent, 500) * 2.1 * session.distanceFactor
            let yaw = session.yawDeg * .pi / 180
            let pitch = session.pitchDeg * .pi / 180
            let direction = Vec3(x: sin(yaw) * cos(pitch), y: sin(pitch), z: cos(yaw) * cos(pitch))
            let position = vec(target + direction * distance)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.45 : 0
            cameraNode.position = position
            cameraNode.look(at: vec(target), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            SCNTransaction.commit()
        }

        /// Einsetzen animieren: Bauteile des aktuellen Schritts starten versetzt in
        /// ihre Bewegungsrichtung und gleiten in Position, wenn der Schritt wechselt.
        private func playInsertion(root: SCNNode, currentIDs: Set<UUID>) {
            let key = "\(session.stepIndex)-\(session.replayToken)"
            guard key != lastStepKey else { return }
            lastStepKey = key
            let nodes = root.childNodes.filter { node in
                guard let text = node.name?.dropFirst(5) else { return false }
                return currentIDs.contains(UUID(uuidString: String(text)) ?? UUID())
            }
            guard !nodes.isEmpty else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            for node in nodes {
                guard let text = node.name?.dropFirst(5), let id = UUID(uuidString: String(text)),
                      let part = session.builtParts.first(where: { $0.partID == id }) else { continue }
                let direction = part.explodeDirection.normalized() ?? Vec3(x: 0, y: 1, z: 0)
                node.position = vec(direction * (session.modelExtent * 0.55))
            }
            SCNTransaction.commit()
            DispatchQueue.main.async {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.9
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for node in nodes { node.position = SCNVector3(0, 0, 0) }
                SCNTransaction.commit()
            }
        }

        private static func metalMaterial() -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = UIColor(white: 0.78, alpha: 1)
            material.metalness.contents = 0.85
            material.roughness.contents = 0.32
            return material
        }

        private static func amberMaterial() -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = UIColor(Theme.accent)
            material.metalness.contents = 0.6
            material.roughness.contents = 0.3
            material.emission.contents = UIColor(Theme.accent.opacity(0.35))
            return material
        }

        private static func ghostMaterial() -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor(white: 0.75, alpha: 0.16)
            material.transparency = 0.16
            return material
        }
    }
}

private func vec(_ v: Vec3) -> SCNVector3 {
    SCNVector3(Float(v.x), Float(v.y), Float(v.z))
}
