import Foundation

/// 2D-CAD-Dokument über dem parametrischen Domain-Modell.
/// Alle Werte in Millimetern, y zeigt nach oben. Reine Werttypen: deterministisch,
/// testbar und ohne UI- oder Speicherbezug. Das Rahmenmodell bleibt in den
/// Projektparametern (FrameParameters) – das Dokument enthält nur eigene Elemente
/// und parametrische Verweise, niemals eine Kopie der Rahmengeometrie.

public enum CADHolePatternKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case linear, circular
    public var id: String { rawValue }
    public var title: String { self == .linear ? "Linear" : "Kreisförmig" }
}

public enum CADKind: String, Codable, Sendable, CaseIterable {
    case line, rectangle, circle, arc, profile, hole, construction, text, dimension, angle
}

public struct CADElement: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var kind: CADKind
    /// Linie: Start · Rechteck: Ecke 1 · Kreis/Bohrung: Mittelpunkt · Bogen: Zentrum
    /// Text: Position · Maß (frei): von · Maß (parametrisch): Anker · Winkel: Scheitel
    public var a: Vec2
    /// Linie: Ende · Rechteck: Gegenecke · Kreis: Radiuspunkt · Bogen: Startpunkt
    /// Maß (frei): bis · Winkel: erster Schenkel
    public var b: Vec2
    /// Bogen: Endpunkt · Maß (frei): Lage der Maßlinie · Winkel: zweiter Schenkel
    public var c: Vec2?
    public var text: String?
    /// Maß (frei): gespeicherter Wert ist der gemessene Abstand; Bearbeiten verschiebt Punkte.
    public var widthMm: Double?
    /// "width" | "height": parametrisches Maß, Wert kommt aus den Projektparametern.
    public var parameterKey: String?
    /// Profilstärke für die Doppel-Linie des Profil-Werkzeugs.
    public var profileWidthMm: Double?

    public init(id: UUID = UUID(), kind: CADKind, a: Vec2, b: Vec2, c: Vec2? = nil,
                text: String? = nil, widthMm: Double? = nil,
                parameterKey: String? = nil, profileWidthMm: Double? = nil) {
        self.id = id; self.kind = kind; self.a = a; self.b = b; self.c = c
        self.text = text; self.widthMm = widthMm
        self.parameterKey = parameterKey; self.profileWidthMm = profileWidthMm
    }

    // MARK: Geometrie

    public var radius: Double? {
        switch kind {
        case .circle, .hole, .arc: return a.distance(to: b)
        default: return nil
        }
    }

    /// Endpunkte und markante Punkte für Snap und Auswahl.
    public var keyPoints: [Vec2] {
        switch kind {
        case .line, .profile, .construction: return [a, b, Vec2(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)]
        case .rectangle:
            let minC = Vec2(x: min(a.x, b.x), y: min(a.y, b.y))
            let maxC = Vec2(x: max(a.x, b.x), y: max(a.y, b.y))
            return [minC, maxC, .init(x: (minC.x + maxC.x) / 2, y: minC.y), .init(x: (minC.x + maxC.x) / 2, y: maxC.y),
                    .init(x: minC.x, y: (minC.y + maxC.y) / 2), .init(x: maxC.x, y: (minC.y + maxC.y) / 2)]
        case .circle, .hole, .arc: return [a, b, c].compactMap { $0 }
        case .text: return [a]
        case .dimension: return parameterKey == nil ? [a, b, c].compactMap { $0 } : [a]
        case .angle: return [a, b, c].compactMap { $0 }
        }
    }

    public var corners: [Vec2] {
        guard kind == .rectangle else { return [] }
        let minC = Vec2(x: min(a.x, b.x), y: min(a.y, b.y))
        let maxC = Vec2(x: max(a.x, b.x), y: max(a.y, b.y))
        return [minC, .init(x: maxC.x, y: minC.y), maxC, .init(x: minC.x, y: maxC.y)]
    }

    /// Abstand für Treffer- und Snap-Prüfung.
    public func distance(to point: Vec2) -> Double {
        switch kind {
        case .line, .profile, .hole, .circle, .arc, .rectangle:
            return geometryDistance(point)
        case .construction:
            return (try? Geometry2D.distance(from: point, toSegment: a, b)) ?? .infinity
        case .text: return a.distance(to: point)
        case .dimension, .angle: return keyPoints.map { $0.distance(to: point) }.min() ?? .infinity
        }
    }

    private func geometryDistance(_ point: Vec2) -> Double {
        switch kind {
        case .line, .profile, .construction:
            return (try? Geometry2D.distance(from: point, toSegment: a, b)) ?? .infinity
        case .circle, .hole:
            guard let radius, radius > 0 else { return .infinity }
            return abs(a.distance(to: point) - radius)
        case .arc:
            guard let radius, radius > 0 else { return .infinity }
            let angle = atan2(point.y - a.y, point.x - a.x) * 180 / .pi
            let start = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
            let end = atan2((c ?? b).y - a.y, (c ?? b).x - a.x) * 180 / .pi
            let sweep = (try? Geometry2D.arcSweep(start: start, end: end)) ?? 0
            var relative = angle - start
            while relative < 0 { relative += 360 }
            if relative <= sweep { return abs(a.distance(to: point) - radius) }
            return min(b.distance(to: point), (c ?? b).distance(to: point))
        case .rectangle:
            let corners = self.corners
            guard corners.count == 4 else { return .infinity }
            return (0..<4).map { (try? Geometry2D.distance(from: point, toSegment: corners[$0], corners[($0 + 1) % 4])) ?? .infinity }.min() ?? .infinity
        default: return .infinity
        }
    }

    /// Wert eines Maßes bzw. Winkels für Anzeige und Bearbeitung.
    public func dimensionValue(frame: FrameParameters?) -> Double? {
        switch kind {
        case .dimension:
            if let key = parameterKey {
                guard let frame else { return nil }
                return key == "width" ? frame.width : frame.height
            }
            return try? Geometry2D.checked(a.distance(to: b))
        case .angle: return angleValue()
        default: return nil
        }
    }

    public func angleValue() -> Double? {
        guard kind == .angle, let c else { return nil }
        let first = b - a, second = c - a
        guard first.magnitude > 1e-9, second.magnitude > 1e-9 else { return nil }
        let cosine = max(-1, min(1, first.dot(second) / (first.magnitude * second.magnitude)))
        return acos(cosine) * 180 / .pi
    }

    /// Endpunkte eines Maßes für das Zeichnen. Parametrische Maße folgen den Projektparametern.
    public func dimensionEndpoints(frame: FrameParameters?) -> (from: Vec2, to: Vec2, linePoint: Vec2)? {
        switch kind {
        case .dimension:
            if let key = parameterKey, let frame {
                if key == "width" { return (.init(x: 0, y: a.y), .init(x: frame.width, y: a.y), a) }
                if key == "height" { return (.init(x: a.x, y: 0), .init(x: a.x, y: frame.height), a) }
                return nil
            }
            guard let c else { return nil }
            return (a, b, c)
        default: return nil
        }
    }

    /// Element mit transformierten Punkten (Mirror, Array, Maßkorrektur).
    public func mapped(_ transform: (Vec2) -> Vec2) -> CADElement {
        var copy = self
        copy.a = transform(a)
        copy.b = transform(b)
        copy.c = c.map(transform)
        return copy
    }
}

public struct CADDrawing: Equatable, Codable, Sendable {
    public var elements: [CADElement] = []
    public init(elements: [CADElement] = []) { self.elements = elements }

    public func element(with id: UUID) -> CADElement? { elements.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { elements.firstIndex { $0.id == id } }

    public mutating func add(_ element: CADElement) throws {
        try Self.validate(element)
        elements.append(element)
    }

    public mutating func remove(ids: Set<UUID>) {
        elements.removeAll { ids.contains($0.id) }
    }

    public mutating func replace(_ element: CADElement) throws {
        try Self.validate(element)
        guard let index = index(of: element.id) else { throw GeometryError.degenerateGeometry }
        elements[index] = element
    }

    /// Kein NaN/Infinity und keine entartete Geometrie im Dokument.
    public static func validate(_ element: CADElement) throws {
        let points = [element.a, element.b, element.c].compactMap { $0 }
        for point in points { try Geometry2D.validate(point) }
        switch element.kind {
        case .line, .profile, .construction:
            guard try Geometry2D.checked(element.a.distance(to: element.b)) > 1e-9 else { throw GeometryError.degenerateGeometry }
            if let width = element.profileWidthMm { try Geometry2D.positive(width) }
        case .rectangle:
            guard abs(element.a.x - element.b.x) > 1e-9, abs(element.a.y - element.b.y) > 1e-9 else { throw GeometryError.degenerateGeometry }
        case .circle, .hole:
            try Geometry2D.positive(try Geometry2D.checked(element.a.distance(to: element.b)))
        case .arc:
            guard let c = element.c else { throw GeometryError.degenerateGeometry }
            try Geometry2D.positive(try Geometry2D.checked(element.a.distance(to: element.b)))
            let start = atan2(element.b.y - element.a.y, element.b.x - element.a.x) * 180 / .pi
            let end = atan2(c.y - element.a.y, c.x - element.a.x) * 180 / .pi
            _ = try Geometry2D.arcSweep(start: start, end: end)
        case .dimension:
            if element.parameterKey != nil {
                guard element.parameterKey == "width" || element.parameterKey == "height" else { throw GeometryError.degenerateGeometry }
            } else {
                guard element.c != nil, try Geometry2D.checked(element.a.distance(to: element.b)) > 1e-9 else { throw GeometryError.degenerateGeometry }
            }
        case .angle:
            guard element.c != nil, element.angleValue() != nil, element.angleValue()! > 1e-6, element.angleValue()! < 180 - 1e-6 else { throw GeometryError.degenerateGeometry }
        case .text:
            guard let text = element.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw GeometryError.degenerateGeometry }
        }
    }
}

// MARK: - Fabrik

public enum CADFactory {
    public static func line(_ a: Vec2, _ b: Vec2) -> CADElement { .init(kind: .line, a: a, b: b) }
    public static func rectangle(_ a: Vec2, _ b: Vec2) -> CADElement { .init(kind: .rectangle, a: a, b: b) }
    public static func circle(center: Vec2, radiusPoint: Vec2) -> CADElement { .init(kind: .circle, a: center, b: radiusPoint) }
    public static func hole(center: Vec2, radiusPoint: Vec2) -> CADElement { .init(kind: .hole, a: center, b: radiusPoint) }
    public static func arc(center: Vec2, start: Vec2, end: Vec2) -> CADElement { .init(kind: .arc, a: center, b: start, c: end) }
    public static func profile(_ a: Vec2, _ b: Vec2, widthMm: Double) -> CADElement { .init(kind: .profile, a: a, b: b, widthMm: widthMm) }
    public static func construction(_ a: Vec2, _ b: Vec2) -> CADElement { .init(kind: .construction, a: a, b: b) }
    public static func text(_ position: Vec2, _ content: String) -> CADElement { .init(kind: .text, a: position, b: position, text: content) }
    public static func dimension(from: Vec2, to: Vec2, linePoint: Vec2) -> CADElement { .init(kind: .dimension, a: from, b: to, c: linePoint) }
    public static func parametricDimension(key: String, anchor: Vec2) -> CADElement { .init(kind: .dimension, a: anchor, b: anchor, parameterKey: key) }
    public static func angle(vertex: Vec2, first: Vec2, second: Vec2) -> CADElement { .init(kind: .angle, a: vertex, b: first, c: second) }
}

// MARK: - Snapping

public struct CADSnap: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case endpoint, midpoint, center, intersection, axis, grid
        public var title: String {
            switch self {
            case .endpoint: return "Endpunkt gefangen"
            case .midpoint: return "Mitte gefangen"
            case .center: return "Zentrum gefangen"
            case .intersection: return "Schnittpunkt gefangen"
            case .axis: return "Ausrichtung gefangen"
            case .grid: return "Am Raster"
            }
        }
    }
    public var point: Vec2
    public var kind: Kind
    public init(point: Vec2, kind: Kind) { self.point = point; self.kind = kind }
}

extension CADDrawing {
    /// Reihenfolge: Endpunkt → Mitte/Zentrum → Schnittpunkt → Ausrichtung → Raster.
    /// Ohne Treffer wird der Rohpunkt verwendet (niemals ein Maß erfunden).
    public func snap(raw: Vec2, frame: FrameParameters?, pendingStart: Vec2?,
                     pxPerMm: Double, tolerancePt: Double, gridMm: Double, gridEnabled: Bool) -> CADSnap? {
        let tolerance = max(1e-9, tolerancePt / max(1e-9, pxPerMm))
        func nearest(_ candidates: [(Vec2, CADSnap.Kind)]) -> CADSnap? {
            var best: (point: Vec2, kind: CADSnap.Kind, distance: Double)?
            for (point, kind) in candidates {
                let distance = point.distance(to: raw)
                if distance <= tolerance, best == nil || distance < best!.distance { best = (point, kind, distance) }
            }
            guard let best else { return nil }
            return CADSnap(point: best.point, kind: best.kind)
        }

        var endpoints: [(Vec2, CADSnap.Kind)] = []
        var middles: [(Vec2, CADSnap.Kind)] = []
        for element in elements {
            switch element.kind {
            case .line, .profile, .construction:
                endpoints.append((element.a, .endpoint)); endpoints.append((element.b, .endpoint))
                middles.append((Vec2(x: (element.a.x + element.b.x) / 2, y: (element.a.y + element.b.y) / 2), .midpoint))
            case .rectangle:
                let corners = element.corners
                for corner in corners { endpoints.append((corner, .endpoint)) }
                middles.append((Vec2(x: (element.a.x + element.b.x) / 2, y: element.a.y), .midpoint))
                middles.append((Vec2(x: (element.a.x + element.b.x) / 2, y: element.b.y), .midpoint))
                middles.append((Vec2(x: element.a.x, y: (element.a.y + element.b.y) / 2), .midpoint))
                middles.append((Vec2(x: element.b.x, y: (element.a.y + element.b.y) / 2), .midpoint))
            case .circle, .hole:
                middles.append((element.a, .center))
            case .arc:
                middles.append((element.a, .center))
                endpoints.append((element.b, .endpoint))
                if let c = element.c { endpoints.append((c, .endpoint)) }
            case .text, .dimension, .angle: break
            }
        }
        if let frame {
            let t = frame.profile.widthMm
            let outer = [Vec2.zero, .init(x: frame.width, y: 0), .init(x: frame.width, y: frame.height), .init(x: 0, y: frame.height)]
            let inner = [Vec2(x: t, y: t), .init(x: frame.width - t, y: t), .init(x: frame.width - t, y: frame.height - t), .init(x: t, y: frame.height - t)]
            for corner in outer { endpoints.append((corner, .endpoint)) }
            for corner in inner { endpoints.append((corner, .endpoint)) }
        }
        if let snap = nearest(endpoints) { return snap }
        if let snap = nearest(middles) { return snap }
        if let snap = nearest(intersectionPoints().map { ($0, CADSnap.Kind.intersection) }) { return snap }
        if let start = pendingStart {
            let dx = abs(raw.x - start.x), dy = abs(raw.y - start.y)
            if dy <= tolerance, dy <= dx { return CADSnap(point: .init(x: raw.x, y: start.y), kind: .axis) }
            if dx <= tolerance { return CADSnap(point: .init(x: start.x, y: raw.y), kind: .axis) }
        }
        guard gridEnabled, gridMm > 0 else { return nil }
        let gridX = (raw.x / gridMm).rounded() * gridMm
        let gridY = (raw.y / gridMm).rounded() * gridMm
        let gridPoint = Vec2(x: gridX, y: gridY)
        guard gridPoint.distance(to: raw) <= tolerance else { return nil }
        return CADSnap(point: gridPoint, kind: .grid)
    }

    /// Segmente für Schnittberechnungen. Hilfslinien gelten als unbegrenzte Geraden.
    public struct Segment {
        public var start: Vec2
        public var end: Vec2
        public var infinite: Bool
        public var owner: UUID
    }

    public func segments() -> [Segment] {
        var result: [Segment] = []
        for element in elements {
            switch element.kind {
            case .line, .profile: result.append(Segment(start: element.a, end: element.b, infinite: false, owner: element.id))
            case .construction: result.append(Segment(start: element.a, end: element.b, infinite: true, owner: element.id))
            case .rectangle:
                let corners = element.corners
                for index in 0..<4 {
                    result.append(Segment(start: corners[index], end: corners[(index + 1) % 4], infinite: false, owner: element.id))
                }
            default: break
            }
        }
        return result
    }

    /// Schnittpunkte Segment↔Segment und Segment↔Kreis, begrenzt auf sinnvolle Mengen.
    public func intersectionPoints() -> [Vec2] {
        let segments = segments()
        let circles = elements.filter { $0.kind == .circle || $0.kind == .hole }
        var points: [Vec2] = []
        let maximum = 200
        for i in 0..<segments.count {
            for j in (i + 1)..<segments.count where segments[i].owner != segments[j].owner {
                guard let point = Self.intersection(of: segments[i], and: segments[j]) else { continue }
                points.append(point)
                if points.count >= maximum { return points }
            }
            for circle in circles {
                guard let radius = circle.radius, radius > 0 else { continue }
                for point in Self.intersection(of: segments[i], circleCenter: circle.a, radius: radius) {
                    points.append(point)
                    if points.count >= maximum { return points }
                }
            }
        }
        return points
    }

    public static func intersection(of first: Segment, and second: Segment) -> Vec2? {
        guard let directionA = try? (first.end - first.start).normalized(),
              let directionB = try? (second.end - second.start).normalized() else { return nil }
        guard let point = try? Geometry2D.lineIntersection(first.start, directionA, second.start, directionB) else { return nil }
        func contains(_ segment: Segment, _ point: Vec2) -> Bool {
            if segment.infinite { return true }
            let length = segment.start.distance(to: segment.end)
            guard length > 1e-9 else { return false }
            let direction = (segment.end - segment.start) * (1 / length)
            let projection = (point - segment.start).dot(direction)
            return projection >= -1e-6 && projection <= length + 1e-6
        }
        guard contains(first, point), contains(second, point) else { return nil }
        return point
    }

    public static func intersection(of segment: Segment, circleCenter: Vec2, radius: Double) -> [Vec2] {
        let direction = segment.end - segment.start
        guard direction.magnitude > 1e-9 else { return [] }
        let unit = direction * (1 / direction.magnitude)
        let offset = segment.start - circleCenter
        let projection = offset.dot(unit)
        let perpendicularSquared = max(0, offset.dot(offset) - projection * projection)
        guard radius * radius >= perpendicularSquared else { return [] }
        let half = (radius * radius - perpendicularSquared).squareRoot()
        var results: [Vec2] = []
        for t in [projection - half, projection + half] {
            if segment.infinite || (t >= -1e-6 && t <= segment.start.distance(to: segment.end) + 1e-6) {
                let point = segment.start + unit * t
                if point.isFinite { results.append(point) }
            }
        }
        return results
    }
}

// MARK: - Viewport

public struct CADViewport: Equatable, Sendable {
    /// Bildschirmpunkte pro Millimeter.
    public var pxPerMm: Double
    /// Weltpunkt im Zentrum der Zeichenfläche.
    public var center: Vec2

    public init(pxPerMm: Double, center: Vec2) {
        self.pxPerMm = min(50, max(0.02, pxPerMm))
        self.center = center
    }

    public func screenPoint(_ world: Vec2, canvas: CGSize) -> CGPoint {
        CGPoint(x: canvas.width / 2 + (world.x - center.x) * pxPerMm,
                y: canvas.height / 2 - (world.y - center.y) * pxPerMm)
    }

    public func worldPoint(_ screen: CGPoint, canvas: CGSize) -> Vec2 {
        Vec2(x: center.x + (screen.x - canvas.width / 2) / pxPerMm,
             y: center.y - (screen.y - canvas.height / 2) / pxPerMm)
    }

    public mutating func pan(screenDelta: CGSize) {
        center.x -= screenDelta.width / pxPerMm
        center.y += screenDelta.height / pxPerMm
        center = Vec2(x: center.x, y: center.y)
    }

    public mutating func zoom(factor: Double, anchor: CGPoint, canvas: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let anchorWorld = worldPoint(anchor, canvas: canvas)
        pxPerMm = min(50, max(0.02, pxPerMm * factor))
        center = Vec2(x: anchorWorld.x + (canvas.width / 2 - anchor.x) / pxPerMm,
                      y: anchorWorld.y - (canvas.height / 2 - anchor.y) / pxPerMm)
    }

    public static func fitted(content: Vec2, marginMm: Double, canvas: CGSize) -> CADViewport {
        let spanX = max(1, content.x + 2 * marginMm), spanY = max(1, content.y + 2 * marginMm)
        let scale = min(canvas.width / spanX, canvas.height / spanY)
        return CADViewport(pxPerMm: scale, center: Vec2(x: content.x / 2, y: content.y / 2))
    }

    /// Nächster Normmaßstab aus dem aktuellen Zoom (1 pt ≈ 0,3528 mm).
    public func scaleLabel() -> String {
        let screenMmPerMm = 0.3528 / max(1e-9, pxPerMm)
        if screenMmPerMm >= 0.9 {
            let magnifications: [Double] = [1, 2, 5, 10]
            let best = magnifications.min { abs($0 - screenMmPerMm) < abs($1 - screenMmPerMm) } ?? 1
            return "\(Int(best)):1"
        }
        let denominators: [Double] = [1, 2, 5, 10, 20, 50, 100, 200]
        let target = 1 / max(1e-9, screenMmPerMm)
        let best = denominators.min { abs($0 - target) < abs($1 - target) } ?? 1
        return "1:\(Int(best))"
    }
}

// MARK: - Undo/Redo

public struct CADHistoryEntry: Equatable, Sendable {
    public var label: String
    public var drawingBefore: CADDrawing
    public var drawingAfter: CADDrawing
    public var widthBefore: Double?
    public var widthAfter: Double?
    public var heightBefore: Double?
    public var heightAfter: Double?

    public init(label: String, drawingBefore: CADDrawing, drawingAfter: CADDrawing,
                widthBefore: Double? = nil, widthAfter: Double? = nil,
                heightBefore: Double? = nil, heightAfter: Double? = nil) {
        self.label = label
        self.drawingBefore = drawingBefore; self.drawingAfter = drawingAfter
        self.widthBefore = widthBefore; self.widthAfter = widthAfter
        self.heightBefore = heightBefore; self.heightAfter = heightAfter
    }
}

public struct CADHistory: Equatable, Sendable {
    private(set) var undoStack: [CADHistoryEntry] = []
    private(set) var redoStack: [CADHistoryEntry] = []
    public init() {}
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ entry: CADHistoryEntry) {
        undoStack.append(entry)
        if undoStack.count > 150 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public mutating func undo() -> CADHistoryEntry? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry)
        return entry
    }

    public mutating func redo() -> CADHistoryEntry? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry)
        return entry
    }
}

// MARK: - Bearbeitungsoperationen

public enum CADOperations {
    /// Spiegelung eines Punkts an der Achse a–b.
    public static func reflect(_ point: Vec2, across a: Vec2, _ b: Vec2) -> Vec2 {
        let direction = b - a
        let lengthSquared = direction.dot(direction)
        guard lengthSquared > 1e-12 else { return point }
        let foot = a + direction * ((point - a).dot(direction) / lengthSquared)
        return foot * 2 - point
    }

    /// Trim: der Anteil des Zielelements, der dem Tipppunkt am nächsten liegt, wird entfernt.
    public static func trim(_ drawing: CADDrawing, targetID: UUID, cutterID: UUID, tap: Vec2) -> CADDrawing? {
        guard let target = drawing.element(with: targetID), target.kind == .line || target.kind == .profile,
              let cutter = drawing.element(with: cutterID) else { return nil }
        var cuts: [Vec2] = []
        switch cutter.kind {
        case .line, .profile:
            if let point = CADDrawing.intersection(of: .init(start: target.a, end: target.b, infinite: false, owner: target.id),
                                                   and: .init(start: cutter.a, end: cutter.b, infinite: false, owner: cutter.id)) { cuts.append(point) }
        case .construction:
            if let point = CADDrawing.intersection(of: .init(start: target.a, end: target.b, infinite: false, owner: target.id),
                                                   and: .init(start: cutter.a, end: cutter.b, infinite: true, owner: cutter.id)) { cuts.append(point) }
        case .circle, .hole:
            guard let radius = cutter.radius, radius > 0 else { return nil }
            cuts.append(contentsOf: CADDrawing.intersection(of: .init(start: target.a, end: target.b, infinite: false, owner: target.id),
                                                            circleCenter: cutter.a, radius: radius))
        default: return nil
        }
        guard let cut = cuts.min(by: { $0.distance(to: tap) < $1.distance(to: tap) }) else { return nil }
        let length = target.a.distance(to: target.b)
        guard length > 2e-6 else { return nil }
        let direction = (target.b - target.a) * (1 / length)
        let cutProjection = (cut - target.a).dot(direction)
        let tapProjection = (tap - target.a).dot(direction)
        let remaining: (Vec2, Vec2)
        if tapProjection < cutProjection { remaining = (target.a, cut) } else { remaining = (cut, target.b) }
        guard remaining.0.distance(to: remaining.1) > 1e-6 else { return nil }
        var result = drawing
        var trimmed = target
        trimmed.a = remaining.0
        trimmed.b = remaining.1
        try? result.replace(trimmed)
        return result
    }

    /// Extend: der dem Tipppunkt nächste Endpunkt wird bis zum Schnitt mit der Grenze verlängert.
    public static func extend(_ drawing: CADDrawing, targetID: UUID, boundaryID: UUID, tap: Vec2) -> CADDrawing? {
        guard let target = drawing.element(with: targetID), target.kind == .line || target.kind == .profile,
              let boundary = drawing.element(with: boundaryID) else { return nil }
        let boundarySegment = CADDrawing.Segment(start: boundary.a, end: boundary.b, infinite: boundary.kind == .construction, owner: boundary.id)
        guard let direction = try? (target.b - target.a).normalized() else { return nil }
        guard let intersection = CADDrawing.intersection(of: .init(start: target.a, end: target.b, infinite: true, owner: target.id),
                                                         and: boundarySegment) else { return nil }
        let extendStart = target.a.distance(to: tap) <= target.b.distance(to: tap) ? target.a : target.b
        let fixed = extendStart == target.a ? target.b : target.a
        guard extendStart.distance(to: intersection) > 1e-6 else { return nil }
        let forward = (extendStart - fixed).dot(direction) >= 0
        let unit = forward ? direction : direction * -1
        let length = fixed.distance(to: intersection)
        guard length > 1e-6 else { return nil }
        var result = drawing
        var extended = target
        extended.a = fixed
        extended.b = fixed + unit * length
        try? result.replace(extended)
        return result
    }

    /// Offset: parallele Kopie im Abstand `distanceMm` auf der Seite des Tipps.
    public static func offset(_ drawing: CADDrawing, id: UUID, distanceMm: Double, side: Vec2) -> CADDrawing? {
        guard distanceMm.isFinite, distanceMm > 0,
              let element = drawing.element(with: id),
              element.kind == .line || element.kind == .profile || element.kind == .construction,
              let direction = try? (element.b - element.a).normalized() else { return nil }
        var normal = Vec2(x: -direction.y, y: direction.x)
        let midpoint = Vec2(x: (element.a.x + element.b.x) / 2, y: (element.a.y + element.b.y) / 2)
        if (side - midpoint).dot(normal) < 0 { normal = normal * -1 }
        var result = drawing
        var copy = element
        copy.id = UUID()
        copy.a = element.a + normal * distanceMm
        copy.b = element.b + normal * distanceMm
        try? result.add(copy)
        return result.elements.count > drawing.elements.count ? result : nil
    }

    /// Mirror: gespiegelte Kopien der Auswahl an der Achse a–b.
    public static func mirror(_ drawing: CADDrawing, ids: [UUID], axisA: Vec2, axisB: Vec2) -> CADDrawing? {
        guard axisA.distance(to: axisB) > 1e-9 else { return nil }
        var result = drawing
        var added = 0
        for id in ids {
            guard let element = drawing.element(with: id) else { continue }
            var copy = element.mapped { reflect($0, across: axisA, axisB) }
            copy.id = UUID()
            try? result.add(copy)
            if result.elements.last?.id == copy.id { added += 1 }
        }
        return added > 0 ? result : nil
    }

    /// Array: lineare Vervielfältigung der Auswahl.
    public static func linearArray(_ drawing: CADDrawing, ids: [UUID], count: Int, dx: Double, dy: Double) -> CADDrawing? {
        guard count >= 2, count <= 500, dx.isFinite, dy.isFinite, abs(dx) + abs(dy) > 1e-9 else { return nil }
        var result = drawing
        var added = 0
        for index in 1..<count {
            for id in ids {
                guard let element = drawing.element(with: id) else { continue }
                var copy = element.mapped { Vec2(x: $0.x + Double(index) * dx, y: $0.y + Double(index) * dy) }
                copy.id = UUID()
                try? result.add(copy)
                if result.elements.last?.id == copy.id { added += 1 }
            }
        }
        return added > 0 ? result : nil
    }

    /// Erstellt ein lineares oder kreisförmiges Lochbild als eine geprüfte CAD-Operation.
    /// Alle Bohrungen werden zunächst validiert; ein einziges ungültiges Element verwirft das Muster vollständig.
    public static func drillPattern(_ drawing: CADDrawing, center: Vec2, kind: CADHolePatternKind,
                                    count: Int, spacingMm: Double, pitchCircleDiameterMm: Double,
                                    startAngleDeg: Double, holeDiameterMm: Double) -> CADDrawing? {
        guard (2...500).contains(count), holeDiameterMm.isFinite, holeDiameterMm >= 1,
              startAngleDeg.isFinite else { return nil }
        let radius = holeDiameterMm / 2
        let centers: [Vec2]
        switch kind {
        case .linear:
            guard spacingMm.isFinite, spacingMm > 0 else { return nil }
            let angle = startAngleDeg * .pi / 180
            let direction = Vec2(x: cos(angle), y: sin(angle))
            centers = (0..<count).map { index in center + direction * (Double(index) * spacingMm) }
        case .circular:
            guard pitchCircleDiameterMm.isFinite, pitchCircleDiameterMm > 0 else { return nil }
            let pitchRadius = pitchCircleDiameterMm / 2
            let start = startAngleDeg * .pi / 180
            centers = (0..<count).map { index in
                let angle = start + 2 * .pi * Double(index) / Double(count)
                return center + Vec2(x: cos(angle) * pitchRadius, y: sin(angle) * pitchRadius)
            }
        }
        var result = drawing
        for holeCenter in centers {
            let hole = CADElement(kind: .hole, a: holeCenter,
                                  b: holeCenter + Vec2(x: radius, y: 0))
            do { try result.add(hole) } catch { return nil }
        }
        return result.elements.count == drawing.elements.count + count ? result : nil
    }

    /// Maß bearbeiten: parametrische Maße ändern Projektparameter, freie Maße verschieben
    /// den Endpunkt und alle damit zusammenfallenden Geometrie-Endpunkte deterministisch.
    public static func dimensionEdit(_ drawing: CADDrawing, dimensionID: UUID, newValueMm: Double) -> (drawing: CADDrawing, parameterKey: String?, parameterValue: Double?)? {
        guard newValueMm.isFinite, newValueMm > 0, let dimension = drawing.element(with: dimensionID), dimension.kind == .dimension else { return nil }
        if let key = dimension.parameterKey {
            return (drawing, key, newValueMm)
        }
        let currentValue = dimension.a.distance(to: dimension.b)
        guard currentValue > 1e-9, abs(currentValue - newValueMm) > 1e-9 else { return nil }
        let direction = (dimension.b - dimension.a) * (1 / currentValue)
        let newEnd = dimension.a + direction * newValueMm
        guard newEnd.isFinite else { return nil }
        let oldEnd = dimension.b
        var result = drawing
        var updated = dimension
        updated.b = newEnd
        try? result.replace(updated)
        result.elements = result.elements.map { element in
            element.id == dimensionID ? element : element.mapped { point in
                point.distance(to: oldEnd) <= 0.5 ? newEnd : point
            }
        }
        return (result, nil, nil)
    }
}
