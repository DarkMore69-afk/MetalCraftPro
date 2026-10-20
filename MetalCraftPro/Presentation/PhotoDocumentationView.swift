import SwiftUI
import PhotosUI
import UIKit

private struct PhotoDraft: Identifiable {
    let id = UUID()
    let jpegData: Data
}

struct PhotoGalleryView: View {
    @Environment(LocalStore.self) private var store
    let project: MCProject

    @State private var filter: PhotoCategory?
    @State private var showCamera = false
    @State private var cameraProblem: String?
    @State private var cameraData: Data?
    @State private var draft: PhotoDraft?
    @State private var photoItem: PhotosPickerItem?

    private var photos: [MCPhoto] {
        project.photos
            .filter { filter == nil || $0.category == filter?.rawValue }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                projectHeading
                categoryFilters
                if photos.isEmpty {
                    emptyGallery
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(photos) { photo in
                            NavigationLink {
                                PhotoDetailView(photo: photo)
                            } label: {
                                photoCard(photo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 850)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.appBackground)
        .navigationTitle("Fotos")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            importBar
        }
        .sheet(isPresented: $showCamera, onDismiss: presentCameraDraft) {
            CameraPicker(onImage: { data in
                cameraData = data
                showCamera = false
            }, onCancel: {
                showCamera = false
            })
            .ignoresSafeArea()
        }
        .sheet(item: $draft) { value in
            PhotoReviewView(project: project, imageData: value.jpegData)
                .environment(store)
                .presentationDetents([.large])
        }
        .alert("Foto konnte nicht geöffnet werden", isPresented: Binding(
            get: { cameraProblem != nil }, set: { if !$0 { cameraProblem = nil } }
        )) {
            Button("OK", role: .cancel) { cameraProblem = nil }
        } message: {
            Text(cameraProblem ?? "")
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    photoItem = nil
                    guard let data else {
                        cameraProblem = "Das Foto aus der Bibliothek konnte nicht geladen werden."
                        return
                    }
                    prepareDraft(from: data)
                }
            }
        }
    }

    private var projectHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name).font(.title3.weight(.semibold))
            Text("\(project.number) · Revision \(project.revisionLabel)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card())
    }

    private var categoryFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill(title: "Alle", symbol: "square.grid.2x2", selected: filter == nil) { filter = nil }
                ForEach(PhotoCategory.allCases) { category in
                    filterPill(title: category.label, symbol: category.symbol, selected: filter == category) {
                        filter = category
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterPill(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .foregroundStyle(selected ? Color.black : Color.primary)
                .background {
                    Capsule().fill(selected ? Theme.accent : Theme.cardBackground)
                }
                .overlay {
                    Capsule().strokeBorder(selected ? Theme.accent : Color.white.opacity(0.1), lineWidth: 0.7)
                }
        }
        .buttonStyle(.plain)
    }

    private var emptyGallery: some View {
        ContentUnavailableView {
            Label(filter.map { "Keine Fotos · \($0.label)" } ?? "Noch keine Fertigungsfotos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(filter == nil ? "Halte jeden Fertigungsschritt fest. Bilder bleiben lokal auf diesem Gerät." : "Für diese Kategorie gibt es noch keine Fotos.")
        }
        .frame(minHeight: 280)
    }

    private func photoCard(_ photo: MCPhoto) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.fieldBackground)
                if let image = PhotoImageStore.load(photo.imageFileName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 145)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(height: 145)
                }
            }
            .frame(height: 145)

            Text(photo.caption.isEmpty ? photo.categoryLabel : photo.caption)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            HStack(spacing: 5) {
                Text(photo.categoryLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 3)
                Text(photo.createdAt.formatted(date: .numeric, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let part = photo.partID.flatMap({ id in project.parts.first(where: { $0.id == id }) }) {
                Text("Pos. \(part.positionNumber) · \(part.name)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .background(Theme.card())
        .accessibilityElement(children: .combine)
    }

    private var importBar: some View {
        HStack(spacing: 10) {
            Button {
                guard CameraPicker.isAvailable() else {
                    cameraProblem = "Die Kamera ist auf diesem Gerät nicht verfügbar."
                    return
                }
                showCamera = true
            } label: {
                Label("Foto aufnehmen", systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)

            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle")
                    .font(.headline)
                    .frame(width: 52, height: 50)
            }
            .buttonStyle(.glass)
            .tint(.white)
            .accessibilityLabel("Foto aus Bibliothek wählen")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private func presentCameraDraft() {
        guard let data = cameraData else { return }
        cameraData = nil
        prepareDraft(from: data)
    }

    private func prepareDraft(from data: Data) {
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.88) else {
            cameraProblem = "Das Bild konnte nicht gelesen werden."
            return
        }
        draft = PhotoDraft(jpegData: jpeg)
    }
}

private struct PhotoReviewView: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject
    let imageData: Data

    @State private var category: PhotoCategory = .vorher
    @State private var caption = ""
    @State private var partID: UUID?
    @State private var problem: String?
    @State private var saving = false

    private var parts: [MCPart] { project.parts.sorted { $0.positionNumber < $1.positionNumber } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image = UIImage(data: imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 245)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .listRowBackground(Color.clear)
                    }
                }
                Section("Fertigungsschritt") {
                    Picker("Kategorie", selection: $category) {
                        ForEach(PhotoCategory.allCases) { option in
                            Label(option.label, systemImage: option.symbol).tag(option)
                        }
                    }
                    TextField("z. B. Querstrebe eingeschweißt", text: $caption, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Zuordnung") {
                    Picker("Bauteil", selection: $partID) {
                        Text("Projekt · ohne Bauteil").tag(Optional<UUID>.none)
                        ForEach(parts) { part in
                            Text("Pos. \(part.positionNumber) · \(part.name)").tag(Optional(part.id))
                        }
                    }
                }
                Section {
                    Label("Bleibt vollständig auf dem Gerät.", systemImage: "internaldrive")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground)
            .navigationTitle("Foto prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(saving)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        saving = true
        do {
            try store.addPhoto(project, imageData: imageData, category: category.rawValue,
                               caption: caption, partID: partID)
            dismiss()
        } catch {
            problem = error.localizedDescription
            saving = false
        }
    }
}

private struct PhotoDetailView: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let photo: MCPhoto
    @State private var showDeleteConfirmation = false
    @State private var problem: String?

    private var linkedPart: MCPart? {
        guard let project = photo.project, let partID = photo.partID else { return nil }
        return project.parts.first { $0.id == partID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    if let image = PhotoImageStore.load(photo.imageFileName) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Foto nicht verfügbar", systemImage: "photo.badge.exclamationmark")
                            .frame(height: 250)
                    }
                }
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    Label(photo.categoryLabel, systemImage: PhotoCategory(rawValue: photo.category)?.symbol ?? "photo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text(photo.caption.isEmpty ? "Ohne Beschriftung" : photo.caption)
                        .font(.title3.weight(.semibold))
                    if let linkedPart {
                        Label("Pos. \(linkedPart.positionNumber) · \(linkedPart.name)", systemImage: "cube")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Label("Projektweite Dokumentation", systemImage: "folder")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(photo.createdAt.formatted(date: .long, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card())

                Button(role: .destructive) { showDeleteConfirmation = true } label: {
                    Label("Foto löschen", systemImage: "trash")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glass)
            }
            .frame(maxWidth: 760)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.appBackground)
        .navigationTitle("Foto")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Foto dauerhaft löschen?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Foto löschen", role: .destructive) { delete() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Das Bild wird vom Gerät entfernt und im Projektprotokoll vermerkt.")
        }
        .alert("Foto nicht gelöscht", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func delete() {
        do {
            try store.deletePhoto(photo)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
