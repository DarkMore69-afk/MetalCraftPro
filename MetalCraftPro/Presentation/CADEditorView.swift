import SwiftUI

// MARK: - Editor-Session

/// Zustand und Befehle des 2D-CAD-Editors. Alle Änderungen laufen über den
/// Undo/Redo-Verlauf und werden sofort im Projekt persistiert (Autosave).
@MainActor
@Observable
final class CADSession {
    enum Tool: String, CaseIterable {
        case select, line, rectangle, circle, arc, profile, hole, holePattern, dimension, angle
        case text, construction, trim, extend, offset, mirror, array

        var title: String {
            switch self {
            case .select: return "Auswahl"
            case .line: return "Linie"
            case .rectangle: return "Rechteck"
            case .circle: return "Kreis"
            case .arc: return "Bogen"
            case .profile: return "Profil"
            case .hole: return "Bohrung"
            case .holePattern: return "Bohrmuster"
            case .dimension: return "Maß"
            case .angle: return "Winkel"
            case .text: return "Text"
            case .construction: return "Hilfslinie"
            case .trim: return "Trim"
            case .extend: return "Extend"
            case .offset: return "Offset"
            case .mirror: return "Mirror"
            case .array: return "Array"
            }
        }

        var hint: String {
            switch self {
            case .select: return "Element antippen zum Auswählen · Maß antippen zum Bearbeiten"
            case .line: return "Startpunkt antippen, dann Endpunkt"
            case .rectangle: return "Erste Ecke antippen, dann Gegenecke"
            case .circle: return "Mittelpunkt antippen, dann Radius"
            case .arc: return "Zentrum, Startpunkt und Endpunkt antippen"
            case .profile: return "Profilverlauf antippen: Startpunkt, dann Endpunkt"
            case .hole: return "Bohrungsmitte antippen, dann Radius"
            case .holePattern: return "Startpunkt des linearen Musters oder Mittelpunkt des Lochkreises antippen"
            case .dimension: return "Von und bis antippen · an der Außenkante wird das Maß parametrisch"
            case .angle: return "Scheitelpunkt und beide Schenkel antippen"
            case .text: return "Position antippen und Text eingeben"
            case .construction: return "Zwei Punkte der Hilfsgeraden antippen"
            case .trim: return "Zu kürzendes Element antippen, dann das Schneiden-Element"
            case .extend: return "Zu verlängerndes Element antippen, dann die Grenze"
            case .offset: return "Linie antippen und Abstand eingeben"
            case .mirror: return "Zuerst Elemente auswählen, dann zwei Achspunkte antippen"
            case .array: return "Zuerst Elemente auswählen, dann Anzahl und Abstand festlegen"
            }
        }

        var requiredPoints: Int {
            switch self {
            case .select, .text, .trim, .extend, .offset, .array, .holePattern: return 0
            case .arc, .angle: return 3
            default: return 2
            }
        }
    }

    let project: MCProject
    let store: LocalStore
    private(set) var drawing: CADDrawing
    var viewport = CADViewport(pxPerMm: 0.28, center: Vec2(x: 600, y: 400))
    var tool: Tool = .select {
        didSet {
            pending = []; trimTarget = nil; snap = nil; snapScreen = nil
            if tool != .holePattern { holePatternDraft = false; holePatternAnchor = nil }
        }
    }
    private(set) var selection: Set<UUID> = []
    private(set) var pending: [Vec2] = []
    private(set) var snap: CADSnap?
    private(set) var snapScreen: CGPoint?
    var message: String?
    var gridEnabled = true
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    // Entwürfe für Alarme und Blätter
    var textDraft: Vec2?
    var offsetDraft: (id: UUID, side: Vec2)?
    var arrayDraft = false
    var dimensionDraft: UUID?
    var holePatternDraft = false
    var holePatternAnchor: Vec2?
    var canvasSize: CGSize = .zero

    private var history = CADHistory()
    private var trimTarget: UUID?
    private var lastDrag: CGSize?
    private var lastMagnification = 1.0
    private var messageTask: Task<Void, Never>?
    private var didFit = false

    init(project: MCProject, store: LocalStore) {
        self.project = project
        self.store = store
        self.drawing = project.cadDrawing ?? CADDrawing()
    }

    var frame: FrameParameters? { project.frameParameters }

    /// Sendbarer Render-Zustand für die Zeichenfläche (isolerungsfrei gezeichnet).
    func makeRenderState() -> CADRenderState {
        CADRenderState(drawing: drawing, selection: selection, viewport: viewport, pending: pending,
                       snap: snap, snapScreen: snapScreen, frameParameters: frame,
                       gridEnabled: gridEnabled,
                       trimHighlight: (tool == .trim || tool == .extend) ? selection.first : nil)
    }

    func fitIfNeeded() {
        guard !didFit, canvasSize.width > 20, canvasSize.height > 20 else { return }
        didFit = true
        let content = frame.map { Vec2(x: $0.width, y: $0.height) } ?? Vec2(x: 1000, y: 1000)
        viewport = .fitted(content: content, marginMm: max(160, max(content.x, content.y) * 0.18), canvas: canvasSize)
    }

    // MARK: Eingabe

    func tap(at screen: CGPoint) {
        guard canvasSize.width > 1 else { return }
        let raw = viewport.worldPoint(screen, canvas: canvasSize)
        let result = drawing.snap(raw: raw, frame: frame, pendingStart: tool.requiredPoints > 0 && !pending.isEmpty ? pending.last : nil,
                                  pxPerMm: viewport.pxPerMm, tolerancePt: 22, gridMm: 50, gridEnabled: gridEnabled)
        let point = result?.point ?? raw
        snap = result
        snapScreen = result == nil ? nil : screen
        handle(point)
    }

    private func handle(_ point: Vec2) {
        switch tool {
        case .select:
            guard let element = hitElement(point) else { selection = []; return }
            if element.kind == .dimension {
                selection = [element.id]
                dimensionDraft = element.id
            } else if selection.contains(element.id) {
                selection.remove(element.id)
            } else {
                selection.insert(element.id)
            }
        case .text:
            textDraft = point
        case .holePattern:
            holePatternAnchor = point
            holePatternDraft = true
        case .trim, .extend:
            handleTrimExtend(point)
        case .offset:
            guard let element = hitElement(point) else { show("Linie, Profil oder Hilfslinie antippen."); return }
            guard element.kind == .line || element.kind == .profile || element.kind == .construction else {
                show("Offset funktioniert auf Linien, Profilen und Hilfslinien."); return
            }
            offsetDraft = (element.id, point)
        case .mirror:
            guard !selection.isEmpty else { show("Zuerst Elemente mit der Auswahl auswählen."); return }
            pending.append(point)
            if pending.count == 2 {
                let axisA = pending[0], axisB = pending[1]
                let ids = Array(selection)
                commit(label: "Mirror") { CADOperations.mirror($0, ids: ids, axisA: axisA, axisB: axisB) }
                pending = []
                selection = []
            }
        case .array:
            guard !selection.isEmpty else { show("Zuerst Elemente mit der Auswahl auswählen."); return }
            arrayDraft = true
        default:
            pending.append(point)
            if pending.count == tool.requiredPoints { buildPendingElement() }
        }
    }

    private func handleTrimExtend(_ point: Vec2) {
        guard let element = hitElement(point) else { show("Element antippen."); return }
        if trimTarget == nil {
            if tool == .trim, element.kind != .line, element.kind != .profile {
                show("Trim kürzt Linien und Profile."); return
            }
            if tool == .extend, element.kind != .line, element.kind != .profile {
                show("Extend verlängert Linien und Profile."); return
            }
            trimTarget = element.id
            selection = [element.id]
            return
        }
        let targetID = trimTarget!
        guard element.id != targetID else { return }
        if tool == .trim {
            guard element.kind == .line || element.kind == .profile || element.kind == .construction || element.kind == .circle || element.kind == .hole else {
                show("Schneiden-Element antippen."); return
            }
            commit(label: "Trim") { CADOperations.trim($0, targetID: targetID, cutterID: element.id, tap: point) }
        } else {
            guard element.kind == .line || element.kind == .profile || element.kind == .construction else {
                show("Grenz-Element antippen."); return
            }
            commit(label: "Extend") { CADOperations.extend($0, targetID: targetID, boundaryID: element.id, tap: point) }
        }
        trimTarget = nil
        selection = []
    }

    private func buildPendingElement() {
        let points = pending
        pending = []
        let label: String
        let element: CADElement?
        switch tool {
        case .line:
            label = "Linie"; element = CADFactory.line(points[0], points[1])
        case .rectangle:
            label = "Rechteck"; element = CADFactory.rectangle(points[0], points[1])
        case .circle:
            label = "Kreis"; element = CADFactory.circle(center: points[0], radiusPoint: points[1])
        case .hole:
            label = "Bohrung"
            element = points[0].distance(to: points[1]) >= 0.5 ? CADFactory.hole(center: points[0], radiusPoint: points[1]) : nil
            if element == nil { show("Bohrung zu klein (mindestens 0,5 mm Radius).") }
        case .arc:
            label = "Bogen"
            element = points[0].distance(to: points[1]) > 1e-6 ? CADFactory.arc(center: points[0], start: points[1], end: points[2]) : nil
            if element == nil { show("Startpunkt liegt im Zentrum.") }
        case .profile:
            label = "Profil"
            element = CADFactory.profile(points[0], points[1], widthMm: frame?.profile.heightMm ?? 40)
        case .construction:
            label = "Hilfslinie"; element = CADFactory.construction(points[0], points[1])
        case .dimension:
            label = "Maß"; element = dimensionElement(from: points[0], to: points[1])
        case .angle:
            label = "Winkel"; element = CADFactory.angle(vertex: points[0], first: points[1], second: points[2])
        default: return
        }
        guard let element else { return }
        commit(label: label) { current in
            var copy = current
            do { try copy.add(element) } catch { return nil }
            return copy
        }
    }

    /// Ein Maß, das die Außenkante des Rahmens aufspannt, wird parametrisch:
    /// Sein Wert kommt fortan aus den Projektparametern (Single Source of Truth).
    private func dimensionElement(from a: Vec2, to b: Vec2) -> CADElement {
        let horizontal = abs(a.y - b.y) <= abs(a.x - b.x)
        if let frame {
            let tolerance = 0.6
            if horizontal, abs(a.x) < tolerance, abs(b.x - frame.width) < tolerance, abs(a.y - b.y) < tolerance,
               abs(a.y) < tolerance || abs(a.y - frame.height) < tolerance {
                let above = abs(a.y - frame.height) < tolerance
                return CADFactory.parametricDimension(key: "width", anchor: Vec2(x: frame.width / 2, y: a.y + (above ? 40 : -40)))
            }
            if !horizontal, abs(a.y) < tolerance, abs(b.y - frame.height) < tolerance, abs(a.x - b.x) < tolerance,
               abs(a.x) < tolerance || abs(a.x - frame.width) < tolerance {
                let right = abs(a.x - frame.width) < tolerance
                return CADFactory.parametricDimension(key: "height", anchor: Vec2(x: a.x + (right ? 40 : -40), y: frame.height / 2))
            }
        }
        let length = a.distance(to: b)
        guard length > 1e-9 else { return CADFactory.dimension(from: a, to: b, linePoint: Vec2(x: a.x, y: a.y + 40)) }
        let unit = (b - a) * (1 / length)
        var normal = Vec2(x: -unit.y, y: unit.x)
        if normal.y < 0 && abs(unit.y) < abs(unit.x) { normal = normal * -1 }
        if abs(unit.y) >= abs(unit.x) && normal.x > 0 { normal = normal * -1 }
        let midpoint = Vec2(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return CADFactory.dimension(from: a, to: b, linePoint: midpoint + normal * 40)
    }

    func hitElement(_ point: Vec2) -> CADElement? {
        let tolerance = 16 / max(1e-9, viewport.pxPerMm)
        var best: (element: CADElement, distance: Double)?
        for element in drawing.elements {
            let distance = element.distance(to: point)
            if distance <= tolerance, best == nil || distance < best!.distance { best = (element, distance) }
        }
        return best?.element
    }

    // MARK: Commit, Undo, Persistenz

    @discardableResult
    func commit(label: String, _ transform: (CADDrawing) -> CADDrawing?) -> Bool {
        guard let after = transform(drawing) else { show("Ungültige Geometrie wurde verworfen."); return false }
        history.record(CADHistoryEntry(label: label, drawingBefore: drawing, drawingAfter: after))
        drawing = after
        persist()
        return true
    }

    func commitParameter(key: String, value: Double, label: String) {
        let oldWidth = project.widthMm, oldHeight = project.heightMm
        do { try store.setFrameParameter(project, key: key, value: value) }
        catch { show(error.localizedDescription); return }
        history.record(CADHistoryEntry(label: label, drawingBefore: drawing, drawingAfter: drawing,
                                       widthBefore: key == "width" ? oldWidth : nil,
                                       widthAfter: key == "width" ? value : nil,
                                       heightBefore: key == "height" ? oldHeight : nil,
                                       heightAfter: key == "height" ? value : nil))
        show("Parametrisch geändert: Zeichnung, Bauteile und Zuschnitt folgen.")
    }

    func undo() {
        guard let entry = history.undo() else { return }
        drawing = entry.drawingBefore
        applyParameter(entry.widthBefore, key: "width")
        applyParameter(entry.heightBefore, key: "height")
        selection = []
        persist()
    }

    func redo() {
        guard let entry = history.redo() else { return }
        drawing = entry.drawingAfter
        applyParameter(entry.widthAfter, key: "width")
        applyParameter(entry.heightAfter, key: "height")
        selection = []
        persist()
    }

    private func applyParameter(_ value: Double?, key: String) {
        guard let value else { return }
        let width = key == "width" ? value : project.widthMm
        let height = key == "height" ? value : project.heightMm
        guard (try? FrameParameters(width: width, height: height, profile: project.profileSpec)) != nil else { return }
        if key == "width" { project.widthMm = value } else { project.heightMm = value }
    }

    private func persist() {
        project.cadDrawing = drawing
        do { try store.persistDrawing(project) } catch { show("Nicht gespeichert: \(error.localizedDescription)") }
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        commit(label: "Löschen") { current in
            var copy = current
            copy.remove(ids: ids)
            return copy.elements.count < current.elements.count ? copy : nil
        }
        selection = []
    }

    func commitText(_ content: String) {
        guard let position = textDraft else { return }
        textDraft = nil
        commit(label: "Text") { current in
            var copy = current
            do { try copy.add(CADFactory.text(position, content)) } catch { return nil }
            return copy
        }
    }

    func commitOffset(distanceMm: Double) {
        guard let draft = offsetDraft else { return }
        offsetDraft = nil
        commit(label: "Offset") { CADOperations.offset($0, id: draft.id, distanceMm: distanceMm, side: draft.side) }
    }

    func commitArray(count: Int, dx: Double, dy: Double) {
        guard arrayDraft, !selection.isEmpty else { return }
        arrayDraft = false
        let ids = Array(selection)
        commit(label: "Array") { CADOperations.linearArray($0, ids: ids, count: count, dx: dx, dy: dy) }
        selection = []
    }

    @discardableResult
    func commitHolePattern(kind: CADHolePatternKind, count: Int, spacingMm: Double,
                           pitchCircleDiameterMm: Double, startAngleDeg: Double,
                           holeDiameterMm: Double) -> Bool {
        guard let anchor = holePatternAnchor else { return false }
        let oldIDs = Set(drawing.elements.map(\.id))
        let accepted = commit(label: kind == .linear ? "Lineares Bohrmuster" : "Kreisförmiges Bohrmuster") {
            CADOperations.drillPattern($0, center: anchor, kind: kind, count: count,
                                       spacingMm: spacingMm, pitchCircleDiameterMm: pitchCircleDiameterMm,
                                       startAngleDeg: startAngleDeg, holeDiameterMm: holeDiameterMm)
        }
        guard accepted else { return false }
        selection = Set(drawing.elements.lazy.filter { !oldIDs.contains($0.id) }.map(\.id))
        holePatternDraft = false
        holePatternAnchor = nil
        return true
    }

    func commitDimensionEdit(valueMm: Double) {
        guard let id = dimensionDraft, let element = drawing.element(with: id) else { return }
        dimensionDraft = nil
        if let key = element.parameterKey {
            commitParameter(key: key, value: valueMm, label: "Maß angepasst")
        } else {
            commit(label: "Maß angepasst") { current in
                CADOperations.dimensionEdit(current, dimensionID: id, newValueMm: valueMm)?.drawing
            }
        }
    }

    // MARK: Navigation

    func dragChanged(_ translation: CGSize) {
        defer { lastDrag = translation }
        guard let last = lastDrag else { snap = nil; snapScreen = nil; return }
        viewport.pan(screenDelta: CGSize(width: translation.width - last.width, height: translation.height - last.height))
    }

    func dragEnded() { lastDrag = nil }

    func magnifyChanged(magnification: Double) {
        defer { lastMagnification = magnification }
        let delta = magnification / max(1e-9, lastMagnification)
        guard delta.isFinite, abs(delta - 1) > 1e-6 else { return }
        let anchor = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        viewport.zoom(factor: delta, anchor: anchor, canvas: canvasSize)
    }

    func magnifyEnded() { lastMagnification = 1 }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.message = nil }
        }
    }
}

/// Sendbarer Render-Zustand: wird je Bildaktualisierung aus der Session gelesen.
struct CADRenderState: Sendable {
    var drawing: CADDrawing
    var selection: Set<UUID>
    var viewport: CADViewport
    var pending: [Vec2]
    var snap: CADSnap?
    var snapScreen: CGPoint?
    var frameParameters: FrameParameters?
    var gridEnabled: Bool
    var trimHighlight: UUID?
}

// MARK: - Ansicht

struct CADEditorView: View {
    @State private var session: CADSession
    @State private var textEntry = ""
    @State private var offsetEntry = ""
    @State private var arrayCount = "3"
    @State private var arrayDX = "500"
    @State private var arrayDY = "0"
    @State private var dimensionEntry = ""
    @State private var holePatternKind: CADHolePatternKind = .linear
    @State private var holePatternCount = "4"
    @State private var holePatternSpacing = "40"
    @State private var holePatternPitchCircle = "80"
    @State private var holePatternAngle = "0"
    @State private var holePatternDiameter = "8"
    @State private var holePatternProblem: String?

    init(project: MCProject, store: LocalStore) {
        _session = State(initialValue: CADSession(project: project, store: store))
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()
            CADCanvasView(session: session)
            CADChrome(session: session, project: session.project)
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert("Text platzieren", isPresented: Binding(
            get: { session.textDraft != nil },
            set: { if !$0 { session.textDraft = nil } })) {
            TextField("Beschriftung", text: $textEntry)
            Button("Einfügen") { session.commitText(textEntry); textEntry = "" }
            Button("Abbrechen", role: .cancel) { session.textDraft = nil; textEntry = "" }
        }
        .alert("Offset-Abstand", isPresented: Binding(
            get: { session.offsetDraft != nil },
            set: { if !$0 { session.offsetDraft = nil } })) {
            TextField("Abstand in mm", text: $offsetEntry).keyboardType(.decimalPad)
            Button("Offset erstellen") {
                if let distance = DeFormat.parse(offsetEntry), distance > 0 { session.commitOffset(distanceMm: distance) }
                else { session.message = "Bitte einen positiven Abstand eingeben." }
                offsetEntry = ""
            }
            Button("Abbrechen", role: .cancel) { session.offsetDraft = nil; offsetEntry = "" }
        } message: { Text("Parallele Kopie auf der Seite des angetippten Elements.") }
        .alert("Maß anpassen", isPresented: Binding(
            get: { session.dimensionDraft != nil },
            set: { if !$0 { session.dimensionDraft = nil } })) {
            TextField("Wert in mm", text: $dimensionEntry).keyboardType(.decimalPad)
            Button("Übernehmen") {
                if let value = DeFormat.parse(dimensionEntry), value > 0 { session.commitDimensionEdit(valueMm: value) }
                else { session.message = "Bitte einen gültigen Wert eingeben." }
            }
            Button("Abbrechen", role: .cancel) { session.dimensionDraft = nil }
        } message: {
            if let id = session.dimensionDraft, let element = session.drawing.element(with: id), element.parameterKey != nil {
                Text("Parametrisches Maß: ändert Breite bzw. Höhe des Projekts. Zeichnung, Bauteile und Zuschnitt folgen automatisch.")
            } else {
                Text("Freies Maß: der Endpunkt und zusammenfallende Geometrie-Endpunkte werden deterministisch verschoben.")
            }
        }
        .sheet(isPresented: Binding(
            get: { session.arrayDraft || session.holePatternDraft },
            set: { if !$0 { session.arrayDraft = false; session.holePatternDraft = false; session.holePatternAnchor = nil } })) {
            if session.holePatternDraft { holePatternSheet } else { arraySheet }
        }
        .onChange(of: session.dimensionDraft) { _, id in
            guard let id, let element = session.drawing.element(with: id), let value = element.dimensionValue(frame: session.frame) else { return }
            dimensionEntry = DeFormat.number(value, maxFractionDigits: 3)
        }
    }

    private var holePatternSheet: some View {
        NavigationStack {
            Form {
                Section("Anordnung") {
                    Picker("Musterart", selection: $holePatternKind) {
                        ForEach(CADHolePatternKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Anzahl Bohrungen", text: $holePatternCount).keyboardType(.numberPad)
                    if holePatternKind == .linear {
                        TextField("Abstand Mitte–Mitte (mm)", text: $holePatternSpacing).keyboardType(.decimalPad)
                    } else {
                        TextField("Lochkreisdurchmesser (mm)", text: $holePatternPitchCircle).keyboardType(.decimalPad)
                    }
                    TextField("Startwinkel (°)", text: $holePatternAngle).keyboardType(.decimalPad)
                }
                Section("Bohrung") {
                    TextField("Durchmesser (mm)", text: $holePatternDiameter).keyboardType(.decimalPad)
                    Text("Der angetippte Punkt ist beim linearen Muster die Mitte der ersten Bohrung, beim Lochkreis der Kreismittelpunkt.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let holePatternProblem {
                    Section { Label(holePatternProblem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Button("Bohrmuster erstellen") { createHolePattern() }
                        .font(.headline)
                    Button("Abbrechen", role: .cancel) {
                        session.holePatternDraft = false
                        session.holePatternAnchor = nil
                    }
                }
            }
            .navigationTitle("Bohrmuster")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func createHolePattern() {
        guard let count = Int(holePatternCount), (2...500).contains(count),
              let angle = DeFormat.parse(holePatternAngle), angle.isFinite,
              let diameter = DeFormat.parse(holePatternDiameter), diameter >= 1 else {
            holePatternProblem = "Gib 2–500 Bohrungen, einen gültigen Startwinkel und einen Durchmesser ab 1 mm ein."
            return
        }
        let spacing = DeFormat.parse(holePatternSpacing) ?? 0
        let pitchCircle = DeFormat.parse(holePatternPitchCircle) ?? 0
        if holePatternKind == .linear, spacing <= 0 {
            holePatternProblem = "Der Abstand muss größer als 0 mm sein."
            return
        }
        if holePatternKind == .circular, pitchCircle <= 0 {
            holePatternProblem = "Der Lochkreisdurchmesser muss größer als 0 mm sein."
            return
        }
        if session.commitHolePattern(kind: holePatternKind, count: count, spacingMm: spacing,
                                     pitchCircleDiameterMm: pitchCircle, startAngleDeg: angle,
                                     holeDiameterMm: diameter) {
            holePatternProblem = nil
        }
    }

    private var arraySheet: some View {
        NavigationStack {
            Form {
                Section("Lineares Array") {
                    TextField("Anzahl (gesamt)", text: $arrayCount).keyboardType(.numberPad)
                    TextField("Abstand X (mm)", text: $arrayDX).keyboardType(.decimalPad)
                    TextField("Abstand Y (mm)", text: $arrayDY).keyboardType(.decimalPad)
                }
                Section {
                    Button("Array erstellen") {
                        guard let count = Int(arrayCount), count >= 2,
                              let dx = DeFormat.parse(arrayDX), let dy = DeFormat.parse(arrayDY) else {
                            session.message = "Anzahl ab 2 und gültige Abstände eingeben."; return
                        }
                        session.commitArray(count: count, dx: dx, dy: dy)
                    }
                    Button("Abbrechen", role: .cancel) { session.arrayDraft = false }
                }
            }
            .navigationTitle("Array").navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Zeichenfläche

struct CADCanvasView: View {
    let session: CADSession

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let state = session.makeRenderState()
            Canvas { context, _ in
                CADRenderer.draw(context: context, size: size, state: state)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in session.tap(at: value.location) })
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { session.dragChanged($0.translation) }
                    .onEnded { _ in session.dragEnded() }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in session.magnifyChanged(magnification: value.magnification) }
                    .onEnded { _ in session.magnifyEnded() }
            )
            .onAppear { session.canvasSize = size; session.fitIfNeeded() }
            .onChange(of: size) { _, newSize in session.canvasSize = newSize; session.fitIfNeeded() }
        }
    }
}

// MARK: - Renderer (rein, ohne Sitzungszugriff)

enum CADRenderer {
    static func draw(context: GraphicsContext, size: CGSize, state: CADRenderState) {
        let viewport = state.viewport
        let white = Color(white: 0.93)
        let amber = Theme.accent
        let screen = { (point: Vec2) in viewport.screenPoint(point, canvas: size) }

        drawGrid(context: context, size: size, state: state)
        drawFrameLayer(context: context, state: state, screen: screen, white: white)
        for element in state.drawing.elements {
            let selected = state.selection.contains(element.id)
            drawElement(context: context, element: element, screen: screen, white: white, amber: amber,
                        selected: selected, viewport: viewport, frame: state.frameParameters)
        }
        drawPending(context: context, state: state, screen: screen, amber: amber)
        drawSnapIndicator(context: context, state: state, amber: amber)
    }

    private static func dot(_ center: CGPoint, _ radius: Double) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return path
    }

    private static func drawGrid(context: GraphicsContext, size: CGSize, state: CADRenderState) {
        guard state.gridEnabled else { return }
        let viewport = state.viewport
        var gridMm = 50.0
        while gridMm * viewport.pxPerMm < 11 { gridMm *= 2 }
        let topLeft = viewport.worldPoint(.zero, canvas: size)
        let bottomRight = viewport.worldPoint(CGPoint(x: size.width, y: size.height), canvas: size)
        var x = (topLeft.x / gridMm).rounded(.down) * gridMm
        let maxY = topLeft.y
        while x <= bottomRight.x {
            var y = (bottomRight.y / gridMm).rounded(.down) * gridMm
            while y <= maxY {
                let point = viewport.screenPoint(Vec2(x: x, y: y), canvas: size)
                if point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height {
                    context.fill(dot(point, 1.1), with: .color(.white.opacity(0.13)))
                }
                y += gridMm
            }
            x += gridMm
        }
    }

    /// Abgeleitete Ebene: Rahmenkonturen aus den Parametern plus Kontroll-Diagonale.
    private static func drawFrameLayer(context: GraphicsContext, state: CADRenderState, screen: (Vec2) -> CGPoint, white: Color) {
        guard let frame = state.frameParameters else { return }
        let viewport = state.viewport
        for contour in [frame.outerContour, frame.innerContour] {
            if case .rectangle(let origin, let width, let height) = contour {
                let topLeft = screen(Vec2(x: origin.x, y: origin.y + height))
                let rect = CGRect(x: topLeft.x, y: topLeft.y, width: width * viewport.pxPerMm, height: height * viewport.pxPerMm)
                context.stroke(Path(rect), with: .color(white), lineWidth: 1.6)
            }
        }
        let start = screen(Vec2.zero), end = screen(Vec2(x: frame.width, y: frame.height))
        var diagonal = Path()
        diagonal.move(to: start)
        diagonal.addLine(to: end)
        context.stroke(diagonal, with: .color(white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        let angle = atan2(end.y - start.y, end.x - start.x)
        var textAngle = angle
        if textAngle > .pi / 2 || textAngle < -.pi / 2 { textAngle += .pi }
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let value = DeFormat.number((frame.width * frame.width + frame.height * frame.height).squareRoot(), maxFractionDigits: 1)
        let resolved = context.resolve(Text(value).font(.system(size: 12, weight: .medium)).foregroundColor(white.opacity(0.85)))
        var transformed = context
        transformed.transform = context.transform
            .translatedBy(x: mid.x, y: mid.y - 10)
            .rotated(by: textAngle)
        transformed.draw(resolved, at: .zero, anchor: .center)
    }

    private static func drawElement(context: GraphicsContext, element: CADElement, screen: (Vec2) -> CGPoint,
                                    white: Color, amber: Color, selected: Bool, viewport: CADViewport, frame: FrameParameters?) {
        let color = selected ? amber : (element.kind == .construction ? Color(white: 0.62) : white)
        let style = StrokeStyle(lineWidth: selected ? 2.6 : 1.6, lineCap: .round)
        switch element.kind {
        case .line, .profile:
            if element.kind == .profile, let width = element.profileWidthMm, width > 0,
               let unit = try? (element.b - element.a).normalized() {
                let normal = Vec2(x: -unit.y, y: unit.x) * (width / 2)
                for offset in [normal, normal * -1] {
                    context.stroke(linePath(screen(element.a + offset), screen(element.b + offset)), with: .color(color), style: style)
                }
                for endpoint in [element.a, element.b] {
                    context.stroke(linePath(screen(endpoint + normal), screen(endpoint + normal * -1)), with: .color(color), style: style)
                }
                context.stroke(linePath(screen(element.a), screen(element.b)), with: .color(color.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            } else {
                context.stroke(linePath(screen(element.a), screen(element.b)), with: .color(color), style: style)
            }
        case .rectangle:
            let minC = Vec2(x: min(element.a.x, element.b.x), y: min(element.a.y, element.b.y))
            let maxC = Vec2(x: max(element.a.x, element.b.x), y: max(element.a.y, element.b.y))
            let topLeft = screen(Vec2(x: minC.x, y: maxC.y))
            let rect = CGRect(x: topLeft.x, y: topLeft.y, width: (maxC.x - minC.x) * viewport.pxPerMm, height: (maxC.y - minC.y) * viewport.pxPerMm)
            context.stroke(Path(rect), with: .color(color), style: style)
        case .circle, .hole:
            guard let radius = element.radius, radius > 0 else { break }
            let center = screen(element.a)
            let radiusPx = radius * viewport.pxPerMm
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radiusPx, y: center.y - radiusPx, width: radiusPx * 2, height: radiusPx * 2)),
                           with: .color(color), style: style)
            let cross = radiusPx * 0.4 + 3
            context.stroke(linePath(CGPoint(x: center.x - cross, y: center.y), CGPoint(x: center.x + cross, y: center.y)),
                           with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1))
            context.stroke(linePath(CGPoint(x: center.x, y: center.y - cross), CGPoint(x: center.x, y: center.y + cross)),
                           with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1))
            if element.kind == .hole {
                let label = "Ø\(DeFormat.number(radius * 2, maxFractionDigits: 1))"
                let resolved = context.resolve(Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(color))
                context.draw(resolved, at: CGPoint(x: center.x, y: center.y - radiusPx - 10), anchor: .center)
            }
        case .arc:
            guard let radius = element.radius, radius > 0, let c = element.c else { break }
            let center = screen(element.a)
            let radiusPx = radius * viewport.pxPerMm
            let startAngle = atan2(element.b.y - element.a.y, element.b.x - element.a.x)
            let endAngle = atan2(c.y - element.a.y, c.x - element.a.x)
            let sweep = (try? Geometry2D.arcSweep(start: startAngle * 180 / .pi, end: endAngle * 180 / .pi)) ?? 0
            var path = Path()
            path.addArc(center: center, radius: radiusPx,
                        startAngle: .radians(startAngle),
                        endAngle: .radians(startAngle + sweep * .pi / 180), clockwise: false)
            context.stroke(path, with: .color(color), style: style)
        case .construction:
            let direction = element.b - element.a
            let length = direction.magnitude
            if length > 1e-9 {
                let unit = direction * (1 / length)
                context.stroke(linePath(screen(element.a - unit * length * 1.5), screen(element.b + unit * length * 1.5)),
                               with: .color(color), style: StrokeStyle(lineWidth: 1.1, dash: [7, 5]))
            }
        case .text:
            let resolved = context.resolve(Text(element.text ?? "").font(.system(size: 13, weight: .medium)).foregroundColor(color))
            context.draw(resolved, at: screen(element.a), anchor: .center)
        case .dimension:
            drawDimension(context: context, element: element, screen: screen, color: color, selected: selected, frame: frame)
        case .angle:
            drawAngle(context: context, element: element, screen: screen, color: color, selected: selected)
        }
        if selected {
            for point in element.keyPoints {
                context.fill(dot(screen(point), 3.5), with: .color(amber))
            }
        }
    }

    private static func drawDimension(context: GraphicsContext, element: CADElement, screen: (Vec2) -> CGPoint,
                                      color: Color, selected: Bool, frame: FrameParameters?) {
        guard let endpoints = element.dimensionEndpoints(frame: frame) else { return }
        let style = StrokeStyle(lineWidth: selected ? 2 : 1.1, lineCap: .round)
        let a = endpoints.from, b = endpoints.to, linePoint = endpoints.linePoint
        let length = a.distance(to: b)
        guard length > 1e-9, let unit = try? (b - a).normalized() else { return }
        let normal = Vec2(x: -unit.y, y: unit.x)
        let projection = (linePoint - a).dot(unit)
        let lineA = a + unit * projection
        let lineB = b + unit * projection
        for (point, foot) in [(a, lineA), (b, lineB)] {
            let start = screen(point + (foot - point) * 0.06)
            let extensionDirection = foot - point
            let extensionLength = max(1e-9, extensionDirection.magnitude)
            let end = screen(foot + extensionDirection * (4 / extensionLength))
            context.stroke(linePath(start, end), with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1))
        }
        context.stroke(linePath(screen(lineA), screen(lineB)), with: .color(color), style: style)
        // Schrägstriche an den Enden (werkstattübliche Maßpfeile)
        let tick = Vec2(x: unit.x + normal.x, y: unit.y + normal.y)
        for endpoint in [lineA, lineB] {
            let position = screen(endpoint)
            let half = 5.0
            context.stroke(linePath(CGPoint(x: position.x - tick.x * half, y: position.y + tick.y * half),
                                    CGPoint(x: position.x + tick.x * half, y: position.y - tick.y * half)),
                           with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        if let value = element.dimensionValue(frame: frame) {
            let resolved = context.resolve(Text(DeFormat.number(value, maxFractionDigits: 2))
                .font(.system(size: 13, weight: .semibold)).foregroundColor(color))
            let mid = screen(linePoint)
            context.draw(resolved, at: CGPoint(x: mid.x - normal.x * 11, y: mid.y + normal.y * 11), anchor: .center)
        }
    }

    private static func drawAngle(context: GraphicsContext, element: CADElement, screen: (Vec2) -> CGPoint, color: Color, selected: Bool) {
        guard let c = element.c, let value = element.angleValue() else { return }
        let vertex = screen(element.a)
        let first = atan2(element.b.y - element.a.y, element.b.x - element.a.x)
        let second = atan2(c.y - element.a.y, c.x - element.a.x)
        var delta = second - first
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        let radius = 34.0
        var path = Path()
        path.addArc(center: vertex, radius: radius, startAngle: .radians(first), endAngle: .radians(first + delta), clockwise: delta < 0)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: selected ? 2 : 1.3))
        let bisector = first + delta / 2
        let resolved = context.resolve(Text("\(DeFormat.number(value, maxFractionDigits: 1))°")
            .font(.system(size: 12, weight: .semibold)).foregroundColor(color))
        context.draw(resolved, at: CGPoint(x: vertex.x + cos(bisector) * (radius + 16), y: vertex.y + sin(bisector) * (radius + 16)), anchor: .center)
    }

    private static func drawPending(context: GraphicsContext, state: CADRenderState, screen: (Vec2) -> CGPoint, amber: Color) {
        for point in state.pending {
            let position = screen(point)
            context.stroke(linePath(CGPoint(x: position.x - 9, y: position.y), CGPoint(x: position.x + 9, y: position.y)),
                           with: .color(amber), style: StrokeStyle(lineWidth: 1.6))
            context.stroke(linePath(CGPoint(x: position.x, y: position.y - 9), CGPoint(x: position.x, y: position.y + 9)),
                           with: .color(amber), style: StrokeStyle(lineWidth: 1.6))
        }
        if let target = state.trimHighlight, let element = state.drawing.element(with: target) {
            for point in element.keyPoints {
                context.fill(dot(screen(point), 4), with: .color(amber.opacity(0.7)))
            }
        }
    }

    private static func drawSnapIndicator(context: GraphicsContext, state: CADRenderState, amber: Color) {
        guard let snap = state.snap, let point = state.snapScreen else { return }
        context.stroke(linePath(CGPoint(x: point.x - 12, y: point.y), CGPoint(x: point.x + 12, y: point.y)),
                       with: .color(amber), style: StrokeStyle(lineWidth: 1.5))
        context.stroke(linePath(CGPoint(x: point.x, y: point.y - 12), CGPoint(x: point.x, y: point.y + 12)),
                       with: .color(amber), style: StrokeStyle(lineWidth: 1.5))
        let pillX = point.x + 46, pillY = point.y + 46
        let pill = CGRect(x: pillX, y: pillY, width: 186, height: 50)
        context.fill(Path(roundedRect: pill, cornerRadius: 12), with: .color(Color(white: 0.07).opacity(0.94)))
        context.stroke(Path(roundedRect: pill, cornerRadius: 12), with: .color(.white.opacity(0.16)), lineWidth: 0.8)
        context.stroke(linePath(point, CGPoint(x: pillX + 6, y: pillY + 4)), with: .color(amber.opacity(0.85)), style: StrokeStyle(lineWidth: 1.1))
        let title = context.resolve(Text(snap.kind.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white))
        let coordinates = context.resolve(
            Text("X \(DeFormat.number(snap.point.x, maxFractionDigits: 1)) · Y \(DeFormat.number(snap.point.y, maxFractionDigits: 1))")
                .font(.system(size: 13)).foregroundColor(Color(white: 0.72)))
        context.draw(title, at: CGPoint(x: pillX + 12, y: pillY + 14), anchor: .leading)
        context.draw(coordinates, at: CGPoint(x: pillX + 12, y: pillY + 34), anchor: .leading)
    }

    private static func linePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }
}

// MARK: - Bedienoberfläche

private struct CADChrome: View {
    @Environment(\.dismiss) private var dismiss
    let session: CADSession
    let project: MCProject

    var body: some View {
        VStack(spacing: 0) {
            topBar.padding(.horizontal, 14).padding(.top, 6)
            Spacer()
            HStack(alignment: .bottom) {
                toolPalette
                Spacer()
            }
            hint.padding(.bottom, 14)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 34)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
            .accessibilityLabel("Editor schließen")
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.headline).lineLimit(1)
                Text("\(project.number) · Revision \(project.revisionLabel)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .font(.system(size: 17, weight: .medium))
                .disabled(!session.canUndo)
                .accessibilityLabel("Undo")
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .font(.system(size: 17, weight: .medium))
                .disabled(!session.canRedo)
                .accessibilityLabel("Redo")
            if !session.selection.isEmpty {
                Button { session.deleteSelection() } label: { Image(systemName: "trash") }
                    .font(.system(size: 16, weight: .medium))
                    .tint(.red)
                    .accessibilityLabel("Auswahl löschen")
            }
            Button { session.gridEnabled.toggle() } label: { Image(systemName: "square.grid.3x3") }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(session.gridEnabled ? Theme.accent : Color(white: 0.7))
                .accessibilityLabel("Raster umschalten")
            Text(session.viewport.scaleLabel())
                .font(.subheadline.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var toolPalette: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 7) {
                ForEach(CADSession.Tool.allCases, id: \.self) { tool in
                    Button { session.tool = tool } label: {
                        CADToolIcon(tool: tool, active: session.tool == tool)
                            .frame(width: 46, height: 46)
                            .background(session.tool == tool ? Theme.accent : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
                }
            }
            .padding(7)
        }
        .frame(maxHeight: 400)
        .fixedSize(horizontal: true, vertical: false)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.leading, 14)
    }

    @ViewBuilder
    private var hint: some View {
        if let message = session.message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote.weight(.medium)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 24)
        } else {
            Text(session.tool.hint)
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 24)
        }
    }
}

// MARK: - Werkzeug-Icons

struct CADToolIcon: View {
    let tool: CADSession.Tool
    let active: Bool

    var body: some View {
        Canvas { context, size in
            let color = active ? Color.black : Color(white: 0.85)
            let stroke = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            let w = size.width, h = size.height
            func line(_ a: CGPoint, _ b: CGPoint, dash: [CGFloat]? = nil) {
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                var style = stroke
                if let dash { style.dash = dash }
                context.stroke(path, with: .color(color), style: style)
            }
            func dot(_ point: CGPoint, radius: CGFloat = 2.4) {
                var path = Path()
                path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                context.fill(path, with: .color(color))
            }
            switch tool {
            case .select:
                var path = Path()
                path.move(to: CGPoint(x: w * 0.28, y: h * 0.14))
                path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.78))
                path.addLine(to: CGPoint(x: w * 0.45, y: h * 0.6))
                path.addLine(to: CGPoint(x: w * 0.58, y: h * 0.86))
                path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.8))
                path.addLine(to: CGPoint(x: w * 0.55, y: h * 0.56))
                path.addLine(to: CGPoint(x: w * 0.76, y: h * 0.52))
                path.closeSubpath()
                context.fill(path, with: .color(color))
            case .line:
                line(CGPoint(x: 4, y: h - 5), CGPoint(x: w - 4, y: 5))
                dot(CGPoint(x: 4, y: h - 5)); dot(CGPoint(x: w - 4, y: 5))
            case .rectangle:
                context.stroke(Path(CGRect(x: 4, y: 5, width: w - 8, height: h - 10)), with: .color(color), style: stroke)
            case .circle:
                context.stroke(Path(ellipseIn: CGRect(x: 4, y: 4, width: w - 8, height: h - 8)), with: .color(color), style: stroke)
            case .arc:
                var path = Path()
                path.addArc(center: CGPoint(x: w / 2, y: h * 0.72), radius: w * 0.36,
                            startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                context.stroke(path, with: .color(color), style: stroke)
            case .profile:
                line(CGPoint(x: 3, y: h * 0.36), CGPoint(x: w - 3, y: h * 0.22))
                line(CGPoint(x: 3, y: h * 0.66), CGPoint(x: w - 3, y: h * 0.52))
                line(CGPoint(x: 3, y: h * 0.36), CGPoint(x: 3, y: h * 0.66))
                line(CGPoint(x: w - 3, y: h * 0.22), CGPoint(x: w - 3, y: h * 0.52))
            case .hole:
                context.stroke(Path(ellipseIn: CGRect(x: 4.5, y: 4.5, width: w - 9, height: h - 9)), with: .color(color), style: stroke)
                dot(CGPoint(x: w / 2, y: h / 2), radius: 1.6)
            case .holePattern:
                for index in 0..<3 {
                    let center = CGPoint(x: w * CGFloat(index + 1) / 4, y: h / 2)
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - 4.2, y: center.y - 4.2, width: 8.4, height: 8.4)),
                                   with: .color(color), style: stroke)
                }
            case .dimension:
                line(CGPoint(x: 3, y: h / 2), CGPoint(x: w - 3, y: h / 2))
                line(CGPoint(x: 6, y: h / 2 - 4), CGPoint(x: 10, y: h / 2 + 4))
                line(CGPoint(x: w - 10, y: h / 2 - 4), CGPoint(x: w - 6, y: h / 2 + 4))
            case .angle:
                line(CGPoint(x: 4, y: h - 5), CGPoint(x: w - 4, y: h - 5))
                line(CGPoint(x: 4, y: h - 5), CGPoint(x: w - 6, y: 4))
                var path = Path()
                path.addArc(center: CGPoint(x: 4, y: h - 5), radius: 7, startAngle: .degrees(-55), endAngle: .degrees(0), clockwise: false)
                context.stroke(path, with: .color(color), style: stroke)
            case .text:
                line(CGPoint(x: 4, y: 5), CGPoint(x: w - 4, y: 5))
                line(CGPoint(x: w / 2, y: 5), CGPoint(x: w / 2, y: h - 5))
            case .construction:
                line(CGPoint(x: 3, y: h - 5), CGPoint(x: w - 3, y: 5), dash: [3.5, 3])
            case .trim:
                line(CGPoint(x: 6, y: h - 5), CGPoint(x: w - 6, y: 5))
                line(CGPoint(x: 6, y: 5), CGPoint(x: w - 6, y: h - 5))
                dot(CGPoint(x: 5, y: h - 6), radius: 1.8); dot(CGPoint(x: 5, y: 6), radius: 1.8)
            case .extend:
                line(CGPoint(x: 3, y: h / 2), CGPoint(x: w - 8, y: h / 2))
                line(CGPoint(x: w - 6, y: 4), CGPoint(x: w - 6, y: h - 4))
            case .offset:
                line(CGPoint(x: 4, y: h - 5), CGPoint(x: w - 4, y: h * 0.38))
                line(CGPoint(x: 4, y: h * 0.66), CGPoint(x: w * 0.72, y: 4))
            case .mirror:
                line(CGPoint(x: w / 2, y: 3), CGPoint(x: w / 2, y: h - 3), dash: [3, 3])
                var left = Path()
                left.move(to: CGPoint(x: w / 2 - 3, y: h * 0.3))
                left.addLine(to: CGPoint(x: 3, y: h * 0.5))
                left.addLine(to: CGPoint(x: w / 2 - 3, y: h * 0.7))
                left.closeSubpath()
                context.stroke(left, with: .color(color), style: stroke)
                var right = Path()
                right.move(to: CGPoint(x: w / 2 + 3, y: h * 0.3))
                right.addLine(to: CGPoint(x: w - 3, y: h * 0.5))
                right.addLine(to: CGPoint(x: w / 2 + 3, y: h * 0.7))
                right.closeSubpath()
                context.stroke(right, with: .color(color), style: stroke)
            case .array:
                for dx in [0.0, 1.0] {
                    for dy in [0.0, 1.0] {
                        let rect = CGRect(x: 3 + dx * (w / 2 - 1), y: 4 + dy * (h / 2 - 2), width: w / 2 - 6, height: h / 2 - 6)
                        context.stroke(Path(rect), with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                }
            }
        }
    }
}
