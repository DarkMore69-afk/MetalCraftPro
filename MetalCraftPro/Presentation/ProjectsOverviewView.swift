import SwiftUI
import SwiftData

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
    @State private var name = ""
    @State private var number = ""
    @State private var description = ""
    @State private var frame = true
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Projekt") {
                    TextField("Name", text: $name).accessibilityIdentifier("projectName")
                    TextField("Projektnummer (automatisch)", text: $number)
                    TextField("Beschreibung", text: $description, axis: .vertical).lineLimit(3...6)
                }
                Section {
                    Toggle("Parametrischer Rahmen", isOn: $frame)
                } footer: {
                    Text(frame ? "Vier Rahmenprofile, 1000 × 1000 mm, Vierkantrohr 40 × 40 × 2. Maße und Profil sind anschließend editierbar." : "Leeres Projekt ohne Zeichnung oder Bauteile.")
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
                Section { Label("Nur auf diesem Gerät gespeichert", systemImage: "internaldrive").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Neues Projekt").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") {
                        do {
                            try store.create(name: name, number: number, description: description, frame: frame)
                            dismiss()
                        } catch { problem = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("createProject")
                }
            }
        }
    }
}
