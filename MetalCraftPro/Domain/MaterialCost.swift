import Foundation

public struct MaterialPriceInput: Sendable {
    public var grade: String
    public var pricePerKg: Double

    public init(grade: String, pricePerKg: Double) {
        self.grade = grade
        self.pricePerKg = pricePerKg
    }
}

public struct PurchasedPartPriceInput: Sendable {
    public var id: UUID
    public var positionNumber: Int
    public var name: String
    public var quantity: Int
    public var unitPrice: Double?
    public var laborHours: Double?

    public init(id: UUID, positionNumber: Int, name: String, quantity: Int, unitPrice: Double?, laborHours: Double? = nil) {
        self.id = id
        self.positionNumber = positionNumber
        self.name = name
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.laborHours = laborHours
    }
}

public enum MaterialCostKind: Equatable, Sendable {
    case fabricated, purchased
}

public struct MaterialCostLine: Identifiable, Sendable {
    public var id: UUID
    public var positionNumber: Int
    public var name: String
    public var detail: String
    public var kind: MaterialCostKind
    public var quantity: Int
    public var weightKg: Double?
    public var amountEUR: Double?
    public var priceDescription: String
    public var laborHours: Double?
    public var laborEUR: Double?

    public init(id: UUID, positionNumber: Int, name: String, detail: String,
                kind: MaterialCostKind, quantity: Int, weightKg: Double?,
                amountEUR: Double?, priceDescription: String,
                laborHours: Double? = nil, laborEUR: Double? = nil) {
        self.id = id
        self.positionNumber = positionNumber
        self.name = name
        self.detail = detail
        self.kind = kind
        self.quantity = quantity
        self.weightKg = weightKg
        self.amountEUR = amountEUR
        self.priceDescription = priceDescription
        self.laborHours = laborHours
        self.laborEUR = laborEUR
    }
}

public struct MaterialCostEstimate: Sendable {
    public var lines: [MaterialCostLine]
    /// Previously calculated material and purchased-part subtotal.
    public var totalEUR: Double?
    public var pricedPositionCount: Int
    public var unpricedPositionCount: Int
    public var laborTotalEUR: Double?
    public var totalWithLaborEUR: Double?
    public var laborRateEURPerHour: Double?
    public var unpricedLaborPositionCount: Int
    public var cuttingSummary: CuttingCostSummary?

    public init(lines: [MaterialCostLine], totalEUR: Double?, pricedPositionCount: Int,
                unpricedPositionCount: Int, laborTotalEUR: Double? = 0,
                totalWithLaborEUR: Double? = nil, laborRateEURPerHour: Double? = nil,
                unpricedLaborPositionCount: Int = 0, cuttingSummary: CuttingCostSummary? = nil) {
        self.lines = lines
        self.totalEUR = totalEUR
        self.pricedPositionCount = pricedPositionCount
        self.unpricedPositionCount = unpricedPositionCount
        self.laborTotalEUR = laborTotalEUR
        self.totalWithLaborEUR = totalWithLaborEUR ?? totalEUR
        self.laborRateEURPerHour = laborRateEURPerHour
        self.unpricedLaborPositionCount = unpricedLaborPositionCount
        self.cuttingSummary = cuttingSummary
    }

    public var topPositions: [MaterialCostLine] {
        lines.filter { $0.amountEUR != nil }
            .sorted {
                if $0.amountEUR != $1.amountEUR { return ($0.amountEUR ?? 0) > ($1.amountEUR ?? 0) }
                if $0.positionNumber != $1.positionNumber { return $0.positionNumber < $1.positionNumber }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(3)
            .map { $0 }
    }
}

/// Pure, live projection of position costs and labor into one local estimate.
public enum MaterialCostBuilder {
    public static func estimate(entries: [CutListEntry], materialPrices: [MaterialPriceInput],
                                 purchasedParts: [PurchasedPartPriceInput],
                                 laborRateEURPerHour: Double? = nil,
                                 laborHoursByPosition: [UUID: Double] = [:],
                                 stockLengthMm: Double = CuttingCostBuilder.defaultStockLengthMm,
                                 kerfMm: Double = CuttingCostBuilder.defaultKerfMm) -> MaterialCostEstimate {
        let safeLaborRate = laborRateEURPerHour.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        var lines: [MaterialCostLine] = []

        for entry in entries {
            let gradeKey = entry.materialGrade.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchingPrices = materialPrices
                .filter { $0.grade.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == gradeKey
                    && $0.pricePerKg.isFinite && $0.pricePerKg >= 0 }
                .map(\.pricePerKg)
            let materialPrice: Double?
            if let first = matchingPrices.first, matchingPrices.allSatisfy({ $0 == first }) {
                materialPrice = first
            } else {
                materialPrice = nil
            }

            let weight = try? CalculationEngine.profileWeight(
                lengthMm: entry.lengthMm * Double(max(1, entry.quantity)), profile: entry.profile)
            let safeWeight = weight.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let amount = safeWeight.flatMap { weight in
                materialPrice.flatMap { price in
                    let result = weight * price
                    return result.isFinite && result >= 0 ? result : nil
                }
            }
            let priceLabel: String
            if matchingPrices.count > 1 && Set(matchingPrices).count > 1 {
                priceLabel = "Materialpreis nicht eindeutig"
            } else if let materialPrice {
                priceLabel = "\(number(materialPrice)) €/kg · \(number(safeWeight ?? 0)) kg"
            } else {
                priceLabel = "Kein eindeutiger €/kg-Preis für \(entry.materialGrade.isEmpty ? "Werkstoff offen" : entry.materialGrade)"
            }
            lines.append(MaterialCostLine(
                id: entry.id, positionNumber: entry.positionNumber, name: entry.name,
                detail: "\(entry.quantity) × \(entry.displayLabel) · \(number(entry.lengthMm)) mm",
                kind: .fabricated, quantity: entry.quantity, weightKg: safeWeight,
                amountEUR: amount, priceDescription: priceLabel))
        }

        for part in purchasedParts.sorted(by: { $0.positionNumber < $1.positionNumber }) {
            let quantity = max(1, part.quantity)
            let amount = part.unitPrice.flatMap { price -> Double? in
                guard price.isFinite, price >= 0 else { return nil }
                let result = price * Double(quantity)
                return result.isFinite && result >= 0 ? result : nil
            }
            let priceLabel = part.unitPrice.map { "\(number($0)) € / Stück × \(quantity)" } ?? "Kein Stückpreis hinterlegt"
            lines.append(MaterialCostLine(
                id: part.id, positionNumber: part.positionNumber, name: part.name,
                detail: "Zukaufteil · \(quantity) Stück", kind: .purchased,
                quantity: quantity, weightKg: nil, amountEUR: amount,
                priceDescription: priceLabel, laborHours: part.laborHours))
        }

        lines.sort {
            if $0.positionNumber != $1.positionNumber { return $0.positionNumber < $1.positionNumber }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for index in lines.indices {
            if let hours = laborHoursByPosition[lines[index].id] {
                lines[index].laborHours = hours
            }
        }
        let pricedSum = sum(lines.compactMap(\.amountEUR))
        let laborValues: [(Int, Double)] = lines.enumerated().compactMap { index, line in
            guard let hours = line.laborHours, hours.isFinite, hours >= 0,
                  let safeLaborRate else { return nil }
            let amount = hours * safeLaborRate
            guard amount.isFinite, amount >= 0 else { return nil }
            lines[index].laborEUR = amount
            return (index, amount)
        }
        let laborSum = sum(laborValues.map(\.1))
        let unpricedLaborCount = lines.filter { $0.laborHours.map { $0.isFinite && $0 >= 0 } == true && safeLaborRate == nil }.count
        let cuttingSummary = try? CuttingCostBuilder.estimate(entries: entries, materialPrices: materialPrices,
                                                             stockLengthMm: stockLengthMm, kerfMm: kerfMm)
        let wasteCost = cuttingSummary?.wasteTotalEUR
        let combined = pricedSum.flatMap { materialTotal in
            laborSum.flatMap { laborTotal in
                wasteCost.flatMap { waste in
                    let amount = materialTotal + laborTotal + waste
                    return amount.isFinite && amount >= 0 ? amount : nil
                }
            }
        }
        return MaterialCostEstimate(lines: lines, totalEUR: pricedSum,
                                    pricedPositionCount: lines.filter { $0.amountEUR != nil }.count,
                                    unpricedPositionCount: lines.filter { $0.amountEUR == nil }.count,
                                    laborTotalEUR: laborSum, totalWithLaborEUR: combined,
                                    laborRateEURPerHour: safeLaborRate,
                                    unpricedLaborPositionCount: unpricedLaborCount,
                                    cuttingSummary: cuttingSummary)
    }

    private static func sum(_ values: [Double]) -> Double? {
        var total = 0.0
        for value in values {
            total += value
            if !total.isFinite { return nil }
        }
        return total
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "de_DE")).grouping(.never).precision(.fractionLength(2)))
    }
}
