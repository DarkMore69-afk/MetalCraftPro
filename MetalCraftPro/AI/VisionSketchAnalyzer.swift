//
//  VisionSketchAnalyzer.swift
//  MetalCraft Pro
//
//  Lokale Bildanalyse mit Vision: Text/OCR, Rechtecke und Konturen. Alle Bilder
//  bleiben auf dem Gerät. Ergebnis sind strukturierte Erkennungsobjekte aus der
//  Domain-Schicht – niemals fertige Geometrie.
//

import Foundation
import Vision
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Analysiert Skizzenbilder lokal. Läuft als detachierter Task, damit die UI flüssig bleibt.
enum SketchScanService {
    static func analyze(imageData: Data) async throws -> RecognitionResult {
        try await Task.detached(priority: .userInitiated) {
            try analyzeSynchronously(imageData: imageData)
        }.value
    }

    /// Normalisiert Kamera-, Bibliotheks- und Dateiimporte auf JPEG mit sinnvoller Auflösung.
    static func normalizedJPEG(from fileData: Data) -> Data? {
        if let document = PDFDocument(data: fileData), let page = document.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = min(2400 / max(bounds.width, 1), 4)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(CGRect(origin: .zero, size: size))
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: scale, y: -scale)
                context.cgContext.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
            return image.jpegData(compressionQuality: 0.9)
        }
        guard let image = UIImage(data: fileData), let cgImage = image.cgImage else { return nil }
        let maxDimension = max(cgImage.width, cgImage.height)
        var scaled = image
        if maxDimension > 2600 {
            let factor = 2600 / maxDimension
            let newSize = CGSize(width: cgImage.width * factor, height: cgImage.height * factor)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        return scaled.jpegData(compressionQuality: 0.9)
    }

    // MARK: - Analyse

    private static func analyzeSynchronously(imageData: Data) throws -> RecognitionResult {
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
            throw AnalysisError.unreadableImage
        }
        let width = Double(cgImage.width), height = Double(cgImage.height)

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        textRequest.recognitionLanguages = ["de-DE", "en-US"]

        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.minimumConfidence = 0.4
        rectangleRequest.minimumAspectRatio = 0.2
        rectangleRequest.maximumAspectRatio = 1.0
        rectangleRequest.minimumSize = 0.1
        rectangleRequest.quadratureTolerance = 25

        let contourRequest = VNDetectContoursRequest()
        contourRequest.detectsDarkOnLight = true

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([textRequest, rectangleRequest, contourRequest])

        var elements: [RecognizedElement] = []

        // 1. Text: Maßzahlen, Profilangaben, Winkel, Beschriftungen.
        let textObservations = textRequest.results ?? []
        for observation in textObservations.prefix(80) {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let raw = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let anchor = anchorPoint(observation.boundingBox, height: height)
            let confidence = Double(observation.confidence)
            if let parsed = DimensionTextParser.parse(raw) {
                let kind = DimensionTextParser.elementKind(for: parsed)
                var profile: [Double]?
                var angle: Double?
                if case .profile(let w, let h, let t) = parsed { profile = [w, h, t] }
                if case .angleDeg(let value) = parsed { angle = value }
                elements.append(RecognizedElement(kind: kind, rawText: raw,
                                                  valueMm: DimensionTextParser.valueMm(of: parsed),
                                                  profileDimensionsMm: profile, angleDeg: angle,
                                                  anchor: anchor, confidence: confidence))
            } else if raw.count <= 24 {
                // Handschrift oder Beschriftung ohne Maßbezug – bleibt reiner Text.
                elements.append(RecognizedElement(kind: .text, rawText: raw, anchor: anchor, confidence: confidence))
            }
        }

        // 2. Rechtecke aus dem spezialisierten Detector.
        let rectangles = (rectangleRequest.results ?? []).prefix(4)
        for observation in rectangles.prefix(4) {
            let origin = RecognizedPoint(x: observation.boundingBox.origin.x,
                                         y: 1 - observation.boundingBox.maxY)
            let size = RecognizedSize(width: observation.boundingBox.width, height: observation.boundingBox.height)
            guard isValid(size: size) else { continue }
            elements.append(RecognizedElement(kind: .rectangle,
                                              shape: .rectangle(origin: origin, width: size.width, height: size.height),
                                              anchor: center(of: origin, size: size),
                                              confidence: Double(observation.confidence)))
        }

        // 3. Konturen → Segmente, Kreise, (falls nötig) Rechtecke.
        let contourObservations = contourRequest.results ?? []
        let hadDetectorRectangle = elements.contains { $0.kind == .rectangle }
        for observation in contourObservations {
            let count = min(observation.contourCount, 200)
            var contours: [(points: [RecognizedPoint], area: Double)] = []
            for index in 0 ..< count {
                guard let contour = try? observation.contour(at: index) else { continue }
                let points = points(of: contour.normalizedPath, width: width, height: height)
                guard points.count >= 3 else { continue }
                contours.append((points, polygonArea(points)))
            }
            let largest = contours.sorted { $0.area > $1.area }.prefix(40)
            for contour in largest {
                appendShapes(from: contour.points, width: width, height: height,
                             into: &elements, allowRectangle: !hadDetectorRectangle)
            }
        }

        // 4. Zuordnung Zahlen ↔ Geometrie, Maßstab, Namen.
        let linked = SketchGeometryLinker.assign(elements, imageWidthPx: width, imageHeightPx: height)
        let names = SketchGeometryLinker.names(for: linked.elements)
        var final = linked.elements
        for index in final.indices { final[index].name = names[final[index].id] ?? final[index].name }
        let limited = limit(final)
        return RecognitionResult(imageWidthPx: width, imageHeightPx: height, mmPerPixel: linked.mmPerPixel, elements: limited)
    }

    private enum AnalysisError: LocalizedError {
        case unreadableImage
        var errorDescription: String? { "Das Bild konnte nicht gelesen werden." }
    }

    private struct RecognizedSize {
        var width: Double
        var height: Double
    }

    private static func isValid(size: RecognizedSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0.02 && size.height > 0.02
    }

    private static func anchorPoint(_ box: CGRect, height: Double) -> RecognizedPoint {
        RecognizedPoint(x: box.midX, y: 1 - box.midY)
    }

    private static func center(of origin: RecognizedPoint, size: RecognizedSize) -> RecognizedPoint {
        .init(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    private static func points(of path: CGPath, width: Double, height: Double) -> [RecognizedPoint] {
        let collector = PointCollector()
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                collector.append(element.pointee.points[0])
            case .addQuadCurveToPoint:
                collector.append(element.pointee.points[1])
            case .addCurveToPoint:
                collector.append(element.pointee.points[2])
            default: break
            }
        }
        return collector.points.compactMap { point in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return RecognizedPoint(x: point.x * width, y: (1 - point.y) * height)
        }
    }

    private final class PointCollector {
        var points: [CGPoint] = []
        func append(_ point: CGPoint) { points.append(point) }
    }

    private static func polygonArea(_ points: [RecognizedPoint]) -> Double {
        guard points.count > 2 else { return 0 }
        var sum = 0.0
        for (a, b) in zip(points, points.dropFirst() + [points[0]]) {
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    private static func appendShapes(from points: [RecognizedPoint], width: Double, height: Double,
                                     into elements: inout [RecognizedElement], allowRectangle: Bool) {
        let maxDimension = max(width, height)
        let tolerance = 0.006 * maxDimension
        let simplified = PolylineAnalysis.simplify(points, tolerance: tolerance)
        guard simplified.count >= 2 else { return }
        let closed = hypot(simplified[0].x - simplified.last!.x, simplified[0].y - simplified.last!.y) * maxDimension < tolerance * 2
        let polygon = closed && simplified.count > 2 ? simplified : simplified

        if closed, polygon.count >= 3 {
            let xs = polygon.map(\.x), ys = polygon.map(\.y)
            let boxWidth = (xs.max()! - xs.min()!) * width
            let boxHeight = (ys.max()! - ys.min()!) * height
            let area = polygonArea(polygon) * width * height
            let perimeter = zip(polygon, polygon.dropFirst() + [polygon[0]]).reduce(0.0) {
                $0 + hypot(($1.1.x - $1.0.x) * width, ($1.1.y - $1.0.y) * height)
            }
            let circularity = perimeter > 0 ? 4 * .pi * area / (perimeter * perimeter) : 0
            let centroid = RecognizedPoint(x: xs.reduce(0, +) / Double(polygon.count),
                                           y: ys.reduce(0, +) / Double(polygon.count))
            if circularity > 0.82, boxWidth > 0.015 * maxDimension {
                let radius = polygon.reduce(0.0) {
                    $0 + hypot(($1.x - centroid.x) * width, ($1.y - centroid.y) * height)
                } / Double(polygon.count)
                let confidence = min(0.95, max(0.3, 1 - abs(1 - circularity) * 3))
                elements.append(RecognizedElement(kind: .circle,
                                                  shape: .circle(center: centroid, radius: radius / width),
                                                  anchor: centroid, confidence: confidence))
                return
            }
            if allowRectangle, polygon.count <= 12, boxWidth > 0.1 * maxDimension, boxHeight > 0.1 * maxDimension {
                let origin = RecognizedPoint(x: xs.min()!, y: ys.min()!)
                let size = RecognizedSize(width: boxWidth / width, height: boxHeight / height)
                elements.append(RecognizedElement(kind: .rectangle,
                                                  shape: .rectangle(origin: origin, width: size.width, height: size.height),
                                                  anchor: center(of: origin, size: size), confidence: 0.85))
                return
            }
        }

        let minLength = 0.045 * maxDimension
        for segment in PolylineAnalysis.segments(from: polygon, minLength: minLength, maxCount: 24) {
            let start = RecognizedPoint(x: segment.x1 / width, y: segment.y1 / height)
            let end = RecognizedPoint(x: segment.x2 / width, y: segment.y2 / height)
            let anchor = RecognizedPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            elements.append(RecognizedElement(kind: .line, shape: .segment(start: start, end: end),
                                              anchor: anchor, confidence: segment.confidence))
        }
    }

    /// Begrenzt die Elementliste auf die relevantesten Einträge, damit der Prüf-Screen
    /// übersichtlich bleibt (längste Linien, größte Formen zuerst).
    private static func limit(_ elements: [RecognizedElement]) -> [RecognizedElement] {
        let shapes = elements.filter { $0.shape != nil }
        let texts = elements.filter { $0.shape == nil }
        let shapeBudget = 40
        let ranked = shapes.enumerated().sorted { score($0.element) > score($1.element) }
        let keptShapes = ranked.prefix(shapeBudget).map(\.element)
        let keptIDs = Set(keptShapes.map(\.id))
        // Zahlen, die einer verworfenen Form zugeordnet waren, bleiben eigenständig erhalten.
        let keptTexts = texts.filter { element in
            guard let assigned = element.assignedID else { return true }
            return keptIDs.contains(assigned)
        }
        return keptShapes + keptTexts
    }

    private static func score(_ element: RecognizedElement) -> Double {
        switch element.shape {
        case .segment(let start, let end):
            return hypot(end.x - start.x, end.y - start.y)
        case .rectangle(_, let width, let height):
            return width * height
        case .circle(_, let radius):
            return radius * radius * .pi
        case nil:
            return 0
        }
    }
}
