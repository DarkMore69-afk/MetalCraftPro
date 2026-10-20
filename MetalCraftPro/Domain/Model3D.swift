//
//  Model3D.swift
//  MetalCraftPro
//
//  Deterministische 3D-Baugruppe aus der parametrischen 2D-Geometrie:
//  Profilquerschnitte (mit Eckradien/Fasen), Extrusion/Sweep entlang der Kontur
//  mit Gehrungsebenen, Bohrungen/Aussparungen als Querschnitts-Konturen
//  (echte Difference in Kap- und Wandflächen), Rotation und Translation über
//  die Platzierung, Union auf Mesh-Ebene zum Rendern.
//  Millimeter throughout; pure values, no UI and no storage.
//

import Foundation

// MARK: - Vektor & Mesh

public struct Vec3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    public static let zero = Vec3(x: 0, y: 0, z: 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { .init(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { .init(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { .init(x: a.x * s, y: a.y * s, z: a.z * s) }

    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vec3) -> Vec3 {
        .init(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x)
    }
    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public func distance(to o: Vec3) -> Double { (self - o).magnitude }
    /// nil bei nicht-endlichen oder degenerierten Werten – niemals stilles Clamping.
    public func normalized() -> Vec3? {
        guard isFinite else { return nil }
        let length = magnitude
        guard length > 1e-12 else { return nil }
        return self * (1 / length)
    }
}

/// Indiziertes Dreiecksnetz mit Normalen. Union = Zusammenführen mit Index-Versatz;
/// Positionen bleiben dabei exakt (kein Verebnen, keine Kopie der 2D-Geometrie).
public struct Mesh3D: Equatable, Sendable {
    public var positions: [Vec3] = []
    public var normals: [Vec3] = []
    public var indices: [UInt32] = []

    public init() {}
    public var isEmpty: Bool { indices.isEmpty }
    public var triangleCount: Int { indices.count / 3 }
    public var isConsistent: Bool {
        indices.count % 3 == 0
            && positions.count == normals.count
            && indices.allSatisfy { Int($0) < positions.count }
            && positions.allSatisfy(\.isFinite)
            && normals.allSatisfy(\.isFinite)
    }

    public mutating func append(_ other: Mesh3D) {
        let offset = UInt32(positions.count)
        positions += other.positions
        normals += other.normals
        indices += other.indices.map { $0 + offset }
    }

    public static func union(_ meshes: [Mesh3D]) -> Mesh3D {
        var result = Mesh3D()
        for mesh in meshes { result.append(mesh) }
        return result
    }

    public func boundingBox() -> (min: Vec3, max: Vec3)? {
        guard let first = positions.first else { return nil }
        var low = first, high = first
        for point in positions {
            low = .init(x: min(low.x, point.x), y: min(low.y, point.y), z: min(low.z, point.z))
            high = .init(x: max(high.x, point.x), y: max(high.y, point.y), z: max(high.z, point.z))
        }
        return (low, high)
    }
}

// MARK: - Profilquerschnitt

/// Querschnitt in der Profilebene: u = Tiefe (quer zur Bauteilebene), v = Profilhöhe.
/// Außenkontur gegen den Uhrzeigersinn, Bohrungen/Aussparungen im Uhrzeigersinn.
public struct SectionLoops: Equatable, Sendable {
    public var outer: [Vec2]
    public var holes: [[Vec2]]
    public init(outer: [Vec2], holes: [[Vec2]] = []) { self.outer = outer; self.holes = holes }
}

public enum ProfileSection {

    /// Querschnitt eines Profils, auf die Bounding-Box-Mitte zentriert.
    /// Rohre erhalten den realistischen Eckradius ~2 × Wandstärke (Idealisierung des Modells).
    public static func crossSection(for spec: ProfileSpec) throws -> SectionLoops {
        try spec.validate()
        let h = spec.heightMm, w = spec.widthMm, t = spec.thicknessMm
        let s = spec.webThicknessMm > 0 ? spec.webThicknessMm : t

        func rectangle(_ width: Double, _ height: Double) -> [Vec2] {
            [Vec2(x: -width / 2, y: -height / 2), .init(x: width / 2, y: -height / 2),
             .init(x: width / 2, y: height / 2), .init(x: -width / 2, y: height / 2)]
        }
        func circle(_ diameter: Double) -> [Vec2] {
            let radius = diameter / 2
            let count = 32
            return (0..<count).map { index in
                let angle = Double(index) / Double(count) * 2 * .pi
                return Vec2(x: radius * cos(angle), y: radius * sin(angle))
            }
        }

        var section = SectionLoops(outer: [])
        switch spec.type {
        case .vierkantrohr, .rechteckrohr:
            let radius = min(2 * t, min(h, w) / 4)
            section.outer = roundedRectangle(width: w, height: h, radius: radius)
            let innerWidth = w - 2 * t, innerHeight = h - 2 * t
            if innerWidth > 0, innerHeight > 0 {
                section.holes = [roundedRectangle(width: innerWidth, height: innerHeight,
                                                  radius: max(0, radius - t)).reversed()]
            }
        case .rundrohr:
            section.outer = circle(h)
            let inner = h - 2 * t
            if inner > 0 { section.holes = [circle(inner).reversed()] }
        case .rundstahl:
            section.outer = circle(h)
        case .flachstahl, .blech:
            // Flachmaterial steht auf der Kante: sichtbare Breite = widthMm, Dicke = thicknessMm.
            section.outer = rectangle(t, w)
        case .winkelstahl:
            section.outer = [
                Vec2(x: -w / 2, y: -h / 2), .init(x: w / 2, y: -h / 2),
                .init(x: w / 2, y: -h / 2 + t), .init(x: -w / 2 + t, y: -h / 2 + t),
                .init(x: -w / 2 + t, y: h / 2), .init(x: -w / 2, y: h / 2)
            ]
        case .uProfil:
            section.outer = [
                Vec2(x: -w / 2, y: -h / 2), .init(x: w / 2, y: -h / 2), .init(x: w / 2, y: h / 2),
                .init(x: w / 2 - s, y: h / 2), .init(x: w / 2 - s, y: -h / 2 + t),
                .init(x: -w / 2 + s, y: -h / 2 + t), .init(x: -w / 2 + s, y: h / 2),
                .init(x: -w / 2, y: h / 2)
            ]
        case .tProfil:
            section.outer = [
                Vec2(x: -w / 2, y: -h / 2), .init(x: w / 2, y: -h / 2), .init(x: w / 2, y: -h / 2 + t),
                .init(x: s / 2, y: -h / 2 + t), .init(x: s / 2, y: h / 2), .init(x: -s / 2, y: h / 2),
                .init(x: -s / 2, y: -h / 2 + t), .init(x: -w / 2, y: -h / 2 + t)
            ]
        case .hProfil, .iProfil:
            section.outer = [
                Vec2(x: -w / 2, y: -h / 2), .init(x: w / 2, y: -h / 2), .init(x: w / 2, y: -h / 2 + t),
                .init(x: s / 2, y: -h / 2 + t), .init(x: s / 2, y: h / 2 - t), .init(x: w / 2, y: h / 2 - t),
                .init(x: w / 2, y: h / 2), .init(x: -w / 2, y: h / 2), .init(x: -w / 2, y: h / 2 - t),
                .init(x: -s / 2, y: h / 2 - t), .init(x: -s / 2, y: -h / 2 + t), .init(x: -w / 2, y: -h / 2 + t)
            ]
        }
        section.outer = Self.forceOrientation(section.outer, clockwise: false)
        section.holes = section.holes.map { Self.forceOrientation($0, clockwise: true) }
        return Self.centered(section)
    }

    /// Fase: Variante mit abgeschrägten Profil-Ecken (gleiche Zentrierung).
    public static func chamferedCrossSection(for spec: ProfileSpec) throws -> SectionLoops {
        var section = try crossSection(for: spec)
        guard spec.type == .vierkantrohr || spec.type == .rechteckrohr else { return section }
        let c = min(spec.thicknessMm, min(spec.heightMm, spec.widthMm) / 4)
        func chamferLoop(_ loop: [Vec2]) -> [Vec2] {
            loop.flatMap { point -> [Vec2] in
                let signX = point.x >= 0 ? 1.0 : -1.0
                return [Vec2(x: point.x - signX * c, y: point.y), point]
            }
        }
        section.outer = Self.forceOrientation(chamferLoop(section.outer), clockwise: false)
        section.holes = section.holes.map { Self.forceOrientation(chamferLoop($0), clockwise: true) }
        return Self.centered(section)
    }

    static func roundedRectangle(width: Double, height: Double, radius: Double) -> [Vec2] {
        guard radius > 0.01 else {
            return [Vec2(x: -width / 2, y: -height / 2), .init(x: width / 2, y: -height / 2),
                    .init(x: width / 2, y: height / 2), .init(x: -width / 2, y: height / 2)]
        }
        var points: [Vec2] = []
        let segments = 5
        let corners: [(Vec2, Double)] = [
            (Vec2(x: width / 2 - radius, y: height / 2 - radius), 0.0),
            (Vec2(x: -width / 2 + radius, y: height / 2 - radius), Double.pi / 2),
            (Vec2(x: -width / 2 + radius, y: -height / 2 + radius), Double.pi),
            (Vec2(x: width / 2 - radius, y: -height / 2 + radius), 3 * Double.pi / 2)
        ]
        for (center, start) in corners {
            for step in 0...segments {
                let angle = start + Double(step) / Double(segments) * Double.pi / 2
                points.append(Vec2(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            }
        }
        return points
    }

    static func signedArea(_ loop: [Vec2]) -> Double {
        guard loop.count > 2 else { return 0 }
        var area = 0.0
        for index in loop.indices {
            let a = loop[index], b = loop[(index + 1) % loop.count]
            area += a.cross(b)
        }
        return area / 2
    }

    static func forceOrientation(_ loop: [Vec2], clockwise: Bool) -> [Vec2] {
        let area = signedArea(loop)
        if clockwise ? area > 0 : area < 0 { return loop.reversed() }
        return loop
    }

    static func centered(_ section: SectionLoops) -> SectionLoops {
        var low = Vec2(x: .infinity, y: .infinity), high = Vec2(x: -.infinity, y: -.infinity)
        for loop in [section.outer] + section.holes {
            for point in loop {
                low = Vec2(x: min(low.x, point.x), y: min(low.y, point.y))
                high = Vec2(x: max(high.x, point.x), y: max(high.y, point.y))
            }
        }
        guard low.x.isFinite else { return section }
        let offset = Vec2(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2)
        var result = section
        result.outer = section.outer.map { $0 - offset }
        result.holes = section.holes.map { $0.map { $0 - offset } }
        return result
    }
}

// MARK: - Sweep mit Gehrungsebenen

public struct SweepSpec: Equatable, Sendable {
    public var start: Vec3
    public var end: Vec3
    /// Gewünschte v-Richtung des Querschnitts (wird orthogonal zur Achse gemacht).
    public var up: Vec3
    /// Schnittwinkel der Enden: 90° = stumpf, 45° = Gehrung.
    public var startCutDeg: Double
    public var endCutDeg: Double
    /// Kipprichtung der Gehrung (+1/−1 entlang der v-Achse).
    public var startTiltSign: Double
    public var endTiltSign: Double

    public init(start: Vec3, end: Vec3, up: Vec3,
                startCutDeg: Double = 90, endCutDeg: Double = 90,
                startTiltSign: Double = 1, endTiltSign: Double = 1) {
        self.start = start; self.end = end; self.up = up
        self.startCutDeg = startCutDeg; self.endCutDeg = endCutDeg
        self.startTiltSign = startTiltSign; self.endTiltSign = endTiltSign
    }
}

public enum MeshBuilder {

    /// Extrudiert den Querschnitt entlang der Strecke und schneidet die Enden mit
    /// den Schnittwinkeln (Gehrungen). Bohrungen der Sektion werden real ausgestanzt.
    public static func sweep(section: SectionLoops, spec: SweepSpec) throws -> Mesh3D {
        guard !section.outer.isEmpty else { throw GeometryError.degenerateGeometry }
        guard let axis = (spec.end - spec.start).normalized() else { throw GeometryError.degenerateGeometry }
        let length = try Geometry2D.checked(spec.start.distance(to: spec.end))
        guard length > 1e-9 else { throw GeometryError.degenerateGeometry }
        for angle in [spec.startCutDeg, spec.endCutDeg] {
            try Geometry2D.validate(angle)
            guard angle > 1, angle < 179 else { throw GeometryError.degenerateGeometry }
        }

        // Lokales Rahmen: u = R, v = U, w = Achse.
        var upVector = spec.up - axis * spec.up.dot(axis)
        if upVector.normalized() == nil {
            let fallback = abs(axis.dot(Vec3(x: 0, y: 1, z: 0))) > 0.9 ? Vec3(x: 0, y: 0, z: 1) : Vec3(x: 0, y: 1, z: 0)
            upVector = fallback - axis * fallback.dot(axis)
        }
        guard let v = upVector.normalized(), let u = axis.cross(v).normalized() else {
            throw GeometryError.degenerateGeometry
        }

        func planeNormal(atEnd: Bool, cutDeg: Double, tiltSign: Double) -> Vec3 {
            let beta = (90 - cutDeg) * .pi / 180
            let sign: Double = atEnd ? 1 : -1
            let candidate = axis * (sign * cos(beta)) + v * (tiltSign * sin(beta))
            return candidate.normalized() ?? (atEnd ? axis : axis * -1)
        }
        let startNormal = planeNormal(atEnd: false, cutDeg: spec.startCutDeg, tiltSign: spec.startTiltSign)
        let endNormal = planeNormal(atEnd: true, cutDeg: spec.endCutDeg, tiltSign: spec.endTiltSign)

        var mesh = Mesh3D()

        // Wände: für jede Kontur (außen + Bohrungen) einen Streifen von Start- zu Endstation.
        for loop in [section.outer] + section.holes where loop.count >= 2 {
            var wall = Mesh3D()
            for index in loop.indices {
                let a = loop[index], b = loop[(index + 1) % loop.count]
                let edge = b - a
                let edgeLength = max(1e-12, edge.magnitude)
                let normal2D = Vec2(x: edge.y / edgeLength, y: -edge.x / edgeLength)
                let normal3D = (u * normal2D.x + v * normal2D.y).normalized() ?? u
                let base = UInt32(wall.positions.count)
                let pA0 = spec.start + u * a.x + v * a.y
                let pB0 = spec.start + u * b.x + v * b.y
                let pA1 = spec.end + u * a.x + v * a.y
                let pB1 = spec.end + u * b.x + v * b.y
                for point in [pA0, pB0, pB1, pA1] { wall.positions.append(point); wall.normals.append(normal3D) }
                wall.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
            mesh.append(wall)
        }

        // Kapflächen: Kontur mit der Schnittebene halbraumweise stutzen, dann triangulieren.
        for (station, normal) in [(spec.start, startNormal), (spec.end, endNormal)] {
            let clippedOuter = Self.clip(loop: section.outer, u: u, v: v, base: station, normal: normal)
            guard clippedOuter.count >= 3 else { continue }
            var clippedHoles: [[Vec2]] = []
            for hole in section.holes {
                let clipped = Self.clip(loop: hole, u: u, v: v, base: station, normal: normal)
                if clipped.count >= 3 { clippedHoles.append(clipped) }
            }
            mesh.append(Self.capMesh(outer: clippedOuter, holes: clippedHoles,
                                     u: u, v: v, station: station, faceNormal: normal))
        }
        return mesh
    }

    /// Halbraum-Stutzung (Sutherland–Hodgman) in Querschnittskoordinaten:
    /// q = base + u·a + v·b liegt im Material, solange (q − base)·n ≤ 0.
    static func clip(loop: [Vec2], u: Vec3, v: Vec3, base: Vec3, normal: Vec3) -> [Vec2] {
        func value(_ point: Vec2) -> Double { (u * point.x + v * point.y).dot(normal) }
        var result: [Vec2] = []
        for index in loop.indices {
            let current = loop[index], next = loop[(index + 1) % loop.count]
            let currentValue = value(current), nextValue = value(next)
            if currentValue <= 0 { result.append(current) }
            if (currentValue < 0 && nextValue > 0) || (currentValue > 0 && nextValue < 0) {
                let t = currentValue / (currentValue - nextValue)
                result.append(current + (next - current) * t)
            }
        }
        return result
    }

    /// Kapfläche: Außenkontur + Bohrungen → über Brücken zu einem einfachen Polygon
    /// verschmolzen → Ohren-Triangulation. Normale zeigt entlang `faceNormal`.
    static func capMesh(outer: [Vec2], holes: [[Vec2]], u: Vec3, v: Vec3,
                        station: Vec3, faceNormal: Vec3) -> Mesh3D {
        var polygon = outer
        for hole in holes {
            guard let bridge = Self.bridgeIndices(polygon: polygon, hole: hole) else { continue }
            // Bohrkontur an der Brücke eingefügt, erster Punkt an beiden Brückenden doppelt.
            let rotated = (0...hole.count).map { offset in hole[(bridge.hole + offset) % hole.count] }
            polygon = Array(polygon[0...bridge.outer]) + rotated + Array(polygon[bridge.outer...])
        }
        var mesh = Mesh3D()
        let triangles = Triangulator.earClip(polygon)
        guard !triangles.isEmpty else { return mesh }
        let base = UInt32(mesh.positions.count)
        for point in polygon {
            mesh.positions.append(station + u * point.x + v * point.y)
            mesh.normals.append(faceNormal)
        }
        for (a, b, c) in triangles {
            var ia = base + UInt32(a), ib = base + UInt32(b), ic = base + UInt32(c)
            let pa = mesh.positions[Int(ia)], pb = mesh.positions[Int(ib)], pc = mesh.positions[Int(ic)]
            if (pb - pa).cross(pc - pa).dot(faceNormal) < 0 { swap(&ib, &ic) }
            mesh.indices += [ia, ib, ic]
        }
        return mesh
    }

    static func bridgeIndices(polygon: [Vec2], hole: [Vec2]) -> (outer: Int, hole: Int)? {
        guard !polygon.isEmpty, !hole.isEmpty else { return nil }
        var best: (outer: Int, hole: Int, distance: Double)?
        for i in polygon.indices {
            for j in hole.indices {
                let dx = polygon[i].x - hole[j].x, dy = polygon[i].y - hole[j].y
                let distance = dx * dx + dy * dy
                if best == nil || distance < best!.distance { best = (i, j, distance) }
            }
        }
        guard let result = best else { return nil }
        return (result.outer, result.hole)
    }

    /// Zylinder-Grundform (z. B. für Bohrungs-Darstellung oder Rundmaterial).
    public static func cylinder(radiusMm: Double, lengthMm: Double, segments: Int = 24) throws -> Mesh3D {
        try Geometry2D.positive(radiusMm); try Geometry2D.positive(lengthMm)
        let count = max(8, segments)
        var loop: [Vec2] = []
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * .pi
            loop.append(Vec2(x: radiusMm * cos(angle), y: radiusMm * sin(angle)))
        }
        return try sweep(section: SectionLoops(outer: ProfileSection.forceOrientation(loop, clockwise: false)),
                         spec: SweepSpec(start: .zero, end: Vec3(x: 0, y: lengthMm, z: 0), up: Vec3(x: 0, y: 0, z: 1)))
    }
}

// MARK: - Triangulation

public enum Triangulator {
    /// Ohren-Clipping für ein einfaches CCW-Polygon (auch nicht-konvex).
    public static func earClip(_ points: [Vec2]) -> [(Int, Int, Int)] {
        guard points.count >= 3 else { return [] }
        var indices = Array(points.indices)
        var triangles: [(Int, Int, Int)] = []
        let limit = points.count * points.count + 10
        var iterations = 0
        while indices.count > 3, iterations < limit {
            iterations += 1
            var clipped = false
            for position in indices.indices {
                let previousIndex = indices[(position + indices.count - 1) % indices.count]
                let currentIndex = indices[position]
                let nextIndex = indices[(position + 1) % indices.count]
                let a = points[previousIndex], b = points[currentIndex], c = points[nextIndex]
                guard isConvex(a, b, c) else { continue }
                let inner = indices.filter { $0 != previousIndex && $0 != currentIndex && $0 != nextIndex }
                guard !inner.contains(where: { isInside(points[$0], a, b, c) }) else { continue }
                triangles.append((previousIndex, currentIndex, nextIndex))
                indices.remove(at: position)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if indices.count == 3 { triangles.append((indices[0], indices[1], indices[2])) }
        return triangles
    }

    static func isConvex(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        (b - a).cross(c - b) > 1e-9
    }

    static func isInside(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        let d1 = (b - a).cross(p - a), d2 = (c - b).cross(p - b), d3 = (a - c).cross(p - c)
        return d1 >= -1e-9 && d2 >= -1e-9 && d3 >= -1e-9
    }
}

// MARK: - Bauteile aus dem parametrischen Modell

public struct ThreeDPartInput: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var positionNumber: Int
    public var quantity: Int
    public var role: String?
    public var profile: ProfileSpec

    public init(id: UUID, name: String, positionNumber: Int, quantity: Int, role: String?, profile: ProfileSpec) {
        self.id = id; self.name = name; self.positionNumber = positionNumber
        self.quantity = quantity; self.role = role; self.profile = profile
    }
}

public struct ThreeDInput: Sendable, Equatable {
    public var widthMm: Double
    public var heightMm: Double
    public var profile: ProfileSpec
    public var parts: [ThreeDPartInput]

    public init(widthMm: Double, heightMm: Double, profile: ProfileSpec, parts: [ThreeDPartInput]) {
        self.widthMm = widthMm; self.heightMm = heightMm; self.profile = profile; self.parts = parts
    }
}

/// Eine gerenderte Bauteil-Instanz: Querschnitt entlang der 2D-Kontur, platziert
/// durch Translation (Start/Ende) und Rotation (Achse + Hochvektor).
public struct PartInstance: Sendable, Equatable {
    public var partID: UUID
    public var name: String
    public var positionNumber: Int
    public var start: Vec3
    public var end: Vec3
    public var up: Vec3
    public var explodeDirection: Vec3
    public var section: SectionLoops

    public var lengthMm: Double { start.distance(to: end) }
}

public struct BuiltPart: Sendable, Equatable {
    public var partID: UUID
    public var name: String
    public var positionNumber: Int
    public var start: Vec3
    public var end: Vec3
    public var explodeDirection: Vec3
    public var mesh: Mesh3D
}

/// A CAD drilling, projected onto the visible face of its nearest matching part.
public struct CADDrillMarker: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var partID: UUID
    public var positionNumber: Int
    public var center: Vec3
    public var radiusMm: Double
}

public enum ThreeDModelBuilder {

    /// Platzierungen ausschließlich aus den Projektparametern (eine Geometriequelle).
    /// Butt-Frame: horizontale Rahmenprofile über die volle Breite, vertikale dazwischen,
    /// Streben gleichmäßig im Innenmaß verteilt.
    public static func placements(for input: ThreeDInput) throws -> [PartInstance] {
        let frame = try FrameParameters(width: input.widthMm, height: input.heightMm, profile: input.profile)
        let t = frame.profile.widthMm
        var instances: [PartInstance] = []
        for part in input.parts.sorted(by: { $0.positionNumber < $1.positionNumber }) {
            guard let role = part.role else { continue }
            let section = try ProfileSection.crossSection(for: part.profile)
            let quantity = max(1, part.quantity)

            func instance(_ start: Vec3, _ end: Vec3, up: Vec3) -> PartInstance {
                let center = (start + end) * 0.5
                let direction = Vec3(x: center.x - frame.width / 2, y: center.y - frame.height / 2, z: 0)
                return PartInstance(partID: part.id, name: part.name, positionNumber: part.positionNumber,
                                    start: start, end: end, up: up,
                                    explodeDirection: direction.normalized() ?? Vec3(x: 0, y: 0, z: 1),
                                    section: section)
            }

            switch role {
            case "rahmen_oben":
                instances.append(instance(Vec3(x: 0, y: frame.height - t / 2, z: 0),
                                          Vec3(x: frame.width, y: frame.height - t / 2, z: 0), up: Vec3(x: 0, y: 1, z: 0)))
            case "rahmen_unten":
                instances.append(instance(Vec3(x: 0, y: t / 2, z: 0),
                                          Vec3(x: frame.width, y: t / 2, z: 0), up: Vec3(x: 0, y: 1, z: 0)))
            case "rahmen_links":
                instances.append(instance(Vec3(x: t / 2, y: t, z: 0),
                                          Vec3(x: t / 2, y: frame.height - t, z: 0), up: Vec3(x: 0, y: 0, z: 1)))
            case "rahmen_rechts":
                instances.append(instance(Vec3(x: frame.width - t / 2, y: t, z: 0),
                                          Vec3(x: frame.width - t / 2, y: frame.height - t, z: 0), up: Vec3(x: 0, y: 0, z: 1)))
            case "querstrebe":
                instances.append(instance(Vec3(x: t, y: frame.height / 2, z: 0),
                                          Vec3(x: frame.width - t, y: frame.height / 2, z: 0), up: Vec3(x: 0, y: 0, z: 1)))
            case "strebe":
                for index in 0..<quantity {
                    let x = t + frame.innerWidth * Double(index + 1) / Double(quantity + 1)
                    instances.append(instance(Vec3(x: x, y: t, z: 0),
                                              Vec3(x: x, y: frame.height - t, z: 0), up: Vec3(x: 0, y: 0, z: 1)))
                }
            default:
                continue
            }
        }
        for candidate in instances {
            guard candidate.start.isFinite, candidate.end.isFinite, candidate.lengthMm > 0 else {
                throw GeometryError.degenerateGeometry
            }
        }
        return instances
    }

    /// Project 2D CAD holes onto the nearest manufactured member in the 3D model.
    /// Only holes whose centers lie within an actual projected profile section are assigned.
    public static func drillMarkers(drawing: CADDrawing, for input: ThreeDInput) -> [CADDrillMarker] {
        guard let placements = try? placements(for: input), !placements.isEmpty else { return [] }
        let holes = drawing.elements.filter { $0.kind == .hole }.sorted { $0.id.uuidString < $1.id.uuidString }
        var result: [CADDrillMarker] = []

        func contains(_ point: Vec2, in polygon: [Vec2]) -> Bool {
            guard polygon.count >= 3 else { return false }
            var inside = false
            for index in polygon.indices {
                let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                if (try? Geometry2D.distance(from: point, toSegment: a, b)) ?? .infinity <= 0.01 { return true }
                let crosses = (a.y > point.y) != (b.y > point.y)
                if crosses {
                    let intersectionX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                    if point.x < intersectionX { inside.toggle() }
                }
            }
            return inside
        }

        for hole in holes {
            guard let radius = hole.radius, radius.isFinite, radius > 0 else { continue }
            let point = Vec3(x: hole.a.x, y: hole.a.y, z: 0)
            var nearest: (marker: CADDrillMarker, score: Double)?
            for placement in placements {
                guard let axis = (placement.end - placement.start).normalized() else { continue }
                var up = placement.up - axis * placement.up.dot(axis)
                guard let v = up.normalized() else { continue }
                guard let u = axis.cross(v).normalized() else { continue }
                let delta = point - placement.start
                let along = delta.dot(axis)
                let length = placement.lengthMm
                guard along >= -radius, along <= length + radius else { continue }
                let sectionPoint = Vec2(x: delta.dot(u), y: delta.dot(v))
                guard contains(sectionPoint, in: placement.section.outer) else { continue }
                let clampedAlong = min(length, max(0, along))
                let base = placement.start + axis * clampedAlong
                let surfaceZ = placement.section.outer.map { (base + u * $0.x + v * $0.y).z }.max() ?? point.z
                let marker = CADDrillMarker(id: hole.id, partID: placement.partID,
                                            positionNumber: placement.positionNumber,
                                            center: Vec3(x: point.x, y: point.y, z: surfaceZ + 0.2),
                                            radiusMm: radius)
                let score = hypot(point.x - base.x, point.y - base.y)
                if nearest == nil || score < nearest!.score {
                    nearest = (marker, score)
                }
            }
            if let nearest { result.append(nearest.marker) }
        }
        return result
    }

    /// Projected drillings flow into the cut list as position-linked machining operations.
    public static func drillingCuts(drawing: CADDrawing, for input: ThreeDInput) -> [CutListCutInput] {
        let holesByID = Dictionary(drawing.elements.filter { $0.kind == .hole }.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        return drillMarkers(drawing: drawing, for: input).compactMap { marker in
            guard let hole = holesByID[marker.id] else { return nil }
            let note = "Bohrung Ø\(DeFormat.number(marker.radiusMm * 2)) · X \(DeFormat.number(hole.a.x)) Y \(DeFormat.number(hole.a.y)) mm"
            return CutListCutInput(partID: marker.partID, angleADeg: 90, angleBDeg: 90,
                                   machining: note, remark: "")
        }
    }

    /// Meshes je Instanz – deterministisch und ohne UI-Abhängigkeit, daher im Hintergrund lauffähig.
    public static func build(_ instances: [PartInstance]) throws -> [BuiltPart] {
        try instances.map { instance in
            let mesh = try MeshBuilder.sweep(section: instance.section,
                                             spec: SweepSpec(start: instance.start, end: instance.end, up: instance.up))
            guard !mesh.isEmpty, mesh.isConsistent else { throw GeometryError.degenerateGeometry }
            return BuiltPart(partID: instance.partID, name: instance.name, positionNumber: instance.positionNumber,
                             start: instance.start, end: instance.end,
                             explodeDirection: instance.explodeDirection, mesh: mesh)
        }
    }
}
