import Foundation

/// Deterministic services. Dimensions are millimetres, weights kilograms, density g/cm³.
/// Every boundary and result is checked; invalid input is never silently clamped.
public enum CalculationEngine {
    public static func pythagoras(a: Double, b: Double) throws -> Double {
        try nonnegative(a, b)
        return try Geometry2D.checked(hypot(a, b))
    }
    public static func rectangleDiagonal(width: Double, height: Double) throws -> Double {
        try Geometry2D.rectangleDiagonal(width: width, height: height)
    }
    public static func frameInnerMeasure(outerMm: Double, profileWidthMm: Double, sides: Int = 2) throws -> Double {
        try Geometry2D.positive(outerMm); try Geometry2D.positive(profileWidthMm)
        guard sides > 0 else { throw GeometryError.negativeValue }
        let result = try Geometry2D.checked(outerMm - Double(sides) * profileWidthMm)
        guard result > 0 else { throw GeometryError.degenerateGeometry }
        return result
    }
    public static func barWeight(lengthMm: Double, kgPerMeter: Double) throws -> Double {
        try nonnegative(lengthMm, kgPerMeter)
        return try Geometry2D.checked(lengthMm / 1000 * kgPerMeter)
    }
    public static func profileWeight(lengthMm: Double, profile: ProfileSpec, densityGCm3: Double = 7.85) throws -> Double {
        try profile.validate(); try Geometry2D.positive(densityGCm3)
        return try barWeight(lengthMm: lengthMm, kgPerMeter: profile.crossSectionAreaMm2 * densityGCm3 / 1000)
    }
    public static func sheetWeight(areaM2: Double, thicknessMm: Double, densityGCm3: Double = 7.85) throws -> Double {
        try nonnegative(areaM2); try Geometry2D.positive(thicknessMm); try Geometry2D.positive(densityGCm3)
        return try Geometry2D.checked(areaM2 * thicknessMm * densityGCm3)
    }
    public static func plateWeight(lengthMm: Double, widthMm: Double, thicknessMm: Double, densityGCm3: Double = 7.85) throws -> Double {
        try nonnegative(lengthMm, widthMm)
        return try sheetWeight(areaM2: lengthMm / 1000 * (widthMm / 1000), thicknessMm: thicknessMm, densityGCm3: densityGCm3)
    }
    private static func nonnegative(_ values: Double...) throws {
        for value in values {
            try Geometry2D.validate(value)
            guard value >= 0 else { throw GeometryError.negativeValue }
        }
    }
}
