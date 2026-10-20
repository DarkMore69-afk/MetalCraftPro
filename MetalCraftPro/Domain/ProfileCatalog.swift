//
//  ProfileCatalog.swift
//  MetalCraftPro
//
//  Metallbau-Profilkatalog: Standard- und benutzerdefinierte Profile
//  inkl. Querschnittsfläche und Gewicht pro Meter.
//

import Foundation

/// Profiltypen des Metallbaus.
public enum ProfileType: String, CaseIterable, Codable, Sendable, Identifiable {
    case vierkantrohr
    case rechteckrohr
    case rundrohr
    case flachstahl
    case winkelstahl
    case uProfil = "u_profil"
    case tProfil = "t_profil"
    case hProfil = "h_profil"
    case iProfil = "i_profil"
    case blech
    case rundstahl

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vierkantrohr: return "Vierkantrohr"
        case .rechteckrohr: return "Rechteckrohr"
        case .rundrohr: return "Rundrohr"
        case .flachstahl: return "Flachstahl"
        case .winkelstahl: return "Winkelstahl"
        case .uProfil: return "U-Profil"
        case .tProfil: return "T-Profil"
        case .hProfil: return "H-Profil"
        case .iProfil: return "I-Profil"
        case .blech: return "Blech"
        case .rundstahl: return "Rundstahl"
        }
    }

    public var iconSystemName: String {
        switch self {
        case .vierkantrohr: return "square"
        case .rechteckrohr: return "rectangle"
        case .rundrohr: return "circle"
        case .flachstahl: return "rectangle.compress.vertical"
        case .winkelstahl: return "angle"
        case .uProfil: return "u.square"
        case .tProfil: return "t.square"
        case .hProfil, .iProfil: return "i.square"
        case .blech: return "square.layers"
        case .rundstahl: return "circle.dotted"
        }
    }
}

/// Parametrische Spezifikation eines Profils.
public struct ProfileSpec: Codable, Equatable, Hashable, Sendable, Identifiable {

    public var id: UUID
    public var type: ProfileType
    public var name: String
    /// Hauptabmessung in mm (z. B. Höhe bzw. Durchmesser).
    public var heightMm: Double
    /// Breite in mm (bei symmetrischen Profilen = heightMm).
    public var widthMm: Double
    /// Wandstärke / Blechdicke in mm.
    public var thicknessMm: Double
    /// Stegdicke für U/T/H/I-Profile in mm.
    public var webThicknessMm: Double
    public var isCustom: Bool

    public init(
        id: UUID = UUID(),
        type: ProfileType,
        name: String,
        heightMm: Double,
        widthMm: Double,
        thicknessMm: Double,
        webThicknessMm: Double = 0,
        isCustom: Bool = false
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.heightMm = heightMm
        self.widthMm = widthMm
        self.thicknessMm = thicknessMm
        self.webThicknessMm = webThicknessMm
        self.isCustom = isCustom
    }

    /// Dichte von Baustahl in g/cm³.
    public static let steelDensityGCm3 = 7.85

    /// Idealised sharp-edged sections, not certified rolled-section table values.
    public func validate() throws {
        for value in [heightMm, widthMm, thicknessMm, webThicknessMm] {
            try Geometry2D.validate(value)
            guard value >= 0, value <= 100_000 else { throw GeometryError.negativeValue }
        }
        guard heightMm > 0, widthMm > 0 else { throw GeometryError.negativeValue }
        let h = heightMm, w = widthMm, t = thicknessMm
        let s = webThicknessMm > 0 ? webThicknessMm : t
        if type != .rundstahl { try Geometry2D.positive(t) }
        switch type {
        case .vierkantrohr:
            guard h == w, 2 * t < h else { throw GeometryError.degenerateGeometry }
        case .rechteckrohr:
            guard 2 * t < min(h, w) else { throw GeometryError.degenerateGeometry }
        case .rundrohr:
            guard h == w, 2 * t < h else { throw GeometryError.degenerateGeometry }
        case .winkelstahl:
            guard t < min(h, w) else { throw GeometryError.degenerateGeometry }
        case .uProfil, .hProfil, .iProfil:
            guard 2 * t < h, s > 0, s < w else { throw GeometryError.degenerateGeometry }
        case .tProfil:
            guard t < h, s > 0, s < w else { throw GeometryError.degenerateGeometry }
        case .flachstahl, .blech:
            guard t <= w else { throw GeometryError.degenerateGeometry }
        case .rundstahl:
            guard h == w else { throw GeometryError.degenerateGeometry }
        }
        try Geometry2D.positive(crossSectionAreaMm2)
    }

    /// Querschnittsfläche in mm² – deterministisch je Profiltyp.
    public var crossSectionAreaMm2: Double {
        let h = max(0, heightMm)
        let w = max(0, widthMm)
        let t = max(0, thicknessMm)
        let s = max(0, webThicknessMm)

        switch type {
        case .vierkantrohr:
            let inner = h - 2 * t
            return inner > 0 ? h * h - inner * inner : h * h
        case .rechteckrohr:
            let iw = w - 2 * t, ih = h - 2 * t
            let outer = w * h
            return (iw > 0 && ih > 0) ? outer - iw * ih : outer
        case .rundrohr:
            let inner = h - 2 * t
            let outer = .pi * h * h / 4
            return inner > 0 ? outer - .pi * inner * inner / 4 : outer
        case .flachstahl:
            return w * t
        case .winkelstahl:
            return (w + h - t) * t
        case .uProfil:
            // Zwei Flansche (Breite × t) plus Steg (Höhe − 2t) × Stegdicke
            let flanges = 2 * w * t
            let web = max(0, h - 2 * t) * (s > 0 ? s : t)
            return flanges + web
        case .tProfil:
            let flange = w * t
            let web = max(0, h - t) * (s > 0 ? s : t)
            return flange + web
        case .hProfil, .iProfil:
            let flanges = 2 * w * t
            let web = max(0, h - 2 * t) * (s > 0 ? s : t)
            return flanges + web
        case .blech:
            return w * t
        case .rundstahl:
            return .pi * h * h / 4
        }
    }

    /// Gewicht pro Meter in kg (Stahl).
    public var weightPerMeterKg: Double {
        crossSectionAreaMm2 * 0.001 * Self.steelDensityGCm3 // mm² × m × g/cm³ → kg/m
    }

    /// Kurzbezeichnung der Abmessungen, z. B. "40 × 40 × 2".
    public var dimensionLabel: String {
        func n(_ value: Double) -> String {
            value.formatted(.number.locale(Locale(identifier: "de_DE")).grouping(.never).precision(.fractionLength(0...3)))
        }
        switch type {
        case .rundrohr: return "Ø\(n(heightMm)) × \(n(thicknessMm))"
        case .rundstahl: return "Ø\(n(heightMm))"
        case .flachstahl, .blech: return "\(n(widthMm)) × \(n(thicknessMm))"
        default: return "\(n(heightMm)) × \(n(widthMm)) × \(n(thicknessMm))"
        }
    }
}

/// Katalog der Standardprofile + Verwaltung benutzerdefinierter Profile.
public enum ProfileCatalog {

    /// Alle Profile, die der Benutzer wählen kann.
    public static func standardCatalog() -> [ProfileSpec] {
        var specs: [ProfileSpec] = []

        func add(_ type: ProfileType, _ name: String, _ h: Double, _ w: Double, _ t: Double, _ s: Double = 0) {
            // Fixed catalogue identities survive launches, installs and repeated evaluations.
            let id = UUID(uuidString: String(format: "CA7A1000-0000-4000-8000-%012d", specs.count + 1))!
            specs.append(ProfileSpec(id: id, type: type, name: name, heightMm: h, widthMm: w, thicknessMm: t, webThicknessMm: s))
        }

        // Vierkantrohr
        add(.vierkantrohr, "20 × 20 × 2", 20, 20, 2)
        add(.vierkantrohr, "25 × 25 × 2", 25, 25, 2)
        add(.vierkantrohr, "30 × 30 × 2", 30, 30, 2)
        add(.vierkantrohr, "40 × 40 × 2", 40, 40, 2)
        add(.vierkantrohr, "40 × 40 × 3", 40, 40, 3)
        add(.vierkantrohr, "50 × 50 × 3", 50, 50, 3)
        add(.vierkantrohr, "60 × 60 × 4", 60, 60, 4)
        add(.vierkantrohr, "80 × 80 × 4", 80, 80, 4)
        // Rechteckrohr
        add(.rechteckrohr, "40 × 20 × 2", 40, 20, 2)
        add(.rechteckrohr, "60 × 40 × 3", 60, 40, 3)
        add(.rechteckrohr, "80 × 40 × 3", 80, 40, 3)
        add(.rechteckrohr, "100 × 50 × 4", 100, 50, 4)
        // Rundrohr
        add(.rundrohr, "21,3 × 2,6", 21.3, 21.3, 2.6)
        add(.rundrohr, "33,7 × 2,6", 33.7, 33.7, 2.6)
        add(.rundrohr, "48,3 × 3,2", 48.3, 48.3, 3.2)
        add(.rundrohr, "60,3 × 3,6", 60.3, 60.3, 3.6)
        // Flachstahl
        add(.flachstahl, "30 × 5", 30, 30, 5)
        add(.flachstahl, "40 × 5", 40, 40, 5)
        add(.flachstahl, "50 × 6", 50, 50, 6)
        // Winkelstahl
        add(.winkelstahl, "30 × 30 × 4", 30, 30, 4)
        add(.winkelstahl, "40 × 40 × 4", 40, 40, 4)
        add(.winkelstahl, "50 × 50 × 5", 50, 50, 5)
        // U-Profil
        add(.uProfil, "U 40 × 40 × 5", 40, 40, 5)
        add(.uProfil, "U 60 × 40 × 5", 60, 40, 5)
        // T-Profil
        add(.tProfil, "T 40 × 40 × 5", 40, 40, 5)
        // H-Profil
        add(.hProfil, "H 100 × 100 × 6 (idealisiert)", 100, 100, 6, 5)
        // I-Profil
        add(.iProfil, "I 100 × 55 × 4 (idealisiert)", 100, 55, 4, 3)
        // Blech
        add(.blech, "Blech 1000 × 5", 1000, 1000, 5)
        add(.blech, "Blech 1000 × 8", 1000, 1000, 8)
        // Rundstahl
        add(.rundstahl, "Ø10", 10, 10, 0)
        add(.rundstahl, "Ø12", 12, 12, 0)
        add(.rundstahl, "Ø16", 16, 16, 0)

        return specs
    }

    /// Sucht ein Profil anhand seines Namens im Katalog.
    public static func spec(named name: String) -> ProfileSpec? {
        standardCatalog().first { $0.name == name }
    }

    /// Das Referenzprofil 40 × 40 × 2 für das Demo-Projekt.
    public static let squareTube40x40x2 = ProfileSpec(
        id: UUID(uuidString: "CA7A1000-0000-4000-8000-000000000004")!,
        type: .vierkantrohr, name: "40 × 40 × 2", heightMm: 40, widthMm: 40, thicknessMm: 2
    )
}
