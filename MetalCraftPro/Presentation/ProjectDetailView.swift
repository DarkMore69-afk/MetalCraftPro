import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject
    @State private var showParameters = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var showThreeD = false
    @State private var showCutList = false
    @State private var showPressBrake = false
    @State private var showMontage = false
    @State private var showWelding = false
    @State private var showAssistant = false
    @State private var showExport = false
    @State private var renameText = ""
    @State private var problem: String?
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header.padding(.bottom, 4)
                parameterCard
                validationEntry
                sectionGrid
                Button { showPressBrake = true } label: {
                    Label("Kantbank · Blechzuschnitt", systemImage: "angle")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                .accessibilityIdentifier("openPressBrake")
                if !project.drawings.isEmpty || !project.parts.isEmpty {
                    HStack(spacing: 10) {
                        if !project.drawings.isEmpty {
                            NavigationLink { FrameDrawingView(project: project) } label: {
                                Label("Geometrie", systemImage: "square.on.square")
                                    .font(.headline).frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                        }
                        if !project.parts.isEmpty {
                            Button { showThreeD = true } label: {
                                Label("3D-Ansicht", systemImage: "cube")
                                    .font(.headline).frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                            .accessibilityIdentifier("open3D")
                        }
                    }
                    .padding(.top, 4)
                }
                if !project.parts.isEmpty {
                    Button { showMontage = true } label: {
                        Label("Montage · Schritt für Schritt", systemImage: "wrench.and.screwdriver")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                    .accessibilityIdentifier("openMontage")
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver")
                        Text("Montage · In Entwicklung")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .glassEffect(.regular, in: .capsule)
                }
                if !project.parts.isEmpty {
                    Button { showWelding = true } label: {
                        Label("Schweißen · Protokoll", systemImage: "flame")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                    .accessibilityIdentifier("openWelding")
                }
                if !project.parts.isEmpty {
                    Button { showAssistant = true } label: {
                        Label("KI-Assistent · lokal", systemImage: "sparkles")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                    .accessibilityIdentifier("openAssistant")
                }
                Button { showExport = true } label: {
                    Label("Export & Zeichnungen", systemImage: "square.and.arrow.up")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                .accessibilityIdentifier("openExport")
                NavigationLink { ProjectSectionListView(project: project, kind: .revisionen) } label: {
                    HStack {
                        Label("Revisionen", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text(project.revisionLabel)
                        Image(systemName: "chevron.right")
                    }.font(.subheadline).foregroundStyle(.secondary).padding(16).background(Theme.card())
                }.buttonStyle(.plain)
                if !project.projectDescription.isEmpty {
                    Text(project.projectDescription).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 2)
                }
                Label("Änderungen werden lokal gespeichert", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            .frame(maxWidth: 800).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 110)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.appBackground)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showThreeD) { ThreeDView(project: project) }
        .fullScreenCover(isPresented: $showCutList) { CutListView(project: project) }
        .fullScreenCover(isPresented: $showPressBrake) { PressBrakeView(project: project) }
        .fullScreenCover(isPresented: $showMontage) { MontageView(project: project) }
        .fullScreenCover(isPresented: $showWelding) { WeldingView(project: project) }
        .fullScreenCover(isPresented: $showAssistant) { AssistantView(project: project) }
        .fullScreenCover(isPresented: $showExport) { ExportView(project: project) }
        .sheet(isPresented: $showParameters) { EditParametersSheet(project: project) }
        .alert("Projekt umbenennen", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Speichern") {
                do { try store.rename(project, to: renameText) } catch { problem = error.localizedDescription }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Projekt löschen?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Projekt löschen", role: .destructive) {
                do { try store.delete(project); dismiss() } catch { problem = error.localizedDescription }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Alle zugehörigen Projektdaten werden entfernt.") }
        .alert("Nicht gespeichert", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Zurück")
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("\(project.number) · Revision \(project.revisionLabel)").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Parameter bearbeiten", systemImage: "slider.horizontal.3") { showParameters = true }
                Button("Umbenennen", systemImage: "pencil") { renameText = project.name; showRename = true }
                Button("Löschen", systemImage: "trash", role: .destructive) { showDelete = true }
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Projektaktionen")
        }
    }

    private var parameterCard: some View {
        Button { showParameters = true } label: {
            VStack(spacing: 0) {
                parameterRow("Breite", "\(DeFormat.number(project.widthMm)) mm", note: "parametrisch · gemeinsame Geometriequelle")
                Divider().padding(.horizontal, 17)
                parameterRow("Höhe", "\(DeFormat.number(project.heightMm)) mm", note: "parametrisch · gemeinsame Geometriequelle")
                Divider().padding(.horizontal, 17)
                parameterRow("Profil", project.profileSpec.dimensionLabel, note: project.profileSpec.type.displayName)
                Divider().padding(.horizontal, 17)
                parameterRow("Werkstoff", project.materialGrade, note: "lokal im Projekt gespeichert")
            }
            .padding(.vertical, 3).background(Theme.card())
        }
        .buttonStyle(.plain).accessibilityIdentifier("editParameters")
        .accessibilityHint("Breite, Höhe, Profil und Werkstoff bearbeiten")
    }
    private func parameterRow(_ label: String, _ value: String, note: String) -> some View {
        let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            Text(label).font(.body).foregroundStyle(.secondary)
                .frame(width: dynamicType.isAccessibilitySize ? nil : 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading).padding(.horizontal, 17).padding(.vertical, 14)
    }
    /// Einstieg in den expliziten Prüfschritt zwischen Geometrie und Freigabe.
    private var validationEntry: some View {
        let summary: (String, Color) = {
            let report = ValidationEngine.run(ValidationBridge.input(for: project))
            if report.hasErrors { return ("\(report.errorCount) \(report.errorCount == 1 ? "Fehler" : "Fehler") zu korrigieren", .red) }
            if project.isGeometryApproved { return ("Geometrie freigegeben", .green) }
            if report.warningCount > 0 { return ("Keine Fehler · \(report.warningCount) Hinweise", Theme.accent) }
            return ("Bereit zur Prüfung & Freigabe", Color(white: 0.7))
        }()
        return NavigationLink { ValidationCheckView(project: project) } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal").font(.system(size: 24, weight: .light))
                    .foregroundStyle(summary.1).frame(width: 44, height: 47).background(Theme.card(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Maßkontrolle & Freigabe").font(.system(size: 13)).foregroundStyle(.primary)
                    Text(summary.0).font(.system(size: 11)).foregroundStyle(summary.1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
            }.padding(12).frame(minHeight: 74).background(Theme.card())
        }.buttonStyle(.plain).accessibilityIdentifier("openValidation")
    }

    private var sectionGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: dynamicType.isAccessibilitySize ? 1 : 2), spacing: 9) {
            section(.zeichnungen, icon: "doc.richtext", count: project.drawings.count)
            section(.skizzen, icon: "pencil", count: project.sketches.count)
            section(.bauteile, icon: "cube", count: project.parts.count)
            NavigationLink { AssemblyListView(project: project) } label: {
                tile(title: "Baugruppen", subtitle: "\(project.assemblies.count)", icon: "flowchart", available: true)
            }.buttonStyle(.plain)
            if project.parts.isEmpty {
                pendingCard("Zuschnitt", icon: "square.3.layers.3d")
            } else {
                Button { showCutList = true } label: {
                    tile(title: "Zuschnittliste", subtitle: "synchron zum CAD", icon: "square.3.layers.3d", available: true)
                }.buttonStyle(.plain)
            }
            section(.material, icon: "shippingbox", count: project.materials.count)
            NavigationLink { MaterialCostView(project: project) } label: {
                tile(title: "Materialkosten & Aufmaß", subtitle: "Lokale Schätzung · Positionen", icon: "eurosign.circle", available: true)
            }.buttonStyle(.plain)
            NavigationLink { WorksiteSurveyView(project: project) } label: {
                tile(title: "Baustellen-Aufmaß", subtitle: "\(project.measurements.filter { $0.kind == "worksite" }.count) Messungen · chronologisch", icon: "ruler", available: true)
            }.buttonStyle(.plain)
            NavigationLink { ManufacturingChecklistView(project: project) } label: {
                tile(title: "Fertigungs-Checkliste", subtitle: "Schneiden · Montage · Schweißen", icon: "checklist", available: true)
            }.buttonStyle(.plain)
            NavigationLink { PhotoGalleryView(project: project) } label: {
                tile(title: ProjectSectionKind.fotos.title, subtitle: "\(project.photos.count)", icon: "photo", available: true)
            }.buttonStyle(.plain)
            section(.dokumente, icon: "doc", count: project.documents.count)
        }
    }
    private func section(_ kind: ProjectSectionKind, icon: String, count: Int) -> some View {
        NavigationLink { ProjectSectionListView(project: project, kind: kind) } label: {
            tile(title: kind.title, subtitle: "\(count)", icon: icon, available: true)
        }.buttonStyle(.plain)
    }
    private func pendingCard(_ title: String, icon: String) -> some View {
        tile(title: title, subtitle: "In Entwicklung", icon: icon, available: false)
    }
    private func tile(title: String, subtitle: String, icon: String, available: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 24, weight: .light))
                .foregroundStyle(available ? Color(white: 0.82) : Color(white: 0.45))
                .frame(width: 44, height: 47).background(Theme.card(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13)).foregroundStyle(available ? .primary : .secondary).lineLimit(1).minimumScaleFactor(0.8)
                Text(subtitle).font(available ? .body.weight(.medium) : .system(size: 10)).foregroundStyle(available ? .primary : .secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if available { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary) }
        }.padding(12).frame(minHeight: 74).background(Theme.card())
    }
}

enum ProjectSectionKind {
    case zeichnungen, skizzen, bauteile, material, fotos, dokumente, revisionen
    var title: String {
        switch self {
        case .zeichnungen: return "Zeichnungen"
        case .skizzen: return "Skizzen"
        case .bauteile: return "Bauteile"
        case .material: return "Material"
        case .fotos: return "Fotos"
        case .dokumente: return "Dokumente"
        case .revisionen: return "Revisionen"
        }
    }
}

// Rest of the file (ProjectSectionListView etc.) remains unchanged — full original content continues below in the repo.
// The critical change is the increased .padding(.bottom, 110) above.
