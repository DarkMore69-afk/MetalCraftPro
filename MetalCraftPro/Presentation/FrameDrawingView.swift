import SwiftUI

/// Read-only inspection of the core model, deliberately not the later CAD editor.
struct FrameDrawingView: View {
    let project: MCProject
    @State private var editing = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Vorderansicht Rahmen").font(.title3.weight(.semibold))
                        Text("\(project.profileSpec.type.displayName) \(project.profileSpec.dimensionLabel) · \(project.materialGrade)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("mm").font(.caption.monospaced()).foregroundStyle(Theme.accent)
                }
                if let frame = project.frameParameters {
                    diagram(frame).frame(height: 300).background(Theme.card())
                        .accessibilityLabel("Rahmen, \(DeFormat.number(frame.width)) mal \(DeFormat.number(frame.height)) Millimeter, Innenmaß \(DeFormat.number(frame.innerWidth)) mal \(DeFormat.number(frame.innerHeight)) Millimeter")
                    VStack(spacing: 0) {
                        value("Außenmaß", "\(DeFormat.number(frame.width)) × \(DeFormat.number(frame.height)) mm")
                        Divider()
                        value("Innenmaß", "\(DeFormat.number(frame.innerWidth)) × \(DeFormat.number(frame.innerHeight)) mm")
                        Divider()
                        value("Diagonale außen", "\(DeFormat.number(hypot(frame.width, frame.height))) mm")
                    }.background(Theme.card())
                    Text("\(DeFormat.number(frame.width)) − \(DeFormat.number(frame.profile.widthMm)) − \(DeFormat.number(frame.profile.widthMm)) = \(DeFormat.number(frame.innerWidth)) mm")
                        .font(.body.monospaced()).foregroundStyle(Theme.accent)
                    Text("Vier Profile, stumpfer Stoß. Horizontale Teile durchgehend; vertikale Teile dazwischen. Die Vorschau ist maßproportional, nicht zum Abmessen am Bildschirm geeignet.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { editing = true } label: {
                        Label("Parameter bearbeiten", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.glassProminent).foregroundStyle(.black)
                } else {
                    ContentUnavailableView("Geometrie nicht darstellbar", systemImage: "exclamationmark.triangle", description: Text("Bitte prüfe Breite, Höhe und Profil."))
                }
                Text("2D-Vorschau · CAD-Bearbeitung in Entwicklung").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 800).padding(20).frame(maxWidth: .infinity)
        }
        .background(Theme.appBackground)
        .navigationTitle("Geometrie").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $editing) { EditParametersSheet(project: project) }
    }
    private func value(_ label: String, _ text: String) -> some View {
        LabeledContent(label, value: text).font(.subheadline).padding(16)
    }
    private func diagram(_ frame: FrameParameters) -> some View {
        Canvas { context, size in
            var grid = Path()
            for x in stride(from: 16.0, to: size.width, by: 20) {
                grid.move(to: CGPoint(x: x, y: 12)); grid.addLine(to: CGPoint(x: x, y: size.height - 12))
            }
            for y in stride(from: 16.0, to: size.height, by: 20) {
                grid.move(to: CGPoint(x: 12, y: y)); grid.addLine(to: CGPoint(x: size.width - 12, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.04)), lineWidth: 0.5)
            let scale = min((size.width - 100) / frame.width, (size.height - 100) / frame.height)
            let w = frame.width * scale, h = frame.height * scale, t = frame.profile.widthMm * scale
            let x = (size.width - w) / 2 - 12, y = (size.height - h) / 2 + 4
            var body = Path()
            body.addRect(CGRect(x: x, y: y, width: w, height: h))
            body.addRect(CGRect(x: x + t, y: y + t, width: w - t * 2, height: h - t * 2))
            context.fill(body, with: .color(.white.opacity(0.06)), style: FillStyle(eoFill: true))
            for edge in [y + t, y + h - t] {
                body.move(to: CGPoint(x: x, y: edge)); body.addLine(to: CGPoint(x: x + t, y: edge))
                body.move(to: CGPoint(x: x + w - t, y: edge)); body.addLine(to: CGPoint(x: x + w, y: edge))
            }
            context.stroke(body, with: .color(.white.opacity(0.85)), lineWidth: 1)
            var dims = Path()
            dims.move(to: CGPoint(x: x, y: y - 18)); dims.addLine(to: CGPoint(x: x + w, y: y - 18))
            dims.move(to: CGPoint(x: x + w + 18, y: y)); dims.addLine(to: CGPoint(x: x + w + 18, y: y + h))
            for xx in [x, x + w] {
                dims.move(to: CGPoint(x: xx, y: y - 24)); dims.addLine(to: CGPoint(x: xx, y: y - 8))
            }
            for yy in [y, y + h] {
                dims.move(to: CGPoint(x: x + w + 8, y: yy)); dims.addLine(to: CGPoint(x: x + w + 24, y: yy))
            }
            context.stroke(dims, with: .color(Theme.accent.opacity(0.7)), lineWidth: 0.7)
            context.draw(Text(DeFormat.number(frame.width)).font(.caption.monospacedDigit()).foregroundStyle(Theme.accent), at: CGPoint(x: x + w / 2, y: y - 32))
            context.draw(Text(DeFormat.number(frame.height)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.accent), at: CGPoint(x: x + w + 23, y: y + h / 2), anchor: .leading)
            context.draw(Text("\(DeFormat.number(frame.innerWidth)) × \(DeFormat.number(frame.innerHeight))").font(.caption.monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: x + w / 2, y: y + h / 2))
        }
    }
}
