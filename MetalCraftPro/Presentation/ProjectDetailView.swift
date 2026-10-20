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
            .frame(maxWidth: 800).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.appBackground)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showThreeD) { ThreeDView(project: project) }
        .fullScreenCover(isPresented: $showCutList) { CutListView(project: project) }
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

struct ProjectSectionListView: View {
    let project: MCProject
    let kind: ProjectSectionKind
    @Environment(LocalStore.self) private var store
    // Skizzenimport-Status
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var scanPayload: SketchScanPayload?
    @State private var cameraProblem: String?
    @State private var showCAD = false

    var body: some View {
        List {
            switch kind {
            case .zeichnungen:
                Section {
                    Button { showCAD = true } label: {
                        Label("2D-CAD-Editor öffnen", systemImage: "pencil.and.ruler")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .tint(Theme.accent)
                    .accessibilityIdentifier("openCAD")
                }
                ForEach(project.drawings) { drawing in
                    NavigationLink { FrameDrawingView(project: project) } label: {
                        Label(drawing.title, systemImage: "doc.richtext")
                    }
                }
                if project.drawings.isEmpty {
                    empty("Noch keine Zeichnungen", "Zeichne direkt am parametrischen Modell – im 2D-CAD-Editor.")
                }
            case .skizzen:
                ForEach(project.sketches.sorted { $0.createdAt > $1.createdAt }) { sketch in
                    NavigationLink { SketchArchiveView(sketch: sketch) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(sketch.title, systemImage: sourceIcon(sketch.source))
                                Spacer()
                                Text(sketch.statusLabel).font(.caption.weight(.medium)).foregroundStyle(sketch.status == "uebernommen" ? .green : .secondary)
                            }
                            Text("\(sketch.sourceLabel) · \(sketch.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(sketch.recognizedCount) Elemente")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
                Section {
                    Menu {
                        Button("Foto aufnehmen", systemImage: "camera.fill") {
                            guard CameraPicker.isAvailable() else { cameraProblem = "Die Kamera ist auf diesem Gerät nicht verfügbar."; return }
                            showCamera = true
                        }
                        Button("Foto aus Bibliothek", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                        Button("Datei oder PDF", systemImage: "doc") { showFileImporter = true }
                    } label: {
                        Label("Skizze scannen oder importieren", systemImage: "plus.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .tint(Theme.accent)
                    .accessibilityIdentifier("importSketch")
                }
                if project.sketches.isEmpty {
                    empty("Noch keine Skizzen", "Importiere eine Skizze per Kamera, Foto oder Datei. Die Analyse mit OCR läuft vollständig lokal.")
                }
            case .bauteile:
                ForEach(project.parts.sorted { $0.positionNumber < $1.positionNumber }) { part in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pos. \(part.positionNumber) · \(part.name)").font(.headline)
                        Text("\(DeFormat.number(part.lengthMm)) mm · \(part.quantity) Stück").monospacedDigit()
                        Text("\(part.profileName) · \(part.remark)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                if project.parts.isEmpty { empty("Noch keine Bauteile", "Dieses Projekt enthält noch kein Modell.") }
            case .material:
                ForEach(project.materials) { material in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(material.resolvedName).font(.headline)
                        Text("\(material.resolvedGrade) · ca. \(DeFormat.number(material.resolvedWeightPerMeter, maxFractionDigits: 3)) kg/m").foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                Section {
                    NavigationLink("Material & Profile (Datenbank)") { ProfileCatalogView(project: project) }
                    if !project.parts.isEmpty, let weight = try? DerivationService.totalPartWeightKg(of: project) {
                        LabeledContent("Rahmengewicht (Stahl)", value: "ca. \(DeFormat.number(weight)) kg")
                        Text("Idealisiertes Profil ohne Radien, Dichte 7,85 g/cm³. Kein zertifizierter Tabellenwert.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .fotos:
                NavigationLink {
                    PhotoGalleryView(project: project)
                } label: {
                    Label("Fotogalerie öffnen · \(project.photos.count)", systemImage: "photo.on.rectangle.angled")
                }
                if project.photos.isEmpty {
                    empty("Noch keine Fertigungsfotos", "Dokumentiere die einzelnen Fertigungsschritte lokal am Projekt oder am Bauteil.")
                }
            case .dokumente:
                ForEach(project.documents) { document in
                    VStack(alignment: .leading) {
                        Text(document.title)
                        Text(document.fileName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                empty(project.documents.isEmpty ? "Noch keine Dokumente" : "Dokumentablage", "Dokumentimport und Export sind in Entwicklung.")
            case .revisionen:
                ForEach(project.revisions.sorted { $0.createdAt > $1.createdAt }) { revision in
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Revision \(revision.label)").font(.headline)
                        Text(revision.note).font(.subheadline)
                        Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.appBackground)
        .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .sheet(isPresented: $showCamera) {
            CameraPicker(onImage: { data in presentScan(data: data, source: "camera", label: "Kamera") },
                         onCancel: {})
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image, .pdf]) { result in
            importFile(result)
        }
        .alert("Kamera nicht verfügbar", isPresented: Binding(get: { cameraProblem != nil }, set: { if !$0 { cameraProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(cameraProblem ?? "") }
        .fullScreenCover(item: $scanPayload) { payload in
            SketchReviewView(project: project, payload: payload)
        }
        .fullScreenCover(isPresented: $showCAD) {
            CADEditorView(project: project, store: store)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                photoItem = nil
                if let data { presentScan(data: data, source: "photo", label: "Foto") }
                else { cameraProblem = "Das Foto konnte nicht geladen werden." }
            }
        }
    }
    private func presentScan(data: Data, source: String, label: String) {
        guard let jpeg = SketchScanService.normalizedJPEG(from: data) else {
            cameraProblem = "Das Bild konnte nicht gelesen werden."; return
        }
        scanPayload = SketchScanPayload(data: jpeg, source: source, sourceLabel: label)
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure: cameraProblem = "Die Datei konnte nicht geöffnet werden."
        case .success(let url):
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                cameraProblem = "Die Datei konnte nicht gelesen werden."; return
            }
            let isPDF = url.pathExtension.lowercased() == "pdf"
            presentScan(data: data, source: isPDF ? "pdf" : "file", label: isPDF ? "PDF" : "Datei")
        }
    }

    private func sourceIcon(_ source: String) -> String {
        switch source {
        case "camera": return "camera.fill"
        case "pdf": return "doc.richtext"
        case "file": return "doc"
        default: return "photo"
        }
    }

    private func empty(_ title: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(message)).listRowBackground(Color.clear)
    }
}

struct EditParametersSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MCProfile.name) private var profiles: [MCProfile]
    let project: MCProject
    @State private var width = ""
    @State private var height = ""
    @State private var material = ""
    @State private var profileID = ProfileCatalog.squareTube40x40x2.id
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("Breite (mm)", text: $width).accessibilityIdentifier("frameWidth")
                    field("Höhe (mm)", text: $height).accessibilityIdentifier("frameHeight")
                } header: { Text("Kernmaße") } footer: {
                    Text("Vorschau, Innenmaße und Bauteillängen werden direkt aus diesen Parametern berechnet. Keine unabhängigen Maßkopien.")
                }
                Section("Profil") {
                    Picker("Profil", selection: $profileID) {
                        ForEach(profiles) { profile in Text("\(profile.spec?.type.displayName ?? "Profil") \(profile.name)").tag(profile.id) }
                    }
                    NavigationLink("Profilkatalog & eigenes Profil") {
                        ProfileCatalogView(onSelect: { profileID = $0.id })
                    }
                }
                Section("Werkstoff") { TextField("z. B. S235", text: $material) }
                if let problem { Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            }
            .navigationTitle("Parameter").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Übernehmen") { save() }.accessibilityIdentifier("saveParameters") }
            }
            .onAppear {
                if width.isEmpty {
                    width = DeFormat.number(project.widthMm, maxFractionDigits: 6)
                    height = DeFormat.number(project.heightMm, maxFractionDigits: 6)
                    material = project.materialGrade
                    profileID = profiles.first(where: { $0.id == project.profileSpec.id })?.id
                        ?? profiles.first(where: { $0.spec?.type == project.profileSpec.type && $0.spec?.dimensionLabel == project.profileSpec.dimensionLabel })?.id
                        ?? ProfileCatalog.squareTube40x40x2.id
                }
            }
        }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack { Text(title); TextField(title, text: text).multilineTextAlignment(.trailing).keyboardType(.decimalPad) }
    }
    private func save() {
        guard let w = DeFormat.parse(width), let h = DeFormat.parse(height), let profile = profiles.first(where: { $0.id == profileID }) else {
            problem = "Bitte gib gültige Maße ein und wähle ein Profil."; return
        }
        do {
            try store.updateParameters(project, width: w, height: h, profile: profile, material: material)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}
