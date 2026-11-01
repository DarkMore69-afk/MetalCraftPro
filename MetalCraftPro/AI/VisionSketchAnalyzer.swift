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
import CoreImage
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
            let factor = CGFloat(2600) / CGFloat(maxDimension)
            let newSize = CGSize(
                width: CGFloat(cgImage.width) * factor,
                height: CGFloat(cgImage.height) * factor
            )
            guard newSize.width >= 1, newSize.height >= 1 else { return nil }
            let renderer = UIGraphicsImageRenderer(size: newSize)
            scaled = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        return scaled.jpegData(compressionQuality: 0.9)
    }

    // MARK: - Analyse

    private static func analyzeSynchronously(imageData: Data) throws -> RecognitionResult {
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
            throw AnalysisError.unreadableImage
        }
        let width = Double(cgImage.width), height = Double(cgImage.height)
        let recognitionImage = enhancedForRecognition(cgImage) ?? cgImage

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        textRequest.recognitionLanguages = ["de-DE", "en-US"]

        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.minimumConfidence = 0.45
        rectangleRequest.minimumAspectRatio = 0.15
        rectangleRequest.maximumAspectRatio = 1.0
        rectangleRequest.minimumSize = 0.08
        rectangleRequest.quadratureTolerance = 20

        let contourRequest = VNDetectContoursRequest()
        contourRequest.detectsDarkOnLight = true

        let handler = VNImageRequestHandler(cgImage: recognitionImage, orientation: .up, options: [:])
        try handler.perform([textRequest, rectangleRequest, contourRequest])

        var elements: [RecognizedElement] = []

        // 1. Text: Maßzahlen, Profilangaben, Winkel, Beschriftungen.
        let textObservations = textRequest.results ?? []
        for observation in textObservations.prefix(100) {
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
                var recognized = RecognizedElement(kind: kind, rawText: raw,
                                                     valueMm: DimensionTextParser.valueMm(of: parsed),
                                                     profileDimensionsMm: profile, angleDeg: angle,
                                                     anchor: anchor, confidence: confidence)
                // Strengere Plausibilität: typische Metallbau-Skizzen selten > 8 m
                if recognized.kind == .length, let value = recognized.valueMm, value >= 8000 || value < 10 {
                    recognized.needsReview = true
                    recognized.accepted = false
                    recognized.reviewNote = "Unplausibles Maß. Bitte mit der Skizze abgleichen oder manuell korrigieren."
                }
                elements.append(recognized)
            } else if raw.count <= 28 {
                elements.append(RecognizedElement(kind: .text, rawText: raw, anchor: anchor, confidence: confidence))
            }
        }

        // 2. Rechtecke
        let rectangles = (rectangleRequest.results ?? []).prefix(6)
        for observation in rectangles {
            let origin = RecognizedPoint(x: observation.boundingBox.origin.x,
                                         y: 1 - observation.boundingBox.maxY)
            let size = RecognizedSize(width: observation.boundingBox.width, height: observation.boundingBox.height)
            guard isValid(size: size) else { continue }
            elements.append(RecognizedElement(kind: .rectangle,
                                              shape: .rectangle(origin: origin, width: size.width, height: size.height),
                                              anchor: center(of: origin, size: size),
                                              confidence: Double(observation.confidence)))
        }

        // 3. Konturen → Segmente, Kreise, Rechtecke
        let contourObservations = contourRequest.results ?? []
        let hadDetectorRectangle = elements.contains { $0.kind == .rectangle }
        for observation in contourObservations {
            let count = min(observation.contourCount, 180)
            var contours: [(points: [RecognizedPoint], area: Double)] = []
            for index in 0 ..< count {
                guard let contour = try? observation.contour(at: index) else { continue }
                let points = points(of: contour.normalizedPath, width: width, height: height)
                guard points.count >= 3 else { continue }
                contours.append((points, polygonArea(points)))
            }
            let largest = contours.sorted { $0.area > $1.area }.prefix(35)
            for contour in largest {
                appendShapes(from: contour.points, width: width, height: height,
                             into: &elements, allowRectangle: !hadDetectorRectangle)
            }
        }

        // Stärkere Raster-Unterdrückung
        let drawingElements = suppressRuledPaperLines(elements, imageWidthPx: width, imageHeightPx: height)

        // 4. Zuordnung Zahlen ↔ Geometrie, Maßstab, Namen.
        let linked = SketchGeometryLinker.assign(drawingElements, imageWidthPx: width, imageHeightPx: height)
        let names = SketchGeometryLinker.names(for: linked.elements)
        var final = linked.elements
        for index in final.indices { final[index].name = names[final[index].id] ?? final[index].name }
        let limited = limit(final)
        return RecognitionResult(imageWidthPx: width, imageHeightPx: height, mmPerPixel: linked.mmPerPixel, elements: limited)
    }

    private static func enhancedForRecognition(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let controls = CIFilter(name: "CIColorControls") else { return nil }
        controls.setValue(input, forKey: kCIInputImageKey)
        controls.setValue(0.0, forKey: kCIInputSaturationKey)
        controls.setValue(1.15, forKey: kCIInputContrastKey)
        controls.setValue(0.02, forKey: kCIInputBrightnessKey)
        guard let contrasted = controls.outputImage,
              let sharpen = CIFilter(name: "CISharpenLuminance") else { return nil }
        sharpen.setValue(contrasted, forKey: kCIInputImageKey)
        sharpen.setValue(0.18, forKey: kCIInputSharpnessKey)
        guard let output = sharpen.outputImage else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(output, from: input.extent)
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
        size.width.isFinite && size.height.isFinite && size.width > 0.015 && size.height > 0.015
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
        let tolerance = 0.005 * maxDimension
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
            if circularity > 0.80, boxWidth > 0.012 * maxDimension {
                let radius = polygon.reduce(0.0) {
                    $0 + hypot(($1.x - centroid.x) * width, ($1.y - centroid.y) * height)
                } / Double(polygon.count)
                let confidence = min(0.95, max(0.3, 1 - abs(1 - circularity) * 3))
                elements.append(RecognizedElement(kind: .circle,
                                                  shape: .circle(center: centroid, radius: radius / width),
                                                  anchor: centroid, confidence: confidence))
                return
            }
            if allowRectangle, polygon.count <= 14, boxWidth > 0.08 * maxDimension, boxHeight > 0.08 * maxDimension {
                let origin = RecognizedPoint(x: xs.min()!, y: ys.min()!)
                let size = RecognizedSize(width: boxWidth / width, height: boxHeight / height)
                elements.append(RecognizedElement(kind: .rectangle,
                                                  shape: .rectangle(origin: origin, width: size.width, height: size.height),
                                                  anchor: center(of: origin, size: size), confidence: 0.82))
                return
            }
        }

        let minLength = 0.038 * maxDimension
        for segment in PolylineAnalysis.segments(from: polygon, minLength: minLength, maxCount: 20) {
            let start = RecognizedPoint(x: segment.x1 / width, y: segment.y1 / height)
            let end = RecognizedPoint(x: segment.x2 / width, y: segment.y2 / height)
            let anchor = RecognizedPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            elements.append(RecognizedElement(kind: .line, shape: .segment(start: start, end: end),
                                              anchor: anchor, confidence: segment.confidence))
        }
    }

    /// Entfernt wiederkehrende, gleichmäßig beabstandete Linien von kariertem Papier.
    private static func suppressRuledPaperLines(_ elements: [RecognizedElement],
                                                imageWidthPx: Double, imageHeightPx: Double) -> [RecognizedElement] {
        var groups: [Int: [(index: Int, position: Double, extent: Double)]] = [0: [], 1: []]
        for (index, element) in elements.enumerated() {
            guard element.kind == .line,
                  case .segment(let start, let end)? = element.shape else { continue }
            let dx = abs(end.x - start.x), dy = abs(end.y - start.y)
            if dx >= dy {
                groups[0, default: []].append((index, (start.y + end.y) / 2, dx))
            } else {
                groups[1, default: []].append((index, (start.x + end.x) / 2, dy))
            }
        }
        var ruledIndices = Set<Int>()
        for group in groups.values where group.count >= 8 {
            let ordered = group.sorted { $0.position < $1.position }
            let gaps = zip(ordered, ordered.dropFirst()).map { $1.position - $0.position }
            guard !gaps.isEmpty else { continue }
            let medianGap = gaps.sorted()[gaps.count / 2]
            guard (0.002...0.05).contains(medianGap) else { continue }
            let regularGapIndices = gaps.indices.filter { abs(gaps[$0] - medianGap) <= medianGap * 0.35 }
            let coverage = (ordered.last!.position - ordered.first!.position)
            let meanExtent = ordered.reduce(0.0) { $0 + $1.extent } / Double(ordered.count)
            guard regularGapIndices.count >= 5, coverage >= 0.55, meanExtent >= 0.08 else { continue }
            for gapIndex in regularGapIndices {
                ruledIndices.insert(ordered[gapIndex].index)
                ruledIndices.insert(ordered[gapIndex + 1].index)
            }
        }
        return elements.enumerated().compactMap { ruledIndices.contains($0.offset) ? nil : $0.element }
    }

    /// Begrenzt die Elementliste – bevorzugt Elemente mit Maß.
    private static func limit(_ elements: [RecognizedElement]) -> [RecognizedElement] {
        let shapes = elements.filter { $0.shape != nil }
        let texts = elements.filter { $0.shape == nil }
        let shapeBudget = 32
        let ranked = shapes.enumerated().sorted { score($0.element) > score($1.element) }
        let keptShapes = ranked.prefix(shapeBudget).map(\.element)
        let keptIDs = Set(keptShapes.map(\.id))
        let keptTexts = texts.filter { element in
            guard let assigned = element.assignedID else { return true }
            return keptIDs.contains(assigned)
        }
        return keptShapes + keptTexts
    }

    private static func score(_ element: RecognizedElement) -> Double {
        var base: Double = 0
        switch element.shape {
        case .segment(let start, let end):
            base = hypot(end.x - start.x, end.y - start.y)
        case .rectangle(_, let width, let height):
            base = width * height
        case .circle(_, let radius):
            base = radius * radius * .pi
        case nil:
            base = 0
        }
        // Bonus für Elemente mit zugeordnetem Maß
        if element.valueMm != nil { base *= 2.2 }
        if element.isUncertain { base *= 0.6 }
        return base
    }
}
