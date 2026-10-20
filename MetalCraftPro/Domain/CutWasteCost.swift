import Foundation

/// Cost and yield of purchasing stock for one profile/material group.
public struct ProfileCutCost: Identifiable, Sendable {
    public var id: String
    public var profileLabel: String
    public var materialGrade: String
    public var stockBarCount: Int
    public var reusableOffcutsMm: [Double]
    public var wasteMm: Double
    public var stockPurchaseEUR: Double?
    public var wasteCostEUR: Double?
    public var overlongPieceCount: Int

    public var totalOffcutMm: Double { reusableOffcutsMm.reduce(0, +) }
}

public struct CuttingCostSummary: Sendable {
    public var profiles: [ProfileCutCost]
    /// Sum of priced scrap only. Rows without a usable material price remain explicitly unpriced.
    public var wasteTotalEUR: Double?
    public var stockPurchaseTotalEUR: Double?
    public var unpricedProfileCount: Int
    public var overlongPieceCount: Int
}

/// Reuses the cut-list optimizer so estimates use exactly the same stock length,
/// kerf and offcut threshold as the workshop cutting plan.
public enum CuttingCostBuilder {
    public static let defaultStockLengthMm = 6000.0
    public static let defaultKerfMm = 3.0
    public static let minimumReusableOffcutMm = 200.0

    public static func estimate(entries: [CutListEntry], materialPrices: [MaterialPriceInput],
                                 stockLengthMm: Double = defaultStockLengthMm,
                                 kerfMm: Double = defaultKerfMm) throws -> CuttingCostSummary {
        guard stockLengthMm.isFinite, stockLengthMm > 0,
              kerfMm.isFinite, kerfMm >= 0, kerfMm < stockLengthMm else {
            throw GeometryError.negativeValue
        }
        let groups = Dictionary(grouping: entries) {
            "\($0.profile.id.uuidString)|\($0.materialGrade.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
        var rows: [ProfileCutCost] = []

        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            let profile = first.profile
            let grade = first.materialGrade
            let label = first.displayLabel
            let pieces = group.sorted {
                if $0.positionNumber != $1.positionNumber { return $0.positionNumber < $1.positionNumber }
                return $0.id.uuidString < $1.id.uuidString
            }.flatMap { entry in
                (0..<max(1, entry.quantity)).map { index in
                    CuttingPiece(id: "\(entry.id.uuidString)-\(index)", entryID: entry.id,
                                 positionNumber: entry.positionNumber, lengthMm: entry.lengthMm,
                                 profileLabel: label)
                }
            }
            let job = CuttingJob(pieces: pieces, stockLengthMm: stockLengthMm,
                                 kerfMm: kerfMm, minimumOffcutMm: minimumReusableOffcutMm)
            let bestPlan = try CuttingOptimizer.plans(for: job).first
            let bars = bestPlan?.bars ?? []
            let waste = bestPlan?.totalWasteMm ?? 0
            let offcuts = bars.map(\.offcutMm).filter { $0 > 0 }.sorted(by: >)
            let matching = materialPrices
                .filter {
                    $0.grade.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(grade) == .orderedSame
                        && $0.pricePerKg.isFinite && $0.pricePerKg >= 0
                }
                .map(\.pricePerKg)
            let price: Double?
            if let initial = matching.first, matching.allSatisfy({ $0 == initial }) { price = initial }
            else { price = nil }

            let stockCost = price.flatMap { rate -> Double? in
                let mass = profile.weightPerMeterKg * (stockLengthMm / 1000) * Double(bars.count)
                let amount = mass * rate
                return mass.isFinite && mass >= 0 && amount.isFinite && amount >= 0 ? amount : nil
            }
            let wasteCost = price.flatMap { rate -> Double? in
                let mass = profile.weightPerMeterKg * (waste / 1000)
                let amount = mass * rate
                return mass.isFinite && mass >= 0 && amount.isFinite && amount >= 0 ? amount : nil
            }
            let overlongCount = bestPlan?.overlongPieces.count ?? 0
            rows.append(ProfileCutCost(id: key, profileLabel: label, materialGrade: grade,
                                       stockBarCount: bars.count, reusableOffcutsMm: offcuts,
                                       wasteMm: waste, stockPurchaseEUR: stockCost,
                                       wasteCostEUR: wasteCost, overlongPieceCount: overlongCount))
        }

        var wasteTotal = 0.0
        var purchaseTotal = 0.0
        var wasteOverflow = false
        var purchaseOverflow = false
        for row in rows {
            if let cost = row.wasteCostEUR {
                wasteTotal += cost
                if !wasteTotal.isFinite { wasteOverflow = true }
            }
            if let cost = row.stockPurchaseEUR {
                purchaseTotal += cost
                if !purchaseTotal.isFinite { purchaseOverflow = true }
            }
        }
        let unpriced = rows.filter { $0.stockPurchaseEUR == nil }.count
        return CuttingCostSummary(
            profiles: rows,
            wasteTotalEUR: wasteOverflow ? nil : wasteTotal,
            stockPurchaseTotalEUR: purchaseOverflow ? nil : purchaseTotal,
            unpricedProfileCount: unpriced,
            overlongPieceCount: rows.reduce(0) { $0 + $1.overlongPieceCount })
    }
}
