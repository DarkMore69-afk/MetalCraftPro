import SwiftUI
import SwiftData
import PhotosUI

struct ProjectsOverviewView: View {
    @Environment(LocalStore.self) private var store
    @Query(sort: \MCProject.createdAt) private var projects: [MCProject]
    @State private var search = ""
    @State private var newestFirst = false
    @State private var showNew = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var target: MCProject?
    @State private var renameText = ""
    @State private var problem: String?
    @State private var showProfiles = false
    @State private var showCalculator = false
    private var filtered: [MCProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = projects.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.number.localizedStandardContains(query) || $0.projectDescription.localizedStandardContains(query) }
        return newestFirst ? result.sorted { $0.createdAt > $1.createdAt } : result
    }
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .center) {
                            Text("Projekte").font(.system(size: 36, weight: .bold)).accessibilityAddTraits(.isHeader)
                            Spacer()
                            Menu {
                                Button("Profilkatalog", systemImage: "square.stack.3d.up") { showProfiles = true }
                                Button("Grundrechner", systemImage: "function") { showCalculator = true }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Werkzeuge")
                        }
                        .padding(.top, 24)
                        searchField.padding(.bottom, 2)
                        LazyVStack(spacing: 14) {
                            ForEach(filtered) { project in
                                NavigationLink(value: project) { ProjectCard(project: project) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Umbenennen", systemImage: "pencil") {
                                            target = project; renameText = project.name; showRename = true
                                        }
                                        Button("Löschen", systemImage: "trash", role: .destructive) {
                                            target = project; showDelete = true
                                        }
                                    }
                            }
                        }
                        if filtered.isEmpty {
                            ContentUnavailableView(search.isEmpty ? "Dein nächstes Projekt" : "Keine Projekte gefunden", systemImage: "folder", description: Text(search.isEmpty ? "Lege mit + ein lokales Projekt an." : "Suche nach Name oder Projektnummer."))
                        }
                    }
                    .frame(maxWidth: 960)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 106)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                Button { showNew = true } label: {
                    Image(systemName: "plus").font(.system(size: 27, weight: .regular))
                        .foregroundStyle(.black).frame(width: 62, height: 62)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                .tint(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.16), radius: 14, y: 3)
                .padding(.trailing, 20).padding(.bottom, 14)
                .accessibilityLabel("Neues Projekt").accessibilityIdentifier("newProject")
            }
            .background(Theme.appBackground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MCProject.self) { ProjectDetailView(project: $0) }
            .sheet(isPresented: $showNew) { NewProjectSheet() }
            .sheet(isPresented: $showProfiles) { NavigationStack { ProfileCatalogView() } }
            .sheet(isPresented: $showCalculator) { NavigationStack { BasicCalculatorView() } }
            .alert("Projekt umbenennen", isPresented: $showRename) {
                TextField("Name", text: $renameText)
                Button("Speichern") {
                    guard let target else { return }
                    do { try store.rename(target, to: renameText) } catch { problem = error.localizedDescription }
                }
                Button("Abbrechen", role: .cancel) {}
            }
            .confirmationDialog("Projekt löschen?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Projekt löschen", role: .destructive) {
                    guard let target else { return }
                    do { try store.delete(target) } catch { problem = error.localizedDescription }
                    self.target = nil
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { Text("Alle zugehörigen Projektdaten werden entfernt. Der Profilkatalog bleibt erhalten.") }
            .alert("Nicht gespeichert", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
        }
    }
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Projekte suchen …", text: $search).autocorrectionDisabled().accessibilityIdentifier("projectSearch")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary).accessibilityLabel("Suche löschen").frame(minWidth: 44, minHeight: 44)
            }
            Menu {
                Picker("Sortierung", selection: $newestFirst) {
                    Text("Nach Anlagedatum").tag(false)
                    Text("Neueste zuerst").tag(true)
                }
            } label: {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary).frame(width: 44, height: 48)
            }.accessibilityLabel("Projekte sortieren")
        }
        .padding(.leading, 17).padding(.trailing, 5)
        .frame(minHeight: 52)
        .glassEffect(.regular, in: .capsule)
    }
}

struct ProjectCard: View {
    let project: MCProject
    @Environment(\.dynamicTypeSize) private var dynamicType
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(project.name).font(.system(.headline, weight: .semibold)).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(project.number).font(.subheadline).foregroundStyle(.secondary)
                Text(project.summaryLine).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !dynamicType.isAccessibilitySize {
                ZStack {
                    if project.parts.isEmpty {
                        Image(systemName: "doc.badge.plus").font(.title2).foregroundStyle(.tertiary)
                    } else { FrameThumbnail(frame: project.frameParameters) }
                }
                .frame(width: 92, height: 86)
                .background(Theme.card(cornerRadius: 9))
            }
            Image(systemName: "chevron.right").font(.subheadline).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(minHeight: 115)
        .background(Theme.card())
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

struct NewProjectSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingPayload: SketchScanPayload?
    @State private var createdProject: MCProject?
    @State private var showReview = false
    @State private var showProject = false
    @State private var didAdoptSketch = false
    @State private var isCreating = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 14)
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 92, height: 92)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 26))
                Text("Neues Projekt")
                    .font(.title2.weight(.bold))
                Text("Starte direkt mit einem Foto deiner Skizze. Name und Projektnummer vergeben wir automatisch.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                VStack(spacing: 12) {
                    Button(action: openCamera) {
                        Label("Skizze fotografieren", systemImage: "camera.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                    .accessibilityIdentifier("newProjectCamera")

                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Foto oder Skizze auswählen", systemImage: "photo.on.rectangle")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.glass).tint(.white)
                    .accessibilityIdentifier("newProjectPhoto")
                    .disabled(isCreating)
                }
                .frame(maxWidth: 420)

                if isCreating { ProgressView("Projekt wird vorbereitet …").padding(.top, 4) }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                Label("Lokal auf diesem Gerät · kein leeres Rahmenprojekt", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.appBackground)
            .navigationTitle("Projektstart").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker(onImage: { data in beginProject(from: data, source: "camera", label: "Kamera") },
                             onCancel: {})
                    .ignoresSafeArea()
            }
            .navigationDestination(isPresented: $showReview) {
                if let createdProject, let pendingPayload {
                    SketchReviewView(project: createdProject, payload: pendingPayload) {
                        didAdoptSketch = true
                    }
                }
            }
            .navigationDestination(isPresented: $showProject) {
                if let createdProject { ProjectDetailView(project: createdProject) }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    photoItem = nil
                    if let data { beginProject(from: data, source: "photo", label: "Foto") }
                    else { problem = "Das Foto konnte nicht geladen werden." }
                }
            }
            .onChange(of: showReview) { _, isPresented in
                guard !isPresented, let createdProject else { return }
                if didAdoptSketch {
                    showProject = true
                } else {
                    // Ein abgebrochener Scan soll kein leeres Projekt zurücklassen.
                    try? store.delete(createdProject)
                    self.createdProject = nil
                    pendingPayload = nil
                }
            }
            .alert("Projektstart nicht möglich", isPresented: Binding(
                get: { problem != nil }, set: { if !$0 { problem = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
        }
    }

    private func openCamera() {
        guard CameraPicker.isAvailable() else {
            problem = "Die Kamera ist auf diesem Gerät nicht verfügbar."
            return
        }
        showCamera = true
    }

    private func beginProject(from data: Data, source: String, label: String) {
        guard !isCreating else { return }
        guard let jpeg = SketchScanService.normalizedJPEG(from: data) else {
            problem = "Das Bild konnte nicht gelesen werden."
            return
        }
        isCreating = true
        defer { isCreating = false }
        do {
            let name = "Skizze \(Date.now.formatted(date: .numeric, time: .shortened))"
            let project = try store.create(name: name, number: "", description: "", frame: false)
            createdProject = project
            pendingPayload = SketchScanPayload(data: jpeg, source: source, sourceLabel: label)
            didAdoptSketch = false
            showReview = true
        } catch {
            problem = error.localizedDescription
        }
    }
}
