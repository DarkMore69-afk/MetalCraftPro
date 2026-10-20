//
//  SketchReviewView.swift
//  MetalCraft Pro
//
//  Transparenter Prüf-Screen: Das Analyseergebnis wird über dem Foto überlagert,
//  jedes erkannte Element kann einzeln übernommen, korrigiert oder verworfen
//  werden. Unsichere Werte lösen einen Prüfhinweis aus. Erst die Übernahme
//  erzeugt validierte Geometrie.
//

import SwiftUI
import SwiftData

/// Ein anstoßender Import: Bilddaten + Quelle.
struct SketchScanPayload: Identifiable {
    let id = UUID()
    let data: Data
    let source: String
    let sourceLabel: String
}

struct SketchReviewView: View {
    let project: MCProject
    let payload: SketchScanPayload
    /// Archivmodus: gespeicherte Skizze ohne Bearbeitung anzeigen.
    var storedSketch: MCSketch?

    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .analyzing
    @State private var image: UIImage?
    @State private var result: RecognitionResult?
    @State private var editingElement: RecognizedElement?
    @State private var editText = ""
    @State private var problem: String?
    @State private var adoptNote: String?
    @State private var isAdopting = false

    enum Phase: Equatable { case analyzing, review, failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch phase {
            case .analyzing:
                Spacer()
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Skizze wird lokal analysiert …").font(.subheadline).foregroundStyle(.secondary)
                    Text("OCR, Linien und Formen · keine Internetverbindung").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            case .failed(let message):
                Spacer()
                ContentUnavailableView("Analyse nicht möglich", systemImage: "exclamationmark.triangle", description: Text(message))
                Spacer()
            case .review:
                reviewBody
            }
        }
        .background(Theme.appBackground)
        .toolbar(.hidden, for: .navigationBar)
        .task { await analyze() }
        .alert("Maß korrigieren", isPresented: Binding(get: { editingElement != nil }, set: { if !$0 { editingElement = nil } })) {
            TextField(editingElement?.name ?? "Wert", text: $editText).keyboardType(.decimalPad)
            Button("Übernehmen") { commitEdit() }
            Button("Abbrechen", role: .cancel) { editingElement = nil }
        } message: {
            Text("Wert in mm eingeben. Die Geometrie wird erst nach erneuter Prüfung übernommen.")
        }
        .alert("Nicht gespeichert", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .alert("Skizze übernommen", isPresented: Binding(get: { adoptNote != nil }, set: { if !$0 { adoptNote = nil; dismiss() } })) {
            Button("Fertig") { adoptNote = nil; dismiss() }
        } message: { Text(adoptNote ?? "") }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Zurück")
            Text("Skizze prüfen").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
    }

    private var reviewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let image, let result {
                    imageView(image, result: result)
                    elementList
                    uncertaintyBanner
                }
            }
            .frame(maxWidth: 800).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionButtons }
    }

    private func imageView(_ image: UIImage, result: RecognitionResult) -> some View {
        let aspect = result.imageHeightPx > 0 ? result.imageWidthPx / result.imageHeightPx : 1
        return Image(uiImage: image).resizable().scaledToFit().aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 430)
            .overlay { SketchOverlayView(elements: result.elements) }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.6) }
            .accessibilityLabel("Skizzenfoto mit erkannten Elementen")
    }

    private var elementList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Erkannte Elemente").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(Array(result!.elements.enumerated()), id: \.element.id) { index, element in
                ElementRowView(element: element,
                               subtitle: subtitle(for: element),
                               showControls: storedSketch == nil,
                               onToggle: { toggle(index) },
                               onEdit: { beginEdit(element) })
            }
            if result!.elements.isEmpty {
                Label("Keine verwertbaren Elemente erkannt. Bitte das Foto mit besserem Licht und aufrechter Kamera wiederholen.",
                      systemImage: "questionmark.square.dashed").font(.subheadline).foregroundStyle(.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card())
            }
        }
    }

    private var uncertaintyBanner: some View {
        let uncertain = result!.elements.filter { $0.accepted && $0.isUncertain }.count
        return Group {
            if uncertain > 0 {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle").font(.title3).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(uncertain == 1 ? "1 Wert ist unsicher" : "\(uncertain) Werte sind unsicher")
                            .font(.subheadline.weight(.semibold))
                        Text("Fehlende Maße werden nicht ergänzt. Bitte jeden unsicheren Wert prüfen oder abwählen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accent.opacity(0.14)).strokeBorder(Theme.accent.opacity(0.4), lineWidth: 0.8))
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Text("Neu scannen").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }.buttonStyle(.glass).tint(.white)
            if storedSketch == nil {
                Button { adopt() } label: {
                    Text(acceptCount == 1 ? "1 Element übernehmen" : "\(acceptCount) Elemente übernehmen")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                .disabled(acceptCount == 0 || isAdopting)
                .accessibilityIdentifier("adoptSketch")
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: 650)
    }

    // MARK: - Zustand

    private var acceptCount: Int { result?.elements.filter(\.accepted).count ?? 0 }

    private func toggle(_ index: Int) {
        guard let result, storedSketch == nil, result.elements.indices.contains(index) else { return }
        self.result?.elements[index].accepted.toggle()
    }

    private func beginEdit(_ element: RecognizedElement) {
        guard storedSketch == nil, element.kind != .text, element.kind != .line,
              element.kind != .rectangle, element.kind != .circle else { return }
        editText = element.rawText ?? ""
        editingElement = element
    }

    private func commitEdit() {
        defer { editingElement = nil }
        guard let target = editingElement, var updated = result else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let parsed = DimensionTextParser.parse(text) else {
            problem = "Diese Angabe konnte nicht gelesen werden. Erlaubt sind z. B. 1200, 40x40x2, 45°, Ø10, M10."
            return
        }
        guard let index = updated.elements.firstIndex(where: { $0.id == target.id }) else { return }
        updated.elements[index].rawText = text
        updated.elements[index].valueMm = DimensionTextParser.valueMm(of: parsed)
        if case .profile(let w, let h, let t) = parsed { updated.elements[index].profileDimensionsMm = [w, h, t] }
        if case .angleDeg(let value) = parsed { updated.elements[index].angleDeg = value }
        updated.elements[index].confidence = 1
        updated.elements[index].needsReview = false
        updated.elements[index].reviewNote = nil
        // Nach jeder Korrektur wird Zuordnung und Maßstab erneut deterministisch abgeleitet.
        let relinked = SketchGeometryLinker.assign(updated.elements, imageWidthPx: updated.imageWidthPx, imageHeightPx: updated.imageHeightPx)
        let names = SketchGeometryLinker.names(for: relinked.elements)
        var elements = relinked.elements
        for i in elements.indices { elements[i].name = names[elements[i].id] ?? elements[i].name }
        result = RecognitionResult(imageWidthPx: updated.imageWidthPx, imageHeightPx: updated.imageHeightPx,
                                   mmPerPixel: relinked.mmPerPixel, elements: elements)
    }

    private func adopt() {
        guard let result else { return }
        isAdopting = true
        let title = "Skizze \(project.sketches.count + 1)"
        do {
            adoptNote = try store.adoptSketch(project, source: payload.source, title: title,
                                              imageData: payload.data, result: result)
        } catch {
            problem = error.localizedDescription
        }
        isAdopting = false
    }

    private func analyze() async {
        if let storedSketch, let stored = storedSketch.recognition {
            image = SketchImageStore.load(storedSketch.imageFileName)
            result = stored
            phase = .review
            return
        }
        image = UIImage(data: payload.data)
        do {
            let analyzed = try await SketchScanService.analyze(imageData: payload.data)
            result = analyzed
            phase = .review
        } catch {
            phase = .failed("Die lokale Analyse ist fehlgeschlagen. Bitte das Foto erneut aufnehmen.")
        }
    }

    private func subtitle(for element: RecognizedElement) -> String {
        let percent = Int((element.confidence * 100).rounded())
        let confidence = "Konfidenz \(percent) %"
        switch element.kind {
        case .line:
            if let value = element.valueMm { return "Länge \(DeFormat.number(value)) mm · \(confidence)" }
            return "\(confidence) · kein Maß zugeordnet"
        case .rectangle:
            if let value = element.valueMm { return "Kante \(DeFormat.number(value)) mm · \(confidence)" }
            return "\(confidence) · kein Maß zugeordnet"
        case .circle:
            if let value = element.valueMm { return "Bohrung Ø\(DeFormat.number(value)) · \(confidence)" }
            return "\(confidence) · kein Durchmesser erkannt"
        case .length, .diameter, .angle, .profile, .text:
            return confidence
        }
    }
}

// MARK: - Elementzeile

struct ElementRowView: View {
    let element: RecognizedElement
    let subtitle: String
    var showControls: Bool = true
    var onToggle: () -> Void = {}
    var onEdit: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(element.name.isEmpty ? "Element" : element.name).font(.body).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            if showControls && element.isUncertain {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.accent)
                    Text("Bitte prüfen").font(.subheadline).foregroundStyle(Theme.accent)
                    Button(action: onEdit) {
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }.accessibilityLabel("Wert korrigieren")
                }
            } else if element.accepted {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
            } else if showControls {
                Image(systemName: "circle").font(.title3).foregroundStyle(Color(white: 0.45))
            }
        }
        .padding(12)
        .frame(minHeight: 66)
        .background(Theme.card(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture(perform: showControls ? onToggle : {})
        .accessibilityElement(children: .combine)
        .accessibilityHint(showControls ? "Tippen zum Übernehmen oder Verwerfen" : "")
    }

    @ViewBuilder private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.17))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.6) }
            switch element.kind {
            case .line:
                if case .segment(let start, let end)? = element.shape {
                    let horizontal = abs(end.y - start.y) <= abs(end.x - start.x)
                    VStack(spacing: 0) {
                        if horizontal { SegmentGlyph(axis: .horizontal) } else { SegmentGlyph(axis: .vertical) }
                    }
                } else { SegmentGlyph(axis: .horizontal) }
            case .rectangle:
                RoundedRectangle(cornerRadius: 3).stroke(Theme.accent, lineWidth: 2).frame(width: 22, height: 18)
            case .circle:
                ZStack {
                    Circle().stroke(Theme.accent, lineWidth: 2).frame(width: 20, height: 20)
                    Circle().fill(Theme.accent).frame(width: 4, height: 4)
                }
            case .length, .diameter, .angle, .profile, .text:
                Text(element.kind == .length || element.kind == .diameter
                     ? (element.valueMm.map { DeFormat.number($0, maxFractionDigits: 0) } ?? "?")
                     : (element.kind == .angle ? (element.angleDeg.map { "\(Int($0))°" } ?? "?") : "T"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .minimumScaleFactor(0.5).lineLimit(1).padding(.horizontal, 4)
            }
        }
        .frame(width: 46, height: 46)
    }
}

struct SegmentGlyph: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    var body: some View {
        Group {
            if axis == .horizontal {
                HStack(spacing: 0) {
                    dot; Rectangle().fill(Theme.accent).frame(height: 2); dot
                }.frame(width: 26)
            } else {
                VStack(spacing: 0) {
                    dot; Rectangle().fill(Theme.accent).frame(width: 2); dot
                }.frame(height: 26)
            }
        }
    }
    private var dot: some View {
        Circle().fill(Theme.accent).frame(width: 6, height: 6)
    }
}

// MARK: - Überlagerung

/// Zeichnet die Erkennung transparent über das Foto: Formen, Maßlinien mit Zahlen,
/// Profilangaben mit Bezugslinie. Abgewählte Elemente erscheinen gedimmt.
struct SketchOverlayView: View {
    let elements: [RecognizedElement]

    var body: some View {
        Canvas { context, size in
            let accepted = elements.filter { $0.accepted }
            for element in accepted {
                drawShape(element, context: &context, size: size)
            }
            for element in elements where !element.accepted && element.shape != nil {
                drawShape(element, context: &context, size: size, dimmed: true)
            }
            for element in accepted where element.shape == nil && element.kind != .text {
                drawLabel(element, context: &context, size: size)
            }
        }
        .allowsHitTesting(false)
    }

    private func point(_ p: RecognizedPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private func drawShape(_ element: RecognizedElement, context: inout GraphicsContext, size: CGSize, dimmed: Bool = false) {
        let color = dimmed ? Color(white: 0.8).opacity(0.35) : Theme.accent
        let width = dimmed ? 1.2 : 2.4
        guard let shape = element.shape else { return }
        switch shape {
        case .segment(let start, let end):
            var path = Path()
            path.move(to: point(start, size)); path.addLine(to: point(end, size))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            if !dimmed {
                for p in [start, end] { context.fill(Path(ellipseIn: CGRect(x: point(p, size).x - 4.5, y: point(p, size).y - 4.5, width: 9, height: 9)), with: .color(color)) }
            }
        case .rectangle(let origin, let w, let h):
            let rect = CGRect(x: origin.x * size.width, y: origin.y * size.height, width: w * size.width, height: h * size.height)
            context.stroke(Path(rect), with: .color(color), lineWidth: width)
            if !dimmed {
                for corner in [rect.origin, CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)] {
                    context.fill(Path(ellipseIn: CGRect(x: corner.x - 4.5, y: corner.y - 4.5, width: 9, height: 9)), with: .color(color))
                }
            }
        case .circle(let center, let radius):
            let c = point(center, size)
            let r = radius * size.width
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color), lineWidth: width)
        }
        // Maßlinie mit erkanntem mm-Wert an Linien.
        if !dimmed, element.kind == .line, case .segment(let start, let end)? = element.shape, let value = element.valueMm {
            drawDimension(from: start, to: end, value: value, context: &context, size: size)
        }
    }

    private func drawDimension(from start: RecognizedPoint, to end: RecognizedPoint, value: Double, context: inout GraphicsContext, size: CGSize) {
        let p1 = point(start, size), p2 = point(end, size)
        let horizontal = abs(p2.y - p1.y) <= abs(p2.x - p1.x)
        let offset: CGFloat = 20
        let line: Path
        let labelPoint: CGPoint
        if horizontal {
            let y = min(p1.y, p2.y) - offset
            line = Path { path in
                path.move(to: CGPoint(x: p1.x, y: y)); path.addLine(to: CGPoint(x: p2.x, y: y))
                path.move(to: CGPoint(x: p1.x, y: y - 5)); path.addLine(to: CGPoint(x: p1.x, y: y + 5))
                path.move(to: CGPoint(x: p2.x, y: y - 5)); path.addLine(to: CGPoint(x: p2.x, y: y + 5))
            }
            labelPoint = CGPoint(x: (p1.x + p2.x) / 2, y: y - 11)
        } else {
            let x = min(p1.x, p2.x) - offset
            line = Path { path in
                path.move(to: CGPoint(x: x, y: p1.y)); path.addLine(to: CGPoint(x: x, y: p2.y))
                path.move(to: CGPoint(x: x - 5, y: p1.y)); path.addLine(to: CGPoint(x: x + 5, y: p1.y))
                path.move(to: CGPoint(x: x - 5, y: p2.y)); path.addLine(to: CGPoint(x: x + 5, y: p2.y))
            }
            labelPoint = CGPoint(x: x - 4, y: (p1.y + p2.y) / 2)
        }
        context.stroke(line, with: .color(Theme.accent), lineWidth: 1.4)
        let text = context.resolve(Text(DeFormat.number(value, maxFractionDigits: 0))
            .font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.accent))
        context.draw(text, at: labelPoint, anchor: horizontal ? .center : .trailing)
    }

    private func drawLabel(_ element: RecognizedElement, context: inout GraphicsContext, size: CGSize) {
        let anchor = point(element.anchor, size)
        let text: String
        switch element.kind {
        case .length: text = "\(DeFormat.number(element.valueMm ?? 0, maxFractionDigits: 0))"
        case .diameter: text = "Ø\(DeFormat.number(element.valueMm ?? 0, maxFractionDigits: 0))"
        case .angle: text = "\(DeFormat.number(element.angleDeg ?? 0, maxFractionDigits: 0))°"
        case .profile:
            text = (element.profileDimensionsMm ?? []).map { DeFormat.number($0, maxFractionDigits: 0) }.joined(separator: "x")
        default: text = element.rawText ?? ""
        }
        guard !text.isEmpty else { return }
        context.fill(Path(ellipseIn: CGRect(x: anchor.x - 3, y: anchor.y - 3, width: 6, height: 6)), with: .color(Theme.accent))
        let resolved = context.resolve(Text(text).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.accent))
        context.draw(resolved, at: CGPoint(x: anchor.x + 34, y: anchor.y + 14), anchor: .leading)
        var leader = Path()
        leader.move(to: anchor)
        leader.addLine(to: CGPoint(x: anchor.x + 30, y: anchor.y + 12))
        context.stroke(leader, with: .color(Theme.accent), lineWidth: 1.2)
    }
}

// MARK: - Archivansicht

/// Gespeicherte Skizze: Foto mit übernommener Erkennung, ohne Bearbeitung.
struct SketchArchiveView: View {
    let sketch: MCSketch
    var body: some View {
        SketchReviewView(project: sketch.project ?? MCProject(name: "–", number: "–"),
                         payload: SketchScanPayload(data: Data(), source: sketch.source, sourceLabel: sketch.sourceLabel),
                         storedSketch: sketch)
    }
}
