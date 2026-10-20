import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case projekte, scan, cad, dreid, zuschnitt, montage
    var id: Self { self }
    var title: String {
        switch self {
        case .projekte: return "Projekte"
        case .scan: return "Scan"
        case .cad: return "CAD"
        case .dreid: return "3D"
        case .zuschnitt: return "Zuschnitt"
        case .montage: return "Montage"
        }
    }
    var icon: String {
        switch self {
        case .projekte: return "folder.fill"
        case .scan: return "viewfinder"
        case .cad, .dreid: return "cube"
        case .zuschnitt: return "sawblade"
        case .montage: return "wrench.adjustable"
        }
    }
}

struct RootView: View {
    @Environment(LocalStore.self) private var store
    @State private var tab = AppTab.projekte
    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()
            ProjectsOverviewView().opacity(tab == .projekte ? 1 : 0)
                .allowsHitTesting(tab == .projekte).accessibilityHidden(tab != .projekte)
            if tab != .projekte { InDevelopmentView(title: tab.title, icon: tab.icon) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CustomTabBar(selection: $tab).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
        }
        .alert("Lokale Speicherung", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("Verstanden") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }
}

/// Native SwiftUI buttons and system Liquid Glass. A six-item dock mirrors the supplied
/// composition without hiding workshop destinations in a More menu.
struct CustomTabBar: View {
    @Binding var selection: AppTab
    @Environment(\.dynamicTypeSize) private var dynamicType
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tab.icon).font(.system(size: 21, weight: .regular)).frame(height: 25)
                        if !dynamicType.isAccessibilitySize {
                            Text(tab.title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .foregroundStyle(selection == tab ? Theme.accent : Color(white: 0.68))
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(selection == tab ? Theme.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 23))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab == .projekte ? tab.title : "\(tab.title), in Entwicklung")
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 650)
    }
}

struct InDevelopmentView: View {
    let title: String
    let icon: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text("In Entwicklung\nDie lokale Projektbasis ist bereits nutzbar. Dieser Bereich folgt in einem späteren Modul.")
        }
    }
}

/// Preview is rendered from the canonical frame, not an unrelated decorative gate image.
struct FrameThumbnail: View {
    let frame: FrameParameters?
    var body: some View {
        Canvas { context, size in
            guard let frame else { return }
            let inset: CGFloat = 10
            let scale = min((size.width - inset * 2) / frame.width, (size.height - inset * 2) / frame.height)
            let w = frame.width * scale, h = frame.height * scale, t = frame.profile.widthMm * scale
            let x = (size.width - w) / 2, y = (size.height - h) / 2
            var outline = Path()
            outline.addRect(CGRect(x: x, y: y, width: w, height: h))
            outline.addRect(CGRect(x: x + t, y: y + t, width: w - t * 2, height: h - t * 2))
            for edge in [y + t, y + h - t] {
                outline.move(to: CGPoint(x: x, y: edge)); outline.addLine(to: CGPoint(x: x + t, y: edge))
                outline.move(to: CGPoint(x: x + w - t, y: edge)); outline.addLine(to: CGPoint(x: x + w, y: edge))
            }
            context.stroke(outline, with: .color(.white.opacity(0.7)), lineWidth: 0.8)
        }
        .accessibilityLabel("Parametrische Rahmenvorschau")
    }
}
