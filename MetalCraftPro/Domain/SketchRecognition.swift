//
//  SketchRecognition.swift
//  MetalCraft Pro
//
//  Strukturierte Erkennungsobjekte der Skizzenanalyse. Diese Schicht enthält noch
//  KEINE Geometrie: Sie beschreibt nur, was der Scanner erkannt hat. Erst die
//  Übernahme (SketchAdoption) validiert die Daten über Geometry2D und erzeugt
//  daraus Geometrie. Fehlende Maße werden niemals ergänzt.
//

import Foundation

// MARK: - Erkennungsobjekte

/// Normierte Bildkoordinate (0…1), Ursprung oben links, unabhängig von der Pixelgröße.
public struct RecognizedPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
    }
}

/// Roherkennnte Form in Bildkoordinaten – noch ohne mm-Bezug.
public enum RecognizedShape: Hashable, Codable, Sendable {
    case segment(start: RecognizedPoint, end: RecognizedPoint)
    case rectangle(origin: RecognizedPoint, width: Double, height: Double)
    case circle(center: RecognizedPoint, radius: Double)
}

/// Ein erkanntes Element: Form, Zahl, Profilangabe oder Beschriftung.
public struct RecognizedElement: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case line, rectangle, circle
        case length, diameter, angle, profile, text
    }

    public var id: UUID = UUID()
    public var kind: Kind
    public var shape: RecognizedShape?
    public var rawText: String?
    /// Länge bzw. Durchmesser in mm – nur wenn die Zahl einem Element zugeordnet wurde.
    public var valueMm: Double?
    /// Profilangabe wie 40x40x2.
    public var profileDimensionsMm: [Double]?
    public var angleDeg: Double?
    /// Mittelpunkt (Form oder Textbox) in normierten Bildkoordinaten.
    public var anchor: RecognizedPoint
    /// Konfidenz 0…1. Werte unter 0,7 gelten als unsicher und lösen einen Prüfhinweis aus.
    public var confidence: Double
    public var needsReview: Bool = false
    public var reviewNote: String?
    /// Zahl → zugeordnetes Geometrie-Element.
    public var assignedID: UUID?
    public var accepted: Bool = true
    public var name: String = ""

    public init(id: UUID = UUID(), kind: Kind, shape: RecognizedShape? = nil, rawText: String? = nil,
                valueMm: Double? = nil, profileDimensionsMm: [Double]? = nil, angleDeg: Double? = nil,
                anchor: RecognizedPoint, confidence: Double, accepted: Bool = true, name: String = "") {
        self.id = id; self.kind = kind; self.shape = shape; self.rawText = rawText
        self.valueMm = valueMm?.isFinite == true ? valueMm : nil
        self.profileDimensionsMm = profileDimensionsMm; self.angleDeg = angleDeg
        self.anchor = anchor
        self.confidence = min(1, max(0, confidence.isFinite ? confidence : 0))
        self.accepted = accepted; self.name = name
    }

    public var isUncertain: Bool { needsReview || confidence < 0.7 }
}

/// Gesamtergebnis einer Analyse – codierbar, damit es am MCSketch persistiert wird.
public struct RecognitionResult: Equatable, Codable, Sendable {
    public var imageWidthPx: Double
    public var imageHeightPx: Double
    /// Aus zugeordneten Maßzahlen abgeleiteter Maßstab; nil, wenn keine Zahl zugeordnet wurde.
    public var mmPerPixel: Double?
    public var elements: [RecognizedElement]

    public init(imageWidthPx: Double, imageHeightPx: Double, mmPerPixel: Double? = nil, elements: [RecognizedElement]) {
        self.imageWidthPx = imageWidthPx; self.imageHeightPx = imageHeightPx
        self.mmPerPixel = mmPerPixel; self.elements = elements
    }
}

// MARK: - Maßtext-Parser

/// Deterministischer Parser für Metallbau-Maßangaben: 1200, 1.200, 40x40x2, 45°, Ø10, M10.
public enum DimensionTextParser {
    public enum Parsed: Equatable {
        case profile(widthMm: Double, heightMm: Double, thicknessMm: Double)
        case lengthMm(Double)
        case diameterMm(Double)
        case angleDeg(Double)
    }

    public static func parse(_ raw: String) -> Parsed? {
        var text = raw.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "*", with: "x")
            .replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: CharacterSet.whitespaces).joined()
        // Tausenderpunkte wie in "1.200" entfernen.
        if let regex = try? NSRegularExpression(pattern: #"^(\d{1,3})(\.\d{3})+$"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            text = (text as NSString).replacingOccurrences(of: ".", with: "", range: match.range)
        }
        let number = #"\d+(?:\.\d+)?"#

        if let m = groups(in: text, pattern: "^\(number)x\(number)x\(number)$") {
            let values = m.compactMap { Double($0) }
            if values.count == 3, values.allSatisfy({ $0 > 0 && $0.isFinite }) {
                return .profile(widthMm: values[0], heightMm: values[1], thicknessMm: values[2])
            }
        }
        if let m = groups(in: text, pattern: "^m(\(number))$"), let value = Double(m[0]), value.isFinite, value > 0 {
            return .diameterMm(value) // Gewinde M10 → Kernlochbezug Ø10
        }
        if let m = groups(in: text, pattern: "^[⌀øøø](\(number))$"), let value = Double(m[0]), value.isFinite, value > 0 {
            return .diameterMm(value)
        }
        if let m = groups(in: text, pattern: "^(\(number))°$"), let value = Double(m[0]), value.isFinite, value > 0, value < 360 {
            return .angleDeg(value)
        }
        if let value = Double(text), value.isFinite, value > 0, value <= 100_000 {
            return .lengthMm(value)
        }
        return nil
    }

    public static func elementKind(for parsed: Parsed) -> RecognizedElement.Kind {
        switch parsed {
        case .profile: return .profile
        case .lengthMm: return .length
        case .diameterMm: return .diameter
        case .angleDeg: return .angle
        }
    }

    public static func valueMm(of parsed: Parsed) -> Double? {
        switch parsed {
        case .profile: return nil
        case .lengthMm(let v), .diameterMm(let v): return v
        case .angleDeg: return nil
        }
    }

    private static func groups(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1 ..< match.numberOfRanges).compactMap { index -> String? in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let converted = Range(range, in: text) else { return nil }
            return String(text[converted])
        }
    }
}

// MARK: - Kontur-Analyse (reine Geometrie, von Vision unabhängig)

public struct RawSegment: Equatable, Sendable {
    public var x1: Double, y1: Double, x2: Double, y2: Double
    public var confidence: Double
    public init(x1: Double, y1: Double, x2: Double, y2: Double, confidence: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        self.confidence = min(1, max(0, confidence.isFinite ? confidence : 0))
    }
    public var length: Double { hypot(x2 - x1, y2 - y1) }
}

/// Douglas-Peucker-Vereinfachung und kollineare Segmentzusammenführung – deterministisch.
public enum PolylineAnalysis {
    public static func simplify(_ points: [RecognizedPoint], tolerance: Double) -> [RecognizedPoint] {
        guard points.count > 2, tolerance.isFinite, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maxDistance = 0.0, maxIndex = start
            for index in (start + 1) ..< end {
                let distance = (try? Geometry2D.distance(from: vec(points[index]),
                                                         toSegment: vec(points[start]), vec(points[end]))) ?? 0
                if distance > maxDistance { maxDistance = distance; maxIndex = index }
            }
            if maxDistance > tolerance {
                keep[maxIndex] = true
                stack.append((start, maxIndex)); stack.append((maxIndex, end))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    /// Lange Teilstücke eines vereinfachten Zuges, kollinear zusammengeführt.
    public static func segments(from polygon: [RecognizedPoint], minLength: Double, maxCount: Int) -> [RawSegment] {
        guard polygon.count >= 2, minLength.isFinite, minLength > 0 else { return [] }
        var raw: [RawSegment] = []
        for (a, b) in zip(polygon, polygon.dropFirst()) {
            let segment = RawSegment(x1: a.x, y1: a.y, x2: b.x, y2: b.y, confidence: 1)
            if segment.length >= minLength { raw.append(segment) }
        }
        let merged = mergeCollinear(raw, angleToleranceDeg: 2, offsetTolerance: minLength * 0.4, gapTolerance: minLength * 0.6)
        return merged.sorted { $0.length > $1.length }.prefix(maxCount).map {
            RawSegment(x1: $0.x1, y1: $0.y1, x2: $0.x2, y2: $0.y2, confidence: $0.confidence)
        }
    }

    public static func mergeCollinear(_ input: [RawSegment], angleToleranceDeg: Double, offsetTolerance: Double, gapTolerance: Double) -> [RawSegment] {
        var segments = input
        var changed = true
        while changed {
            changed = false
            outer: for i in segments.indices {
                for j in segments.indices where i < j {
                    if let merged = merge(segments[i], segments[j], angleToleranceDeg: angleToleranceDeg,
                                          offsetTolerance: offsetTolerance, gapTolerance: gapTolerance) {
                        segments[i] = merged
                        segments.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return segments
    }

    private static func merge(_ a: RawSegment, _ b: RawSegment, angleToleranceDeg: Double, offsetTolerance: Double, gapTolerance: Double) -> RawSegment? {
        let directionA = Vec2(x: a.x2 - a.x1, y: a.y2 - a.y1)
        let directionB = Vec2(x: b.x2 - b.x1, y: b.y2 - b.y1)
        guard directionA.magnitude > 0, directionB.magnitude > 0 else { return nil }
        guard (try? Geometry2D.areParallel(directionA, directionB, toleranceDeg: angleToleranceDeg)) == true else { return nil }
        let midpointB = Vec2(x: (b.x1 + b.x2) / 2, y: (b.y1 + b.y2) / 2)
        guard let offset = try? Geometry2D.distance(from: midpointB, toSegment: .init(x: a.x1, y: a.y1), .init(x: a.x2, y: a.y2)),
              offset <= offsetTolerance else { return nil }
        let unit = (try? directionA.normalized()) ?? .zero
        let startProjection = unit.dot(Vec2(x: b.x1 - a.x1, y: b.y1 - a.y1))
        let endProjection = unit.dot(Vec2(x: b.x2 - a.x1, y: b.y2 - a.y1))
        let lengthA = a.length
        let low = min(startProjection, endProjection), high = max(startProjection, endProjection)
        guard low <= lengthA + gapTolerance, high >= -gapTolerance else { return nil }
        let start = max(-gapTolerance, low), end = min(lengthA + gapTolerance, high)
        let origin = Vec2(x: a.x1, y: a.y1)
        let p1 = origin + unit * start
        let p2 = origin + unit * max(end, start)
        return RawSegment(x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y, confidence: min(a.confidence, b.confidence))
    }

    private static func vec(_ point: RecognizedPoint) -> Vec2 { .init(x: point.x, y: point.y) }
}

// MARK: - Maßzuordnung & Maßstab

/// Ordnet erkannte Zahlen der nächstgelegenen Geometrie zu und leitet daraus den
/// Maßstab ab. Es werden keine fehlenden Maße erfunden: Formen ohne zugeordnete
/// Zahl bleiben ohne mm-Wert.
public enum SketchGeometryLinker {
    public static func assign(_ elements: [RecognizedElement], imageWidthPx: Double, imageHeightPx: Double) -> (elements: [RecognizedElement], mmPerPixel: Double?) {
        var result = elements
        let diagonal = hypot(imageWidthPx, imageHeightPx)
        let threshold = 0.18 * diagonal
        let shapeIndices = result.indices.filter { result[$0].shape != nil }

        // 1. Nächstgelegene Form je Zahl.
        for index in result.indices where result[index].shape == nil && result[index].kind != .text {
            guard let value = result[index].valueMm, value.isFinite, value > 0 else { continue }
            var best: (offset: Int, distance: Double)?
            for shapeIndex in shapeIndices {
                guard var d = distance(from: result[index].anchor, to: result[shapeIndex],
                                       imageWidthPx: imageWidthPx, imageHeightPx: imageHeightPx) else { continue }
                if result[index].kind == .diameter && result[shapeIndex].kind == .circle { d *= 0.5 }
                if d <= threshold, best == nil || d < best!.distance { best = (shapeIndex, d) }
            }
            if let best { result[index].assignedID = result[best.offset].id }
        }

        // 2. Widersprüchliche Maße auf derselben Form markieren.
        var valuesByShape: [UUID: [Double]] = [:]
        for element in result where element.assignedID != nil && element.kind == .length {
            valuesByShape[element.assignedID!, default: []].append(element.valueMm ?? 0)
        }
        for (id, values) in valuesByShape where values.count > 1 {
            let reference = values.max() ?? 0
            for index in result.indices where result[index].assignedID == id && result[index].kind == .length {
                if abs((result[index].valueMm ?? 0) - reference) / max(reference, 1) > 0.02 {
                    result[index].needsReview = true
                    result[index].reviewNote = "Widersprüchliches Maß: erwartet ca. \(Int(reference.rounded())) mm."
                }
            }
        }

        // 3. Maßstab aus den längsten Referenzen ableiten.
        var candidates: [(mmPerPixel: Double, pixelLength: Double, numberIndex: Int)] = []
        for numberIndex in result.indices where result[numberIndex].assignedID != nil {
            guard let shapeIndex = shapeIndices.first(where: { result[$0].id == result[numberIndex].assignedID }),
                  let value = result[numberIndex].valueMm, value > 0 else { continue }
            let pixel = pixelMeasure(of: result[shapeIndex], for: result[numberIndex],
                                     imageWidthPx: imageWidthPx, imageHeightPx: imageHeightPx)
            guard let pixel, pixel > 1 else { continue }
            candidates.append((pixel / value, pixel, numberIndex))
        }
        let sorted = candidates.sorted { $0.pixelLength > $1.pixelLength }
        guard let scale = sorted.first?.mmPerPixel, scale.isFinite, scale > 0 else {
            return (result, nil)
        }
        for candidate in sorted.dropFirst() {
            let expected = candidate.pixelLength / scale
            let actual = candidate.pixelLength / candidate.mmPerPixel
            if abs(expected - actual) / max(actual, 1) > 0.05 {
                result[candidate.numberIndex].needsReview = true
                result[candidate.numberIndex].reviewNote = "Passt nicht zum Maßstab der größten Referenz. Bitte prüfen."
            }
        }
        // 4. mm-Wert auf die Form übertragen (Anzeige und Übernahme).
        for index in result.indices where result[index].shape != nil {
            if let number = result.first(where: { $0.assignedID == result[index].id && ($0.kind == .length || $0.kind == .diameter) }) {
                result[index].valueMm = number.valueMm
            }
        }
        return (result, scale)
    }

    /// Abstand Zahl-Mittelpunkt zur Form in normierten Einheiten × Bilddiagonale (Pixel).
    private static func distance(from anchor: RecognizedPoint, to element: RecognizedElement,
                                 imageWidthPx: Double, imageHeightPx: Double) -> Double? {
        guard let shape = element.shape else { return nil }
        let px = Vec2(x: anchor.x * imageWidthPx, y: anchor.y * imageHeightPx)
        switch shape {
        case .segment(let start, let end):
            guard let d = try? Geometry2D.distance(from: px,
                                                   toSegment: .init(x: start.x * imageWidthPx, y: start.y * imageHeightPx),
                                                   .init(x: end.x * imageWidthPx, y: end.y * imageHeightPx)) else { return nil }
            return d
        case .rectangle(let origin, let width, let height):
            let left = origin.x * imageWidthPx, right = (origin.x + width) * imageWidthPx
            let top = origin.y * imageHeightPx, bottom = (origin.y + height) * imageHeightPx
            let dx = max(left - px.x, 0, px.x - right)
            let dy = max(top - px.y, 0, px.y - bottom)
            return hypot(dx, dy)
        case .circle(let center, let radius):
            let c = Vec2(x: center.x * imageWidthPx, y: center.y * imageHeightPx)
            let r = radius * imageWidthPx
            return abs(px.distance(to: c) - r)
        }
    }

    /// Pixelgröße der Form in Richtung der zugeordneten Zahl.
    private static func pixelMeasure(of element: RecognizedElement, for number: RecognizedElement,
                                     imageWidthPx: Double, imageHeightPx: Double) -> Double? {
        switch element.shape {
        case .segment(let start, let end):
            return hypot((end.x - start.x) * imageWidthPx, (end.y - start.y) * imageHeightPx)
        case .rectangle(let origin, let width, let height):
            let centerX = number.anchor.x, centerY = number.anchor.y
            let distances: [(Double, Double)] = [
                (abs(centerY - origin.y), width),                       // oberer Rand → Breite
                (abs(centerY - (origin.y + height)), width),            // unterer Rand → Breite
                (abs(centerX - origin.x), height),                      // linker Rand → Höhe
                (abs(centerX - (origin.x + width)), height),            // rechter Rand → Höhe
            ]
            return (distances.min(by: { $0.0 < $1.0 })?.1 ?? 0) * imageWidthPx
        case .circle(_, let radius):
            return 2 * radius * imageWidthPx
        case nil:
            return nil
        }
    }

    /// Sprechbare Namen je Element ("Linie unten", "Linie links", "Zahl 800 mm", …).
    public static func names(for elements: [RecognizedElement]) -> [UUID: String] {
        var names: [UUID: String] = [:]
        let lines = elements.enumerated().filter { $0.element.kind == .line }
        var horizontals: [(offset: Int, y: Double)] = [], verticals: [(offset: Int, x: Double)] = []
        for (offset, element) in lines {
            guard case .segment(let start, let end)? = element.shape else { continue }
            if abs(end.y - start.y) <= abs(end.x - start.x) { horizontals.append((offset, (start.y + end.y) / 2)) }
            else { verticals.append((offset, (start.x + end.x) / 2)) }
        }
        let sortedHorizontal = horizontals.sorted { $0.y < $1.y }
        for (position, entry) in sortedHorizontal.enumerated() {
            let label = sortedHorizontal.count == 1 ? "Linie horizontal"
                : position == 0 ? "Linie oben" : position == sortedHorizontal.count - 1 ? "Linie unten" : "Linie \(position + 1)"
            names[elements[entry.offset].id] = label
        }
        let sortedVertical = verticals.sorted { $0.x < $1.x }
        for (position, entry) in sortedVertical.enumerated() {
            let label = sortedVertical.count == 1 ? "Linie vertikal"
                : position == 0 ? "Linie links" : position == sortedVertical.count - 1 ? "Linie rechts" : "Linie vertikal \(position + 1)"
            names[elements[entry.offset].id] = label
        }
        for element in elements {
            switch element.kind {
            case .line: break
            case .rectangle: names[element.id] = "Rechteck"
            case .circle:
                if let value = element.valueMm { names[element.id] = "Kreis Ø\(trim(value))" } else { names[element.id] = "Kreis" }
            case .length:
                if let value = element.valueMm { names[element.id] = "Zahl \(trim(value)) mm" } else { names[element.id] = "Zahl" }
            case .diameter:
                if let value = element.valueMm { names[element.id] = "Ø\(trim(value))" } else { names[element.id] = "Durchmesser" }
            case .angle:
                if let value = element.angleDeg { names[element.id] = "Winkel \(trim(value))°" } else { names[element.id] = "Winkel" }
            case .profile:
                let dims = (element.profileDimensionsMm ?? []).map(trim).joined(separator: "×")
                names[element.id] = dims.isEmpty ? "Profilangabe" : "Profil \(dims)"
            case .text:
                names[element.id] = "Beschriftung\(element.rawText.map { " „\($0)“" } ?? "")"
            }
        }
        return names
    }

    private static func trim(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Übernahme: strukturierte Daten → validierte Geometrie

/// Die Geometrie-Engine-Schwelle: Erst hier werden erkannte Daten validiert und in
/// mm-Geometrie umgerechnet. Ungültige Elemente werden verworfen, niemals gerettet.
public enum SketchAdoption {
    /// Wandelt ein akzeptiertes Erkennungsobjekt in validierte 2D-Geometrie (mm) um.
    /// y zeigt im Bild nach unten, in der Geometrie nach oben → y wird gespiegelt.
    public static func geometry(for element: RecognizedElement, mmPerPixel: Double?, imageWidthPx: Double, imageHeightPx: Double) throws -> GeometryElement2D? {
        guard let shape = element.shape else { return nil }
        guard let scale = mmPerPixel, scale.isFinite, scale > 0 else { return nil }
        func mm(_ point: RecognizedPoint) throws -> Vec2 {
            let x = try Geometry2D.checked(point.x * imageWidthPx * scale)
            let y = try Geometry2D.checked((1 - point.y) * imageHeightPx * scale)
            return .init(x: x, y: y)
        }
        let element2D: GeometryElement2D
        switch shape {
        case .segment(let start, let end):
            element2D = .line(start: try mm(start), end: try mm(end))
        case .rectangle(let origin, let width, let height):
            let w = try Geometry2D.checked(width * imageWidthPx * scale)
            let h = try Geometry2D.checked(height * imageHeightPx * scale)
            let o = RecognizedPoint(x: origin.x, y: origin.y + height)
            element2D = .rectangle(origin: try mm(o), width: w, height: h)
        case .circle(let center, let radius):
            let radiusMm = element.valueMm != nil
                ? try Geometry2D.checked(element.valueMm! / 2)
                : try Geometry2D.checked(radius * imageWidthPx * scale)
            element2D = .circle(center: try mm(center), radius: radiusMm)
        }
        try element2D.validate()
        return element2D
    }

    /// Validiert alle akzeptierten Elemente; ungültige werden mit Grund verworfen.
    public static func validatedGeometry(elements: [RecognizedElement], mmPerPixel: Double?,
                                         imageWidthPx: Double, imageHeightPx: Double) -> (geometry: [(label: String, element: GeometryElement2D)], rejected: [String]) {
        var accepted: [(String, GeometryElement2D)] = [], rejected: [String] = []
        for element in elements where element.accepted && element.shape != nil {
            do {
                if let geometry = try geometry(for: element, mmPerPixel: mmPerPixel, imageWidthPx: imageWidthPx, imageHeightPx: imageHeightPx) {
                    accepted.append((element.name, geometry))
                }
            } catch {
                rejected.append(element.name.isEmpty ? "Unbekanntes Element" : element.name)
            }
        }
        return (accepted, rejected)
    }
}
