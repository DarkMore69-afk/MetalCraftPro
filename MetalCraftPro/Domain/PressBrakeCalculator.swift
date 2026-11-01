//
//  PressBrakeCalculator.swift
//  MetalCraftPro
//
//  Sheet-metal development length and a transparent bend-order heuristic.
//  Dimensions are millimetres; bend angles are rotations from the flat state.
//

import Foundation

public struct PressBrakeInput: Equatable, Sendable {
    /// Outside flange dimensions measured to theoretical sharp corners.
    public var legLengthsMm: [Double]
    /// Bend rotations from flat (90° is a right-angle bend).
    public var bendAnglesDeg: [Double]
    /// Strip width measured along the bend lines.
    public var sheetWidthMm: Double
    public var thicknessMm: Double
    public var insideRadiusMm: Double
    /// Neutral-axis factor; must be calibrated for material and tooling.
    public var kFactor: Double
    public var vOpeningMm: Double

    public init(legLengthsMm: [Double], bendAnglesDeg: [Double], sheetWidthMm: Double,
                thicknessMm: Double, insideRadiusMm: Double, kFactor: Double, vOpeningMm: Double) {
        self.legLengthsMm = legLengthsMm
        self.bendAnglesDeg = bendAnglesDeg
        self.sheetWidthMm = sheetWidthMm
        self.thicknessMm = thicknessMm
        self.insideRadiusMm = insideRadiusMm
        self.kFactor = kFactor
        self.vOpeningMm = vOpeningMm
    }
}

public struct PressBrakeBendResult: Equatable, Sendable, Identifiable {
    public var number: Int
    public var angleDeg: Double
    public var bendAllowanceMm: Double
    public var bendDeductionMm: Double
    public var adjacentFlangeMinMm: Double
    public var id: Int { number }
}

public struct PressBrakeResult: Equatable, Sendable {
    public var flatLengthMm: Double
    public var flatWidthMm: Double
    public var blankAreaM2: Double
    public var totalBendAllowanceMm: Double
    public var totalBendDeductionMm: Double
    public var recommendedVOpeningMm: Double
    public var bendOrder: [Int]
    public var bends: [PressBrakeBendResult]
    public var sequenceNote: String
}

public enum PressBrakeError: Error, LocalizedError {
    case invalidLegs
    case mismatchedBends
    case invalidDimensions
    case invalidKFactor
    case invalidAngle
    case negativeBlank

    public var errorDescription: String? {
        switch self {
        case .invalidLegs: return "Gib 2 bis 12 Flansch-Außenmaße ein."
        case .mismatchedBends: return "Die Zahl der Biegewinkel muss der Zahl der Flansche minus eins entsprechen."
        case .invalidDimensions: return "Blechbreite, Dicke, Radius und V-Öffnung müssen gültige positive Werte sein."
        case .invalidKFactor: return "Der K-Faktor muss zwischen 0 und 0,5 liegen."
        case .invalidAngle: return "Jeder Biegewinkel muss größer als 0° und kleiner als 180° sein."
        case .negativeBlank: return "Die Eingaben ergeben kein positives Abwicklungsmaß."
        }
    }
}

public enum PressBrakeCalculator {
    /// Bend allowance and outside bend deduction for each bend.
    /// Flat length = sum(outside flange dimensions) - sum(bend deductions).
    public static func calculate(_ input: PressBrakeInput) throws -> PressBrakeResult {
        guard (2...12).contains(input.legLengthsMm.count),
              input.legLengthsMm.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw PressBrakeError.invalidLegs
        }
        guard input.bendAnglesDeg.count == input.legLengthsMm.count - 1 else {
            throw PressBrakeError.mismatchedBends
        }
        guard input.bendAnglesDeg.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 180 }) else {
            throw PressBrakeError.invalidAngle
        }
        guard input.sheetWidthMm.isFinite, input.sheetWidthMm > 0,
              input.thicknessMm.isFinite, input.thicknessMm > 0,
              input.insideRadiusMm.isFinite, input.insideRadiusMm >= 0,
              input.vOpeningMm.isFinite, input.vOpeningMm > 0 else {
            throw PressBrakeError.invalidDimensions
        }
        guard input.kFactor.isFinite, (0...0.5).contains(input.kFactor) else {
            throw PressBrakeError.invalidKFactor
        }

        let bends = input.bendAnglesDeg.enumerated().map { index, angle -> PressBrakeBendResult in
            let theta = angle * .pi / 180
            let allowance = theta * (input.insideRadiusMm + input.kFactor * input.thicknessMm)
            let outsideSetback = (input.insideRadiusMm + input.thicknessMm) * tan(theta / 2)
            let deduction = 2 * outsideSetback - allowance
            return PressBrakeBendResult(
                number: index + 1,
                angleDeg: angle,
                bendAllowanceMm: allowance,
                bendDeductionMm: deduction,
                adjacentFlangeMinMm: min(input.legLengthsMm[index], input.legLengthsMm[index + 1])
            )
        }

        let totalDeduction = bends.reduce(0) { $0 + $1.bendDeductionMm }
        let flatLength = input.legLengthsMm.reduce(0, +) - totalDeduction
        guard flatLength.isFinite, flatLength > 0 else { throw PressBrakeError.negativeBlank }

        // A short adjacent return is more likely to become difficult to handle or access
        // after neighbouring bends, so bend those returns first. This is a heuristic:
        // it cannot replace machine/tool-specific collision simulation.
        let order = bends.sorted {
            if $0.adjacentFlangeMinMm != $1.adjacentFlangeMinMm {
                return $0.adjacentFlangeMinMm < $1.adjacentFlangeMinMm
            }
            return $0.number < $1.number
        }.map(\.number)

        return PressBrakeResult(
            flatLengthMm: flatLength,
            flatWidthMm: input.sheetWidthMm,
            blankAreaM2: flatLength * input.sheetWidthMm / 1_000_000,
            totalBendAllowanceMm: bends.reduce(0) { $0 + $1.bendAllowanceMm },
            totalBendDeductionMm: totalDeduction,
            recommendedVOpeningMm: recommendedVOpening(forThicknessMm: input.thicknessMm),
            bendOrder: order,
            bends: bends,
            sequenceNote: "Vorschlag: kurze Rückläufe zuerst. Maschinen- und Werkzeugkollisionen sind ohne Pressen- und Werkzeugdaten nicht geprüft."
        )
    }

    /// General air-bending guide: V opening is approximately 6–12× material thickness.
    public static func recommendedVOpening(forThicknessMm thickness: Double) -> Double {
        guard thickness.isFinite, thickness > 0 else { return 0 }
        let factor: Double
        if thickness < 3 { factor = 6 }
        else if thickness <= 8 { factor = 8 }
        else if thickness <= 10 { factor = 10 }
        else { factor = 12 }
        return thickness * factor
    }
}
