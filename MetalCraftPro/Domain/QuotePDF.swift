import Foundation
import UIKit

/// Immutable values used to generate the shareable cost-estimate document.
public struct QuotePDFInput: Sendable {
    public var projectName: String
    public var projectNumber: String
    public var revisionLabel: String
    public var projectDescription: String
    public var widthMm: Double
    public var heightMm: Double
    public var profileLabel: String
    public var materialGrade: String
    public var estimate: MaterialCostEstimate
    public var generatedAt: Date

    public init(projectName: String, projectNumber: String, revisionLabel: String,
                projectDescription: String, widthMm: Double, heightMm: Double,
                profileLabel: String, materialGrade: String,
                estimate: MaterialCostEstimate, generatedAt: Date) {
        self.projectName = projectName
        self.projectNumber = projectNumber
        self.revisionLabel = revisionLabel
        self.projectDescription = projectDescription
        self.widthMm = widthMm
        self.heightMm = heightMm
        self.profileLabel = profileLabel
        self.materialGrade = materialGrade
        self.estimate = estimate
        self.generatedAt = generatedAt
    }
}

/// Multi-page, German-language offer estimate rendered locally for sharing and printing.
public enum QuotePDF {
    private static let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    private static let margin: CGFloat = 46
    private static let bottomLimit: CGFloat = 786

    public static func data(for input: QuotePDFInput) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Angebotskalkulation · \(input.projectName)",
            kCGPDFContextCreator as String: "MetalCraft Pro",
            kCGPDFContextAuthor as String: "MetalCraft Pro"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let regular = UIFont.systemFont(ofSize: 10)
        let muted = UIColor(white: 0.36, alpha: 1)
        let ink = UIColor(white: 0.10, alpha: 1)
        let accent = UIColor(red: 0.70, green: 0.40, blue: 0.08, alpha: 1)
        let warning = UIColor(red: 0.62, green: 0.20, blue: 0.08, alpha: 1)
        let currency = NumberFormatter()
        currency.locale = Locale(identifier: "de_DE")
        currency.numberStyle = .currency
        currency.currencyCode = "EUR"
        currency.maximumFractionDigits = 2
        currency.minimumFractionDigits = 2

        func euro(_ amount: Double?) -> String {
            guard let amount, amount.isFinite else { return "Nicht eingepreist" }
            return currency.string(from: NSNumber(value: amount)) ?? "—"
        }
        func attributes(_ font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: color]
        }
        func textHeight(_ value: String, width: CGFloat, font: UIFont) -> CGFloat {
            let rect = (value as NSString).boundingRect(
                with: CGSize(width: max(1, width), height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes(font, color: ink), context: nil)
            return ceil(rect.height)
        }
        func draw(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                  font: UIFont, color: UIColor = ink) -> CGFloat {
            let height = max(font.lineHeight, textHeight(value, width: width, font: font))
            NSAttributedString(string: value, attributes: attributes(font, color: color))
                .draw(in: CGRect(x: x, y: y, width: max(1, width), height: height + 2))
            return height
        }
        func rule(y: CGFloat, color: UIColor = UIColor(white: 0.82, alpha: 1)) {
            color.setStroke()
            let path = UIBezierPath()
            path.lineWidth = 0.65
            path.move(to: CGPoint(x: margin, y: y))
            path.addLine(to: CGPoint(x: pageRect.width - margin, y: y))
            path.stroke()
        }
        func pageHeader(page: Int, first: Bool) -> CGFloat {
            UIColor.white.setFill()
            UIRectFill(pageRect)
            var y = margin
            let eyebrow = draw("METALCRAFT PRO  ·  LOKALE KALKULATION", x: margin, y: y,
                               width: pageRect.width - 2 * margin, font: .systemFont(ofSize: 8, weight: .semibold), color: muted)
            y += eyebrow + 8
            let title = draw("Angebotskalkulation", x: margin, y: y,
                             width: pageRect.width - 2 * margin, font: .systemFont(ofSize: 24, weight: .bold), color: ink)
            y += title + 6
            let projectLine = draw("\(input.projectName)  ·  \(input.projectNumber)", x: margin, y: y,
                                   width: pageRect.width - 2 * margin, font: .systemFont(ofSize: 12, weight: .medium), color: ink)
            y += projectLine + 3
            let dateLine = "Revision \(input.revisionLabel)  ·  Erstellt \(input.generatedAt.formatted(date: .long, time: .shortened))"
            y += draw(dateLine, x: margin, y: y, width: pageRect.width - 2 * margin, font: regular, color: muted) + 12

            if first {
                let details = [
                    ("Projektmaß", "\(number(input.widthMm)) × \(number(input.heightMm)) mm"),
                    ("Profil", input.profileLabel.isEmpty ? "Nicht angegeben" : input.profileLabel),
                    ("Werkstoff", input.materialGrade.isEmpty ? "Nicht angegeben" : input.materialGrade)
                ]
                for (label, value) in details {
                    let labelWidth: CGFloat = 105
                    let rowHeight = max(15, textHeight(value, width: pageRect.width - 2 * margin - labelWidth, font: regular))
                    _ = draw(label, x: margin, y: y, width: labelWidth - 5, font: regular, color: muted)
                    _ = draw(value, x: margin + labelWidth, y: y, width: pageRect.width - 2 * margin - labelWidth,
                             font: .systemFont(ofSize: 10, weight: .medium), color: ink)
                    y += rowHeight + 3
                }
                if !input.projectDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    y += 3
                    y += draw(input.projectDescription, x: margin, y: y,
                              width: pageRect.width - 2 * margin, font: regular, color: muted) + 9
                }
                y += 4
                rule(y: y)
                y += 12
            } else {
                let continuation = draw("Positionen · Fortsetzung · Seite \(page)", x: margin, y: y,
                                        width: pageRect.width - 2 * margin,
                                        font: .systemFont(ofSize: 10, weight: .semibold), color: muted)
                y += continuation + 8
                rule(y: y)
                y += 12
            }
            return y
        }

        return renderer.pdfData { context in
            var page = 1
            context.beginPage()
            var y = pageHeader(page: page, first: true)
            let detailWidth = pageRect.width - 2 * margin - 156
            let amountX = pageRect.width - margin - 148
            let amountWidth: CGFloat = 148

            func beginContinuation() {
                page += 1
                context.beginPage()
                y = pageHeader(page: page, first: false)
            }
            func ensureRoom(_ height: CGFloat) {
                if y + height > bottomLimit { beginContinuation() }
            }
            func drawPosition(_ line: MaterialCostLine) {
                let titleFont = UIFont.systemFont(ofSize: 10.5, weight: .semibold)
                let bodyFont = UIFont.systemFont(ofSize: 9)
                let positionTitle = "Pos. \(line.positionNumber)  ·  \(line.name)"
                let kindText = line.kind == .purchased ? "Zukaufteil" : "Material"
                let descriptiveText = "\(kindText)  ·  \(line.detail)\n\(line.priceDescription)"
                let bodyHeight = textHeight(descriptiveText, width: detailWidth, font: bodyFont)
                let rowHeight = max(42, textHeight(positionTitle, width: detailWidth, font: titleFont) + bodyHeight + 13)
                ensureRoom(rowHeight + 8)
                let amount = line.amountEUR.map(euro) ?? "Offen"
                _ = draw(positionTitle, x: margin, y: y, width: detailWidth, font: titleFont, color: ink)
                _ = draw(amount, x: amountX, y: y + 1, width: amountWidth,
                         font: .systemFont(ofSize: line.amountEUR == nil ? 9 : 10, weight: .semibold),
                         color: line.amountEUR == nil ? warning : ink)
                if line.amountEUR == nil {
                    _ = draw("NICHT EINGEPREIST", x: amountX, y: y + 17, width: amountWidth,
                             font: .systemFont(ofSize: 7, weight: .bold), color: warning)
                }
                let bodyY = y + textHeight(positionTitle, width: detailWidth, font: titleFont) + 3
                _ = draw(descriptiveText, x: margin, y: bodyY, width: detailWidth, font: bodyFont, color: muted)
                y += rowHeight
                rule(y: y)
                y += 8
            }

            let sectionTitle = draw("Kalkulation nach Position", x: margin, y: y,
                                    width: pageRect.width - 2 * margin,
                                    font: .systemFont(ofSize: 14, weight: .semibold), color: ink)
            y += sectionTitle + 9
            if input.estimate.lines.isEmpty {
                y += draw("Keine Material- oder Zukaufteilpositionen im Projekt vorhanden.",
                          x: margin, y: y, width: pageRect.width - 2 * margin,
                          font: regular, color: muted) + 12
            } else {
                for line in input.estimate.lines { drawPosition(line) }
            }

            let summaryHeight: CGFloat = input.estimate.unpricedPositionCount > 0 ? 95 : 78
            ensureRoom(summaryHeight)
            y += 4
            rule(y: y, color: accent)
            y += 12
            let totalTitle = input.estimate.unpricedPositionCount > 0
                ? "Bekannte Zwischensumme · eingepreiste Positionen"
                : "Kalkulierte Gesamtsumme"
            _ = draw(totalTitle, x: margin, y: y, width: pageRect.width - 190,
                     font: .systemFont(ofSize: 11, weight: .semibold), color: ink)
            let totalText = input.estimate.totalEUR.map { euro($0) } ?? "Nicht verfügbar"
            _ = draw(totalText, x: amountX, y: y - 2, width: amountWidth,
                     font: .systemFont(ofSize: 16, weight: .bold), color: accent)
            y += 24

            if input.estimate.unpricedPositionCount > 0 {
                let warningText = "\(input.estimate.unpricedPositionCount) Position(en) sind NICHT EINGEPREIST und in der Zwischensumme nicht enthalten. Die Gesamtsumme ist deshalb unvollständig."
                y += draw(warningText, x: margin, y: y, width: pageRect.width - 2 * margin,
                          font: .systemFont(ofSize: 9, weight: .semibold), color: warning) + 8
            }
            let disclaimer = "Unverbindliche lokale Schätzung ohne Gewähr. Die Summe berücksichtigt ausschließlich Positionen mit hinterlegten Preisen; Steuern, Bearbeitung, Verschnitt und weitere Nebenkosten sind nicht enthalten."
            _ = draw(disclaimer, x: margin, y: y + 3, width: pageRect.width - 2 * margin,
                     font: .systemFont(ofSize: 8), color: muted)
        }
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.locale(Locale(identifier: "de_DE")).grouping(.never).precision(.fractionLength(0...2)))
    }
}
