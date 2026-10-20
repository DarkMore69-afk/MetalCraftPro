import Foundation

/// Millimetres throughout. Pure values; no UI, storage or global mutable state.
public enum GeometryError: Error, Equatable, LocalizedError {
    case nonFiniteValue, negativeValue, degenerateGeometry
    public var errorDescription: String? {
        switch self {
        case .nonFiniteValue: return "Der Wert ist nicht endlich oder zu groß."
        case .negativeValue: return "Abmessungen müssen größer als null sein."
        case .degenerateGeometry: return "Diese Abmessungen ergeben keine gültige Geometrie."
        }
    }
}

public struct Vec2: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(x: 0, y: 0)
    public static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Self, b: Double) -> Self { .init(x: a.x * b, y: a.y * b) }
    public var magnitude: Double { hypot(x, y) }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public func distance(to p: Self) -> Double { hypot(x - p.x, y - p.y) }
    public func dot(_ p: Self) -> Double { x * p.x + y * p.y }
    public func cross(_ p: Self) -> Double { x * p.y - y * p.x }
    public func normalized() throws -> Self {
        try Geometry2D.validate(self)
        let length = try Geometry2D.checked(magnitude)
        guard length > 1e-12 else { throw GeometryError.degenerateGeometry }
        return .init(x: x / length, y: y / length)
    }
}

public enum GeometryElement2D: Equatable, Codable, Sendable {
    case point(Vec2)
    case line(start: Vec2, end: Vec2)
    case polyline([Vec2])
    case circle(center: Vec2, radius: Double)
    /// Positive counter-clockwise sweep. 350°→10° is 20°; 0°→360° is a full turn.
    case arc(center: Vec2, radius: Double, startAngleDeg: Double, endAngleDeg: Double)
    case rectangle(origin: Vec2, width: Double, height: Double)

    public func validate() throws {
        switch self {
        case .point(let point): try Geometry2D.validate(point)
        case .line(let a, let b):
            try Geometry2D.validate(a); try Geometry2D.validate(b)
            guard try Geometry2D.checked(a.distance(to: b)) > 1e-12 else { throw GeometryError.degenerateGeometry }
        case .polyline(let points):
            guard points.count >= 2 else { throw GeometryError.degenerateGeometry }
            for (a, b) in zip(points, points.dropFirst()) { try Self.line(start: a, end: b).validate() }
        case .circle(let center, let radius):
            try Geometry2D.validate(center); try Geometry2D.positive(radius)
            try Geometry2D.validate(center + Vec2(x: radius, y: radius))
        case .arc(let center, let radius, let start, let end):
            try Self.circle(center: center, radius: radius).validate()
            _ = try Geometry2D.arcSweep(start: start, end: end)
        case .rectangle(let origin, let width, let height):
            try Geometry2D.validate(origin); try Geometry2D.positive(width); try Geometry2D.positive(height)
            try Geometry2D.validate(origin + Vec2(x: width, y: height))
        }
        _ = try Geometry2D.checked(rawLength)
    }

    private var rawLength: Double {
        switch self {
        case .point: return 0
        case .line(let a, let b): return a.distance(to: b)
        case .polyline(let points): return zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        case .circle(_, let radius): return 2 * .pi * radius
        case .arc(_, let radius, let start, let end):
            return radius * ((try? Geometry2D.arcSweep(start: start, end: end)) ?? .nan) * .pi / 180
        case .rectangle(_, let width, let height): return 2 * (width + height)
        }
    }

    public func measuredLength() throws -> Double { try validate(); return rawLength }
}

public enum Geometry2D {
    @discardableResult public static func checked(_ value: Double) throws -> Double {
        guard value.isFinite else { throw GeometryError.nonFiniteValue }; return value
    }
    public static func validate(_ value: Double) throws { _ = try checked(value) }
    public static func validate(_ point: Vec2) throws {
        guard point.isFinite else { throw GeometryError.nonFiniteValue }
    }
    public static func positive(_ value: Double) throws {
        try validate(value); guard value > 0 else { throw GeometryError.negativeValue }
    }
    public static func angleDegrees(from a: Vec2, to b: Vec2) throws -> Double {
        let na = try a.normalized(), nb = try b.normalized()
        return acos(max(-1, min(1, na.dot(nb)))) * 180 / .pi
    }
    public static func areParallel(_ a: Vec2, _ b: Vec2, toleranceDeg: Double = 0.01) throws -> Bool {
        try validate(toleranceDeg)
        guard (0...90).contains(toleranceDeg) else { throw GeometryError.degenerateGeometry }
        let angle = try angleDegrees(from: a, to: b)
        return min(angle, 180 - angle) <= toleranceDeg
    }
    public static func arePerpendicular(_ a: Vec2, _ b: Vec2, toleranceDeg: Double = 0.01) throws -> Bool {
        try validate(toleranceDeg)
        guard (0...90).contains(toleranceDeg) else { throw GeometryError.degenerateGeometry }
        return abs(try angleDegrees(from: a, to: b) - 90) <= toleranceDeg
    }
    public static func distance(from p: Vec2, toSegment a: Vec2, _ b: Vec2) throws -> Double {
        try validate(p); try validate(a); try validate(b)
        let length = try checked(a.distance(to: b))
        if length <= 1e-12 { return try checked(p.distance(to: a)) }
        let direction = try (b - a).normalized()
        let projection = try checked((p - a).dot(direction))
        return try checked(p.distance(to: a + direction * max(0, min(length, projection))))
    }
    public static func lineIntersection(_ p1: Vec2, _ d1: Vec2, _ p2: Vec2, _ d2: Vec2) throws -> Vec2 {
        try validate(p1); try validate(p2)
        let a = try d1.normalized(), b = try d2.normalized()
        let denominator = a.cross(b)
        guard abs(denominator) > 1e-12 else { throw GeometryError.degenerateGeometry }
        let t = try checked((p2 - p1).cross(b) / denominator)
        let result = p1 + a * t
        try validate(result); return result
    }
    public static func arcSweep(start: Double, end: Double) throws -> Double {
        try validate(start); try validate(end)
        let delta = try checked(end - start)
        guard delta != 0, abs(delta) <= 360 else { throw GeometryError.degenerateGeometry }
        if abs(delta) == 360 { return 360 }
        return delta > 0 ? delta : delta + 360
    }
    public static func rectangleDiagonal(width: Double, height: Double) throws -> Double {
        try positive(width); try positive(height)
        return try checked(hypot(width, height))
    }
}

/// Only independent inputs are stored. All contours and lengths are evaluated on demand.
public struct FrameParameters: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let profile: ProfileSpec
    public init(width: Double, height: Double, profile: ProfileSpec) throws {
        try Geometry2D.positive(width); try Geometry2D.positive(height); try profile.validate()
        guard width <= 100_000, height <= 100_000,
              width > 2 * profile.widthMm, height > 2 * profile.widthMm else { throw GeometryError.degenerateGeometry }
        self.width = width; self.height = height; self.profile = profile
    }
    public var innerWidth: Double { width - 2 * profile.widthMm }
    public var innerHeight: Double { height - 2 * profile.widthMm }
    public var outerContour: GeometryElement2D { .rectangle(origin: .zero, width: width, height: height) }
    public var innerContour: GeometryElement2D {
        .rectangle(origin: .init(x: profile.widthMm, y: profile.widthMm), width: innerWidth, height: innerHeight)
    }
    /// Butt-jointed frame: horizontal members span the full width; vertical members fit between them.
    public func length(for role: String) -> Double? {
        switch role {
        case "rahmen_oben", "rahmen_unten": return width
        case "rahmen_links", "rahmen_rechts": return innerHeight
        case "querstrebe": return innerWidth
        case "strebe": return innerHeight
        default: return nil
        }
    }
}
