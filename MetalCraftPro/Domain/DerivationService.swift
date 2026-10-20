import Foundation

/// Read-only projections from the canonical project parameters. Never writes caches.
@MainActor
enum DerivationService {
    static func totalPartLengthMm(of project: MCProject) -> Double {
        project.parts.reduce(0) { $0 + $1.lengthMm * Double($1.quantity) }
    }
    static func totalPartWeightKg(of project: MCProject) throws -> Double {
        var total = 0.0
        for part in project.parts {
            total += try CalculationEngine.profileWeight(lengthMm: part.lengthMm * Double(part.quantity), profile: part.profileSpec ?? project.profileSpec)
        }
        return try Geometry2D.checked(total)
    }
}
