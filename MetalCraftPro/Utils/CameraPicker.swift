//
//  CameraPicker.swift
//  MetalCraft Pro
//
//  Dünner UIImagePickerController-Wrapper für den Kameraimport. Bilder bleiben lokal.
//

import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    var onCancel: () -> Void

    static func isAvailable() -> Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIViewControllerType, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, onCancel: onCancel) }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onImage: (Data) -> Void
        private let onCancel: () -> Void
        init(onImage: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage; self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) else {
                onCancel(); return
            }
            onImage(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onCancel()
        }
    }
}

/// Lokale Ablage für Skizzenbilder unter Application Support. Kein Cloud-Bezug.
enum SketchImageStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Skizzen", isDirectory: true)
    }

    static func save(_ data: Data) throws -> String {
        let name = "\(UUID().uuidString).jpg"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: name), options: .atomic)
        return name
    }

    static func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    static func load(_ name: String?) -> UIImage? {
        guard let name else { return nil }
        return UIImage(contentsOfFile: url(for: name).path)
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: url(for: name))
    }
}

/// Lokale Ablage für Fertigungsfotos unter Application Support – gleiche Muster
/// wie die Skizzenablage: Zufallsname, atomares Schreiben, keine Cloud-Bezüge.
enum PhotoImageStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Fotos", isDirectory: true)
    }

    static func save(_ data: Data) throws -> String {
        let name = "\(UUID().uuidString).jpg"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: name), options: .atomic)
        return name
    }

    static func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    static func load(_ name: String?) -> UIImage? {
        guard let name else { return nil }
        return UIImage(contentsOfFile: url(for: name).path)
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: url(for: name))
    }
}
