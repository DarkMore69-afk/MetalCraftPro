import SwiftUI
import PhotosUI
import UIKit

enum WorksiteSurveyFilter: Hashable {
    case all
    case unassigned
    case part(UUID)

    func apply(to measurements: [MCMeasurement]) -> [MCMeasurement] {
        measurements
            .filter { measurement in
                guard measurement.kind == "worksite" else { return false }
                switch self {
                case .all: return true
                case .unassigned: return measurement.partID == nil
                case .part(let partID): return measurement.partID == partID
                }
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString > $1.id.uuidString
            }
    }
}

struct WorksiteSurveyView: View {
    @Environment(LocalStore.self) private var store
    let project: MCProject
    @State private var showingAddMeasurement = false
    @State private var measurementToDelete: MCMeasurement?
    @State private var measurementToCheck: MCMeasurement?
    @State private var measurementToDocument: MCMeasurement?
    @State private var selectedFilter = WorksiteSurveyFilter.all
    @State private var problem: String?

    private var isShowingCheckEditor: Binding<Bool> {
        Binding(get: { measurementToCheck != nil }, set: { if !$0 { measurementToCheck = nil } })
    }

    private var isShowingPhotoManager: Binding<Bool> {
        Binding(get: { measurementToDocument != nil }, set: { if !$0 { measurementToDocument = nil } })
    }

    private var parts: [MCPart] {
        project.parts.sorted {
            if $0.positionNumber != $1.positionNumber { return $0.positionNumber < $1.positionNumber }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var measurements: [MCMeasurement] {
        WorksiteSurveyFilter.all.apply(to: project.measurements)
    }

    private var filteredMeasurements: [MCMeasurement] {
        selectedFilter.apply(to: project.measurements)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Baustellen-Aufmaß", systemImage: "ruler")
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                    Text("Erfasse Ist-Maße direkt am Projekt. Neue Einträge stehen oben und werden mit Datum, Uhrzeit und im Projektprotokoll gespeichert.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { showingAddMeasurement = true } label: {
                        Label("Messung erfassen", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
                    .padding(.top, 5)
                }
                .padding(.vertical, 5)
                .listRowBackground(Theme.card())
            }

            if measurements.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Noch keine Messungen", systemImage: "ruler")
                    } description: {
                        Text("Lege ein Baustellenmaß mit Wert, Einheit und optionaler Bauteilzuordnung an.")
                    } actions: {
                        Button("Erste Messung erfassen") { showingAddMeasurement = true }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.accent)
                            .foregroundStyle(.black)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("Filter") {
                    Picker("Bauteil", selection: $selectedFilter) {
                        Text("Alle Bauteile").tag(WorksiteSurveyFilter.all)
                        Text("Ohne Bauteil").tag(WorksiteSurveyFilter.unassigned)
                        ForEach(parts) { part in
                            Text("Pos. \(part.positionNumber) · \(part.name)")
                                .tag(WorksiteSurveyFilter.part(part.id))
                        }
                    }
                    .pickerStyle(.menu)
                    LabeledContent("Angezeigt", value: "\(filteredMeasurements.count) von \(measurements.count) Messwerten")
                        .font(.subheadline.monospacedDigit())
                }

                if filteredMeasurements.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("Keine passenden Messungen", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("Für diesen Filter sind keine Baustellenmessungen vorhanden.")
                        } actions: {
                            Button("Alle Messungen anzeigen") { selectedFilter = .all }
                                .buttonStyle(.glassProminent)
                                .tint(Theme.accent)
                                .foregroundStyle(.black)
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(filteredMeasurements) { measurement in
                            measurementRow(measurement)
                                .listRowBackground(Theme.card())
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        measurementToDelete = measurement
                                    } label: {
                                        Label("Löschen", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Messprotokoll")
                            Spacer()
                            Text("\(filteredMeasurements.count)")
                                .monospacedDigit()
                        }
                    } footer: {
                        Text("Chronologisch sortiert · Änderungen und Löschungen erscheinen im Projektprotokoll.")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.appBackground)
        .navigationTitle("Baustellen-Aufmaß")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddMeasurement = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Messung erfassen")
            }
        }
        .sheet(isPresented: $showingAddMeasurement) {
            AddWorksiteMeasurementSheet(project: project)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: isShowingCheckEditor) {
            if let measurementToCheck {
                WorksiteMeasurementCheckSheet(measurement: measurementToCheck)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: isShowingPhotoManager) {
            if let measurementToDocument {
                WorksiteMeasurementPhotosSheet(measurement: measurementToDocument)
                    .presentationDetents([.large])
            }
        }
        .confirmationDialog("Messung löschen?", isPresented: Binding(
            get: { measurementToDelete != nil },
            set: { if !$0 { measurementToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Messung löschen", role: .destructive) { deleteSelectedMeasurement() }
            Button("Abbrechen", role: .cancel) { measurementToDelete = nil }
        } message: {
            Text(measurementToDelete.map { "„\($0.displayLabel)“ wird aus dem Aufmaß entfernt." } ?? "")
        }
        .alert("Aufmaß konnte nicht gespeichert werden", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func measurementRow(_ measurement: MCMeasurement) -> some View {
        let part = measurement.partID.flatMap { partID in project.parts.first { $0.id == partID } }
        return HStack(alignment: .top, spacing: 13) {
            Image(systemName: "ruler")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 42, height: 42)
                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(measurement.displayLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text("\(DeFormat.number(measurement.value)) \(measurement.unit)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let part {
                    Label("Pos. \(part.positionNumber) · \(part.name)", systemImage: "cube")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = measurement.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = measurement.worksiteCheckSummary {
                    Label(summary, systemImage: measurement.worksiteCheckWithinTolerance == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(measurement.worksiteCheckWithinTolerance == true ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Keine Sollprüfung hinterlegt")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Label(measurement.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        measurementToCheck = measurement
                    } label: {
                        Label(measurement.targetValue == nil ? "Sollwert festlegen" : "Prüfung anpassen",
                              systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(Theme.accent)
                }
                HStack(spacing: 8) {
                    if !measurement.photos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(measurement.photos.sorted { $0.createdAt > $1.createdAt }) { photo in
                                    if let image = PhotoImageStore.load(photo.imageFileName) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 46, height: 46)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                }
                            }
                        }
                    }
                    Button {
                        measurementToDocument = measurement
                    } label: {
                        Label(measurement.photos.isEmpty ? "Foto hinzufügen" : "Fotos · \(measurement.photos.count)",
                              systemImage: "camera")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(Theme.accent)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func deleteSelectedMeasurement() {
        guard let measurement = measurementToDelete else { return }
        measurementToDelete = nil
        do {
            try store.deleteWorksiteMeasurement(measurement)
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct WorksiteMeasurementPhotosSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let measurement: MCMeasurement

    @State private var showCamera = false
    @State private var cameraData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var problem: String?
    @State private var working = false

    private var projectPhotos: [MCPhoto] {
        (measurement.project?.photos ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    private var linkedPhotos: [MCPhoto] {
        measurement.photos.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Messfotos · \(linkedPhotos.count)") {
                    if linkedPhotos.isEmpty {
                        Text("Noch keine Fotos mit diesem Messwert verknüpft.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(linkedPhotos) { photo in
                            HStack(spacing: 12) {
                                thumbnail(photo)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(photo.caption.isEmpty ? photo.categoryLabel : photo.caption)
                                        .font(.subheadline.weight(.medium))
                                    Text(photo.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    remove(photo)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Fotozuordnung entfernen")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section("Vorhandene Projektfotos") {
                    if projectPhotos.isEmpty {
                        Text("In diesem Projekt sind noch keine Fotos gespeichert.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(projectPhotos) { photo in
                            let isLinked = linkedPhotos.contains { $0.id == photo.id }
                            HStack(spacing: 12) {
                                thumbnail(photo)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(photo.caption.isEmpty ? photo.categoryLabel : photo.caption)
                                        .font(.subheadline.weight(.medium))
                                    Text("\(photo.categoryLabel) · \(photo.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    if isLinked { remove(photo) } else { associate(photo) }
                                } label: {
                                    Image(systemName: isLinked ? "checkmark.circle.fill" : "plus.circle")
                                        .font(.title3)
                                }
                                .buttonStyle(.borderless)
                                .tint(isLinked ? .green : Theme.accent)
                                .accessibilityLabel(isLinked ? "Fotozuordnung entfernen" : "Foto zuordnen")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section("Neues Foto hinzufügen") {
                    Button {
                        guard CameraPicker.isAvailable() else {
                            problem = "Die Kamera ist auf diesem Gerät nicht verfügbar."
                            return
                        }
                        showCamera = true
                    } label: {
                        Label("Foto aufnehmen", systemImage: "camera.fill")
                    }
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        Label("Aus der Mediathek wählen", systemImage: "photo.on.rectangle")
                    }
                    .disabled(working)
                    Label("Wird lokal im Projekt gespeichert und diesem Messwert zugeordnet.", systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if working {
                    Section { ProgressView("Foto wird gespeichert …") }
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground)
            .navigationTitle("Fotos am Messwert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showCamera, onDismiss: saveCameraDraft) {
            CameraPicker(onImage: { data in
                cameraData = data
                showCamera = false
            }, onCancel: {
                showCamera = false
            })
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    photoItem = nil
                    guard let data else {
                        problem = "Das Foto aus der Mediathek konnte nicht geladen werden."
                        return
                    }
                    importImage(data)
                }
            }
        }
        .alert("Foto konnte nicht gespeichert werden", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    @ViewBuilder
    private func thumbnail(_ photo: MCPhoto) -> some View {
        if let image = PhotoImageStore.load(photo.imageFileName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func associate(_ photo: MCPhoto) {
        do { try store.associateWorksitePhoto(photo, with: measurement) }
        catch { problem = error.localizedDescription }
    }

    private func remove(_ photo: MCPhoto) {
        do { try store.removeWorksitePhoto(photo, from: measurement) }
        catch { problem = error.localizedDescription }
    }

    private func saveCameraDraft() {
        guard let cameraData else { return }
        self.cameraData = nil
        importImage(cameraData)
    }

    private func importImage(_ data: Data) {
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.88) else {
            problem = "Das Bild konnte nicht gelesen werden."
            return
        }
        working = true
        do {
            _ = try store.addWorksiteMeasurementPhoto(measurement, imageData: jpeg)
        } catch {
            problem = error.localizedDescription
        }
        working = false
    }
}

private struct WorksiteMeasurementCheckSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let measurement: MCMeasurement
    @State private var targetText: String
    @State private var toleranceText: String
    @State private var problem: String?

    init(measurement: MCMeasurement) {
        self.measurement = measurement
        _targetText = State(initialValue: measurement.targetValue.map { String($0) } ?? "")
        _toleranceText = State(initialValue: measurement.targetTolerance.map { String($0) } ?? "")
    }

    private var target: Double? { DeFormat.parse(targetText) }
    private var tolerance: Double? { DeFormat.parse(toleranceText) }
    private var fieldsAreEmpty: Bool {
        targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && toleranceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var fieldsAreValid: Bool {
        if fieldsAreEmpty { return true }
        guard let target, let tolerance else { return false }
        return target.isFinite && (0...1_000_000_000).contains(target)
            && tolerance.isFinite && (0...1_000_000_000).contains(tolerance)
    }
    private var result: Bool? {
        guard let target, let tolerance, fieldsAreValid else { return nil }
        return abs(measurement.value - target) <= tolerance
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Istmaß") {
                    LabeledContent("Erfasster Wert") {
                        Text("\(DeFormat.number(measurement.value)) \(measurement.unit)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Theme.accent)
                    }
                    Text("Ein Sollwert wird nicht vorausgefüllt. Trage Sollwert und Toleranz ausdrücklich ein, um das Maß zu bewerten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Sollmaß") {
                    HStack {
                        Text("Sollwert")
                        TextField("Optional", text: $targetText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text(measurement.unit)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Toleranz ±")
                        TextField("Optional", text: $toleranceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text(measurement.unit)
                            .foregroundStyle(.secondary)
                    }
                    if let result {
                        Label(result ? "Innerhalb der definierten Toleranz" : "Außerhalb der definierten Toleranz",
                              systemImage: result ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(result ? .green : .red)
                    } else if fieldsAreEmpty {
                        Label("Keine Sollprüfung – kein Ergebnis bewertet", systemImage: "minus.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if !fieldsAreValid {
                        Label("Bitte Sollwert und Toleranz als gültige, nicht negative Werte eingeben.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Label("Sollwert und Toleranz gemeinsam angeben.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Soll-Ist-Prüfung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern", action: save)
                        .disabled(!fieldsAreValid)
                }
            }
        }
    }

    private func save() {
        if fieldsAreEmpty {
            do {
                try store.setWorksiteMeasurementCheck(measurement, targetValue: nil, tolerance: nil)
                dismiss()
            } catch { problem = error.localizedDescription }
            return
        }
        guard let target, let tolerance, fieldsAreValid else {
            problem = "Bitte gib Sollwert und Toleranz gemeinsam als gültige Werte ein."
            return
        }
        do {
            try store.setWorksiteMeasurementCheck(measurement, targetValue: target, tolerance: tolerance)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

private struct AddWorksiteMeasurementSheet: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject
    @State private var label = ""
    @State private var value = ""
    @State private var unit = "mm"
    @State private var selectedPartID: UUID?
    @State private var note = ""
    @State private var problem: String?

    private var sortedParts: [MCPart] {
        project.parts.sorted {
            if $0.positionNumber != $1.positionNumber { return $0.positionNumber < $1.positionNumber }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Messwert") {
                    TextField("Bezeichnung · z. B. lichte Breite", text: $label)
                        .textInputAutocapitalization(.sentences)
                    HStack {
                        Text("Wert")
                        TextField("Messwert", text: $value)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        TextField("Einheit", text: $unit)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 62)
                            .accessibilityLabel("Einheit")
                    }
                }

                Section("Zuordnung") {
                    Picker("Bauteil", selection: $selectedPartID) {
                        Text("Kein Bauteil").tag(nil as UUID?)
                        ForEach(sortedParts) { part in
                            Text("Pos. \(part.positionNumber) · \(part.name)")
                                .tag(Optional(part.id))
                        }
                    }
                    TextField("Notiz (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Messung erfassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern", action: save)
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || DeFormat.parse(value) == nil
                                  || unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let parsedValue = DeFormat.parse(value) else {
            problem = "Bitte gib einen gültigen Messwert ein."
            return
        }
        let part = selectedPartID.flatMap { id in project.parts.first { $0.id == id } }
        do {
            _ = try store.addWorksiteMeasurement(project, label: label, value: parsedValue,
                                                 unit: unit, part: part, note: note)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
