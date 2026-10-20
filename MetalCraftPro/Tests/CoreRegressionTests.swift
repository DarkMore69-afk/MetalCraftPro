#if DEBUG
import Foundation
import SwiftData
import UIKit
import PDFKit

/// Lightweight debug regression suite with no app-state side effects. Runs against pure
/// functions and a disposable on-disk container. A normal compile does not execute tests;
/// these checks execute when a debug app launches.
@MainActor
enum CoreRegressionTests {
    private enum Failure: Error { case assertion(String) }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }
    private static func close(_ actual: Double, _ expected: Double, _ message: String) throws {
        try expect(actual.isFinite && abs(actual - expected) < 0.000001, message)
    }
    private static func rejects(_ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try expect(rejected, "Invalid input accepted")
    }
    static func run() {
        do {
            try geometry()
            try calculations()
            try profiles()
            try recognition()
            try cad()
            try validation()
            try threeD()
            try assembly()
            try cutList()
            try montage()
            try welding()
            try assistant()
            try exports()
            try photoDocumentation()
            try materialCosts()
            try worksiteSurvey()
            try persistence()
        } catch { assertionFailure("Core regression failed: \(error)") }
    }
    private static func geometry() throws {
        try GeometryElement2D.point(.zero).validate()
        try close(GeometryElement2D.line(start: .zero, end: .init(x: 3, y: 4)).measuredLength(), 5, "Line")
        try close(GeometryElement2D.polyline([.zero, .init(x: 3, y: 0), .init(x: 3, y: 4)]).measuredLength(), 7, "Polyline")
        try close(GeometryElement2D.circle(center: .zero, radius: 10).measuredLength(), 20 * .pi, "Circle")
        try close(GeometryElement2D.arc(center: .zero, radius: 10, startAngleDeg: 350, endAngleDeg: 10).measuredLength(), 10 * .pi / 9, "Wrapped arc")
        try close(GeometryElement2D.rectangle(origin: .zero, width: 1200, height: 800).measuredLength(), 4000, "Rectangle")
        try close(Geometry2D.distance(from: .init(x: 3, y: 4), toSegment: .zero, .init(x: 6, y: 0)), 4, "Distance")
        try close(Geometry2D.angleDegrees(from: .init(x: 1, y: 0), to: .init(x: 0, y: 1)), 90, "Angle")
        try expect(Geometry2D.areParallel(.init(x: 1, y: 0), .init(x: -2, y: 0)), "Parallel")
        try rejects { _ = try Geometry2D.areParallel(.zero, .init(x: 1, y: 0)) }
        try rejects { try GeometryElement2D.polyline([.zero, .zero]).validate() }
        try rejects { try GeometryElement2D.circle(center: .zero, radius: -.infinity).validate() }
        try rejects { try GeometryElement2D.arc(center: .zero, radius: 1, startAngleDeg: 10, endAngleDeg: 10).validate() }
    }
    private static func calculations() throws {
        try close(CalculationEngine.pythagoras(a: 3, b: 4), 5, "Pythagoras")
        try close(CalculationEngine.frameInnerMeasure(outerMm: 1200, profileWidthMm: 40), 1120, "Frame interior")
        try close(CalculationEngine.profileWeight(lengthMm: 1000, profile: ProfileCatalog.squareTube40x40x2), 2.3864, "Tube weight")
        try close(CalculationEngine.plateWeight(lengthMm: 1000, widthMm: 1000, thicknessMm: 2), 15.7, "Plate weight")
        try rejects { _ = try CalculationEngine.pythagoras(a: .nan, b: 1) }
        try rejects { _ = try CalculationEngine.frameInnerMeasure(outerMm: 80, profileWidthMm: 40) }
        try rejects { _ = try CalculationEngine.plateWeight(lengthMm: -1, widthMm: 1, thicknessMm: 1) }
        try rejects { _ = try CalculationEngine.barWeight(lengthMm: 1e308, kgPerMeter: 1e308) }
    }
    private static func profiles() throws {
        let a = ProfileCatalog.standardCatalog(), b = ProfileCatalog.standardCatalog()
        try expect(a.map(\.id) == b.map(\.id), "Stable catalogue UUIDs")
        try expect(Set(a.map(\.type)).count == 11, "All profile types")
        for spec in a { try spec.validate() }
        let flat = a.first { $0.type == .flachstahl && $0.widthMm == 40 }!
        try close(flat.crossSectionAreaMm2, 200, "Flat steel area")
        try close(flat.weightPerMeterKg, 1.57, "Flat steel weight")
        try rejects { try ProfileSpec(type: .rundrohr, name: "invalid", heightMm: 10, widthMm: 10, thicknessMm: 5).validate() }
        let frame = try FrameParameters(width: 1500, height: 800, profile: ProfileCatalog.squareTube40x40x2)
        try close(frame.innerWidth, 1420, "Parametric width")
        try close(frame.length(for: "rahmen_links")!, 720, "Butt-jointed vertical member")
    }
    private static func recognition() throws {
        // Maßtext-Parser: 1200, 1.200, 40x40x2, 45°, Ø10, M10
        try expect(DimensionTextParser.parse("1200") == .lengthMm(1200), "Plain length")
        try expect(DimensionTextParser.parse("1.200") == .lengthMm(1200), "Thousands dot")
        try expect(DimensionTextParser.parse("40x40x2") == .profile(widthMm: 40, heightMm: 40, thicknessMm: 2), "Profile label")
        try expect(DimensionTextParser.parse("40X40X2") == .profile(widthMm: 40, heightMm: 40, thicknessMm: 2), "Profile label uppercase")
        try expect(DimensionTextParser.parse("45°") == .angleDeg(45), "Angle")
        try expect(DimensionTextParser.parse("Ø10") == .diameterMm(10), "Diameter")
        try expect(DimensionTextParser.parse("M10") == .diameterMm(10), "Thread")
        try expect(DimensionTextParser.parse("abc") == nil, "Text is not a measurement")
        try expect(DimensionTextParser.parse("0") == nil, "Zero rejected")
        try expect(DimensionTextParser.parse("999999999") == nil, "Implausible length rejected")

        // Kollineare Segmente werden zusammengeführt.
        let polygon = [RecognizedPoint(x: 0, y: 0), .init(x: 0.2, y: 0), .init(x: 0.5, y: 0), .init(x: 0.5, y: 0.5)]
        let segments = PolylineAnalysis.segments(from: polygon, minLength: 0.05, maxCount: 10)
        try expect(segments.count == 2, "Collinear merge")
        try close(segments.sorted { $0.length > $1.length }[0].length, 0.5, "Merged horizontal segment")

        // Zuordnung: 1200 an die untere Linie, 600 an die linke, Maßstab 1 mm/px.
        let bottom = RecognizedElement(kind: .line, shape: .segment(start: .init(x: 0.2, y: 0.8), end: .init(x: 0.8, y: 0.8)),
                                       anchor: .init(x: 0.5, y: 0.8), confidence: 0.96)
        let left = RecognizedElement(kind: .line, shape: .segment(start: .init(x: 0.2, y: 0.2), end: .init(x: 0.2, y: 0.8)),
                                     anchor: .init(x: 0.2, y: 0.5), confidence: 0.91)
        let n1200 = RecognizedElement(kind: .length, rawText: "1200", valueMm: 1200, anchor: .init(x: 0.5, y: 0.86), confidence: 0.95)
        let n600 = RecognizedElement(kind: .length, rawText: "600", valueMm: 600, anchor: .init(x: 0.14, y: 0.5), confidence: 0.95)
        let linked = SketchGeometryLinker.assign([bottom, left, n1200, n600], imageWidthPx: 2000, imageHeightPx: 1000)
        try expect(linked.mmPerPixel == 1.0, "Scale from assigned numbers")
        let linkedByID = Dictionary(uniqueKeysWithValues: linked.elements.map { ($0.id, $0) })
        try expect(linkedByID[bottom.id]!.assignedID == n1200.id, "Number assigned to nearest line")
        try close(linkedByID[bottom.id]!.valueMm ?? 0, 1200, "Line receives assigned length")
        try close(linkedByID[left.id]!.valueMm ?? 0, 600, "Second line receives its length")
        let names = SketchGeometryLinker.names(for: linked.elements)
        try expect(names[bottom.id] == "Linie unten", "Horizontal line named by position")
        try expect(names[left.id] == "Linie links", "Vertical line named by position")

        // Widersprüchliche Maße auf derselben Linie lösen einen Prüfhinweis aus.
        let n900 = RecognizedElement(kind: .length, rawText: "900", valueMm: 900, anchor: .init(x: 0.52, y: 0.84), confidence: 0.9)
        let conflicted = SketchGeometryLinker.assign([bottom, left, n1200, n600, n900], imageWidthPx: 2000, imageHeightPx: 1000)
        let conflictedByID = Dictionary(uniqueKeysWithValues: conflicted.elements.map { ($0.id, $0) })
        try expect(conflictedByID[n900.id]!.needsReview, "Contradicting measurement flagged")

        // Übernahme: nur validierte Geometrie, y-Spiegelung Bild → Geometrie.
        let adoptedBottom = try SketchAdoption.geometry(for: linkedByID[bottom.id]!, mmPerPixel: 1,
                                                        imageWidthPx: 2000, imageHeightPx: 1000)
        try expect(adoptedBottom == .line(start: .init(x: 400, y: 200), end: .init(x: 1600, y: 200)), "Segment in mm with y flip")
        let hole = RecognizedElement(kind: .circle, shape: .circle(center: .init(x: 0.7, y: 0.5), radius: 0.05),
                                     valueMm: 10, anchor: .init(x: 0.7, y: 0.5), confidence: 0.88, name: "Kreis Ø10")
        let adoptedHole = try SketchAdoption.geometry(for: hole, mmPerPixel: 1, imageWidthPx: 2000, imageHeightPx: 1000)
        try expect(adoptedHole == .circle(center: .init(x: 1400, y: 500), radius: 5), "Hole uses measured diameter")
        try expect(try SketchAdoption.geometry(for: linkedByID[bottom.id]!, mmPerPixel: nil,
                                               imageWidthPx: 2000, imageHeightPx: 1000) == nil, "No scale means no invented geometry")
        let broken = RecognizedElement(kind: .line, shape: .segment(start: .init(x: 0.2, y: 0.8), end: .init(x: 0.2, y: 0.8)),
                                       anchor: .init(x: 0, y: 0), confidence: 0.9, name: "Degeneriert")
        let validation = SketchAdoption.validatedGeometry(elements: [broken], mmPerPixel: 1,
                                                          imageWidthPx: 2000, imageHeightPx: 1000)
        try expect(validation.geometry.isEmpty && validation.rejected.count == 1, "Degenerate geometry is rejected, never saved")
    }

    private static func cad() throws {
        // Fabrik + Validierung + Codier-Rundtrip
        var drawing = CADDrawing()
        let line = CADFactory.line(.zero, .init(x: 100, y: 0))
        let rectangle = CADFactory.rectangle(.zero, .init(x: 100, y: 50))
        let circle = CADFactory.circle(center: .init(x: 50, y: 25), radiusPoint: .init(x: 60, y: 25))
        try drawing.add(line)
        try drawing.add(rectangle)
        try drawing.add(circle)
        let encoded = try JSONEncoder().encode(drawing)
        let decoded = try JSONDecoder().decode(CADDrawing.self, from: encoded)
        try expect(decoded == drawing, "CAD roundtrip")

        // Snap: Endpunkt vor Raster, Raster als Fallback, Ausrichtung beim Zeichnen
        let frame = try FrameParameters(width: 1200, height: 800, profile: ProfileCatalog.squareTube40x40x2)
        let endpointSnap = drawing.snap(raw: .init(x: 98, y: 2), frame: frame, pendingStart: nil,
                                        pxPerMm: 0.3, tolerancePt: 20, gridMm: 50, gridEnabled: true)
        try expect(endpointSnap?.kind == .endpoint && endpointSnap?.point == .init(x: 100, y: 0), "Endpoint snap")
        let gridSnap = drawing.snap(raw: .init(x: 252, y: 152), frame: nil, pendingStart: nil,
                                    pxPerMm: 0.3, tolerancePt: 20, gridMm: 50, gridEnabled: true)
        try expect(gridSnap?.kind == .grid && gridSnap?.point == .init(x: 250, y: 150), "Grid snap")
        try expect(drawing.snap(raw: .init(x: 252, y: 152), frame: nil, pendingStart: nil,
                                pxPerMm: 0.3, tolerancePt: 20, gridMm: 50, gridEnabled: false) == nil, "Grid off means raw point")
        let axisSnap = drawing.snap(raw: .init(x: 300, y: 3), frame: nil, pendingStart: .init(x: 50, y: 0),
                                    pxPerMm: 0.3, tolerancePt: 20, gridMm: 50, gridEnabled: false)
        try expect(axisSnap?.kind == .axis && axisSnap?.point == .init(x: 300, y: 0), "Horizontal alignment constraint")

        // Trim: getippter Anteil wird entfernt
        let cutter = CADFactory.line(.init(x: 50, y: -10), .init(x: 50, y: 10))
        try drawing.add(cutter)
        let trimmed = CADOperations.trim(drawing, targetID: line.id, cutterID: cutter.id, tap: .init(x: 10, y: 0))
        try expect(trimmed?.element(with: line.id) == .init(id: line.id, kind: .line, a: .zero, b: .init(x: 50, y: 0)), "Trim removes tapped portion")
        try expect(CADOperations.trim(drawing, targetID: line.id, cutterID: circle.id, tap: .init(x: 10, y: 0)) == nil, "Trim without intersection is refused")

        // Extend bis zur Grenze
        let short = CADFactory.line(.init(x: 60, y: 5), .init(x: 70, y: 5))
        try drawing.add(short)
        let extended = CADOperations.extend(drawing, targetID: short.id, boundaryID: cutter.id, tap: .init(x: 70, y: 5))
        try expect(extended?.element(with: short.id) == .init(id: short.id, kind: .line, a: .init(x: 60, y: 5), b: .init(x: 50, y: 5)), "Extend reaches boundary")

        // Offset: parallele Kopie in Abstand und Richtung des Tipps
        let offset = CADOperations.offset(drawing, id: line.id, distanceMm: 20, side: .init(x: 30, y: 5))
        let offsetLine = offset?.elements.last
        try expect(offsetLine?.kind == .line, "Offset creates a copy")
        try close(offsetLine?.a.y ?? 0, 20, "Offset distance")
        try close(offsetLine?.b.x ?? 0, 100, "Offset keeps direction")

        // Mirror an der Vertikalen x = 50
        let mirrored = CADOperations.mirror(drawing, ids: [line.id], axisA: .init(x: 50, y: 0), axisB: .init(x: 50, y: 10))
        try expect(mirrored?.elements.count == drawing.elements.count + 1, "Mirror adds one copy")
        try close(mirrored?.elements.last?.a.x ?? 0, 100, "Mirrored start point")

        // Array: drei Kopien im Abstand 100 mm
        let array = CADOperations.linearArray(drawing, ids: [line.id], count: 3, dx: 100, dy: 0)
        try expect(array?.elements.count == drawing.elements.count + 2, "Array adds count-1 copies")
        try close(array?.elements.last?.a.x ?? 0, 200, "Array offset")
        try expect(CADOperations.linearArray(drawing, ids: [line.id], count: 1, dx: 10, dy: 0) == nil, "Array needs at least two")

        // Validated drilling patterns: every hole is a normal CAD hole, and the batch is atomic.
        let linearPattern = CADOperations.drillPattern(CADDrawing(), center: .init(x: 100, y: 200),
                                                       kind: .linear, count: 4, spacingMm: 25,
                                                       pitchCircleDiameterMm: 0, startAngleDeg: 90,
                                                       holeDiameterMm: 8)
        let linearHoles = linearPattern?.elements ?? []
        try expect(linearHoles.count == 4 && linearHoles.allSatisfy { $0.kind == .hole },
                   "Linear pattern creates individually validated holes")
        try close(linearHoles[0].a.x, 100, "Linear pattern starts at the tapped point")
        try close(linearHoles[2].a.y, 250, "Linear pattern uses spacing and start angle")
        try close(linearHoles[0].radius ?? 0, 4, "Pattern keeps the requested hole diameter")

        let circularPattern = CADOperations.drillPattern(CADDrawing(), center: .init(x: 50, y: 60),
                                                         kind: .circular, count: 4, spacingMm: 0,
                                                         pitchCircleDiameterMm: 80, startAngleDeg: 90,
                                                         holeDiameterMm: 10)
        let circularHoles = circularPattern?.elements ?? []
        try expect(circularHoles.count == 4, "Circular pattern fills one full pitch circle")
        try close(circularHoles[0].a.x, 50, "Circular start angle begins at the top")
        try close(circularHoles[0].a.y, 100, "Pitch-circle radius is half its diameter")
        try close(circularHoles[1].a.x, 10, "Circular pattern spaces holes evenly")
        try expect(CADOperations.drillPattern(drawing, center: .zero, kind: .linear, count: 4,
                                              spacingMm: 0, pitchCircleDiameterMm: 0,
                                              startAngleDeg: 0, holeDiameterMm: 8) == nil,
                   "Invalid drilling pattern is rejected as one operation")
        var drillHistory = CADHistory()
        let emptyDrawing = CADDrawing()
        let patternDrawing = linearPattern!
        drillHistory.record(.init(label: "Bohrmuster", drawingBefore: emptyDrawing, drawingAfter: patternDrawing))
        try expect(drillHistory.undo()?.drawingBefore == emptyDrawing && drillHistory.redo()?.drawingAfter == patternDrawing,
                   "Pattern creation participates in the shared undo/redo history")

        // Freies Maß bearbeiten: Endpunkt und zusammenfallende Endpunkte folgen
        var withDimension = CADDrawing()
        try withDimension.add(CADFactory.line(.zero, .init(x: 100, y: 0)))
        let dimension = CADFactory.dimension(from: .zero, to: .init(x: 100, y: 0), linePoint: .init(x: 50, y: 40))
        try withDimension.add(dimension)
        let edit = CADOperations.dimensionEdit(withDimension, dimensionID: dimension.id, newValueMm: 300)
        try expect(edit?.parameterKey == nil, "Free dimension edits geometry")
        try close(edit?.drawing.element(with: dimension.id)?.b.x ?? 0, 300, "Dimension endpoint moved")
        try close(edit?.drawing.elements.first?.b.x ?? 0, 300, "Coincident line endpoint follows")

        // Parametrisches Maß: ändert Projektparameter, niemals eine Kopie
        var parametric = CADDrawing()
        let widthDim = CADFactory.parametricDimension(key: "width", anchor: .init(x: 600, y: -40))
        try parametric.add(widthDim)
        let paramEdit = CADOperations.dimensionEdit(parametric, dimensionID: widthDim.id, newValueMm: 1500)
        try expect(paramEdit?.parameterKey == "width" && paramEdit?.parameterValue == 1500, "Parametric dimension targets the project parameter")
        try expect(paramEdit?.drawing == parametric, "Parametric edit keeps the drawing unchanged")

        // Winkel und Viewport
        let angle = CADFactory.angle(vertex: .zero, first: .init(x: 10, y: 0), second: .init(x: 10, y: 10))
        try close(angle.angleValue() ?? 0, 45, "Angle between legs")
        var viewport = CADViewport(pxPerMm: 1, center: .zero)
        let world = Vec2(x: 120, y: 80)
        let screenPoint = viewport.screenPoint(world, canvas: CGSize(width: 400, height: 300))
        let roundTrip = viewport.worldPoint(screenPoint, canvas: CGSize(width: 400, height: 300))
        try close(roundTrip.x, 120, "Viewport x roundtrip")
        try close(roundTrip.y, 80, "Viewport y roundtrip")
        viewport.zoom(factor: 2, anchor: screenPoint, canvas: CGSize(width: 400, height: 300))
        try close(viewport.worldPoint(screenPoint, canvas: CGSize(width: 400, height: 300)).x, 120, "Zoom keeps anchor stable")
        try expect(CADViewport(pxPerMm: 1.764, center: .zero).scaleLabel() == "1:5", "Standard scale label")

        // Verlauf: Undo stellt vorherigen Stand wieder her, Redo wiederholt
        var history = CADHistory()
        let before = drawing
        var after = drawing
        try after.add(CADFactory.text(.init(x: 10, y: 10), "Prüfstempel"))
        history.record(.init(label: "Text", drawingBefore: before, drawingAfter: after))
        try expect(history.canUndo, "History records change")
        try expect(history.undo()!.drawingBefore == before, "Undo restores previous drawing")
        try expect(history.redo()!.drawingAfter == after, "Redo repeats the change")
        let changed = after
        var further = changed
        try further.add(CADFactory.text(.init(x: 20, y: 20), "Zweite Zeile"))
        history.record(.init(label: "Text", drawingBefore: changed, drawingAfter: further))
        _ = history.undo()
        try expect(history.canRedo, "Redo stack survives")
    }

    private static func validation() throws {
        let profile = ProfileCatalog.squareTube40x40x2
        func part(_ name: String, _ position: Int, length: Double, role: String? = nil, parametric: Bool = false) -> ValidationInput.PartSnapshot {
            .init(id: UUID(), name: name, positionNumber: position, quantity: 1, lengthMm: length, role: role, isParametric: parametric)
        }
        func cut(_ position: Int, length: Double, a: Double = 90, b: Double = 90) -> ValidationInput.CutSnapshot {
            .init(id: UUID(), positionNumber: position, profileName: "40 × 40 × 2", lengthMm: length, angleADeg: a, angleBDeg: b)
        }

        // 1. Sauberes Demo-Rahmenprojekt: 1200 − 40 − 40 = 1120, Diagonale 1442,2
        var input = ValidationInput(widthMm: 1200, heightMm: 800, profile: profile, parts: [
            part("Rahmen oben", 1, length: 1200, role: "rahmen_oben", parametric: true),
            part("Rahmen links", 4, length: 720, role: "rahmen_links", parametric: true)
        ])
        var report = ValidationEngine.run(input)
        try expect(report.isClean, "Clean demo frame passes with no findings")
        try expect(report.checks.contains { $0.id == "inner-width" && $0.passes && abs(($0.expectedMm ?? 0) - 1120) < 1e-9 },
                   "Interior width 1200 − 40 − 40 = 1120")
        try expect(report.checks.contains { $0.id == "inner-height" && $0.passes && abs(($0.expectedMm ?? 0) - 720) < 1e-9 },
                   "Interior height 800 − 40 − 40 = 720")
        try expect(report.checks.contains { $0.id == "diagonal" && abs(($0.expectedMm ?? 0) - 1442.2205) < 0.001 },
                   "Control diagonal of the frame")

        // 2. Widersprüchliches Bauteilmaß: Stelle markiert, erwarteter Wert, Korrektur
        let deviating = part("Rahmen unten", 2, length: 1150, role: "rahmen_unten")
        input.parts.append(deviating)
        report = ValidationEngine.run(input)
        try expect(report.hasErrors, "Conflicting part length is an error")
        guard let conflict = report.issues.first(where: { $0.category == .conflictingDimension }) else {
            throw Failure.assertion("Conflicting dimension issue missing")
        }
        try expect(conflict.fix == .partLength(partID: deviating.id, valueMm: 1200), "Fix proposes the expected length")
        try expect(conflict.reference == "Pos. 2 · Rahmen unten", "Finding is marked with its place")
        try expect(report.checks.contains { !$0.passes && $0.actualMm == 1150 && abs(($0.expectedMm ?? 0) - 1200) < 1e-9 },
                   "Conflicting check row shows expected versus actual")

        // 3. Kollision: Querstrebe länger als der freie Innenraum
        let collision = ValidationEngine.run(ValidationInput(widthMm: 1200, heightMm: 800, profile: profile, parts: [
            part("Querstrebe", 5, length: 1300, role: "querstrebe")
        ]))
        try expect(collision.issues.contains { $0.category == .collidingParts }, "Bar longer than the opening collides")

        // 4. Fehlende Maße, Nullwerte, NaN
        var missing = ValidationInput(widthMm: 0, heightMm: 800, profile: profile)
        try expect(ValidationEngine.run(missing).issues.contains { $0.category == .missingDimension }, "Zero width is a missing dimension")
        missing.widthMm = 1200
        missing.heightMm = .nan
        try expect(ValidationEngine.run(missing).issues.contains { $0.category == .nonFiniteValue }, "NaN never passes silently")

        // 5. Unmögliches oder fehlendes Profil
        let impossible = ProfileSpec(type: .rundrohr, name: "invalid", heightMm: 10, widthMm: 10, thicknessMm: 5)
        try expect(ValidationEngine.run(ValidationInput(widthMm: 1200, heightMm: 800, profile: impossible))
            .issues.contains { $0.category == .impossibleProfile }, "Impossible profile detected")
        try expect(ValidationEngine.run(ValidationInput(widthMm: 1200, heightMm: 800, profile: nil))
            .issues.contains { $0.category == .missingDimension }, "Missing profile detected")

        // 6. Fehlerhafte Schnittwinkel
        var cutInput = ValidationInput(widthMm: 1200, heightMm: 800, profile: profile, cuts: [cut(1, length: 1000, a: 200)])
        try expect(ValidationEngine.run(cutInput).issues.contains { $0.category == .badCutAngle && $0.severity == .error },
                   "Cut angle beyond 180° is an error")
        cutInput.cuts = [cut(1, length: 1000, a: .nan)]
        try expect(ValidationEngine.run(cutInput).issues.contains { $0.category == .badCutAngle && $0.severity == .error },
                   "NaN cut angle is an error")
        cutInput.cuts = [cut(1, length: 1000, a: 0)]
        let warningOnly = ValidationEngine.run(cutInput)
        try expect(!warningOnly.hasErrors && warningOnly.warningCount >= 1, "Degenerate cut angle warns without blocking")

        // 7. Ungültige Geometrie: gespeicherte Einträge und CAD-Elemente
        let invalidPayload = try JSONEncoder().encode(GeometryElement2D.circle(center: .zero, radius: -1))
        let recordID = UUID()
        let geometryReport = ValidationEngine.run(ValidationInput(
            widthMm: 1200, heightMm: 800, profile: profile,
            geometryRecords: [.init(id: recordID, label: "Skizze · Linie unten", payload: invalidPayload)],
            cadElements: [CADFactory.line(.zero, .zero)]))
        try expect(geometryReport.issues.filter { $0.category == .invalidGeometry }.count == 2,
                   "Stored and CAD geometry are both validated")
        try expect(geometryReport.issues.contains { $0.fix == .removeGeometryRecord(recordID: recordID) },
                   "Invalid stored record offers removal")
        try expect(geometryReport.issues.contains { issue in
            if case .removeCADElement = issue.fix { return issue.reference == "2D-CAD" }
            return false
        }, "Invalid CAD element offers removal")

        // 8. Nicht verbundene Baugruppen
        let unknown = UUID()
        let assembly = ValidationInput.AssemblySnapshot(id: UUID(), name: "Gartentor", partIDs: [unknown],
                                                        parentAssemblyID: UUID(), stepPartIDs: [])
        try expect(ValidationEngine.run(ValidationInput(widthMm: 1200, heightMm: 800, profile: profile, assemblies: [assembly]))
            .issues.contains { $0.category == .disconnectedAssembly && $0.severity == .error },
            "Dangling assembly references are errors")
        let emptyAssembly = ValidationInput.AssemblySnapshot(id: UUID(), name: "Leer", partIDs: [], parentAssemblyID: nil, stepPartIDs: [])
        let emptyReport = ValidationEngine.run(ValidationInput(widthMm: 1200, heightMm: 800, profile: profile, assemblies: [emptyAssembly]))
        try expect(!emptyReport.hasErrors && emptyReport.warningCount >= 1, "Empty assembly warns without blocking")

        // 9. Fehler erscheinen vor Warnungen
        let mixed = ValidationEngine.run(ValidationInput(widthMm: 0, heightMm: 800, profile: profile, assemblies: [emptyAssembly]))
        try expect(mixed.issues.first?.severity == .error, "Errors are listed before warnings")
    }

    private static func threeD() throws {
        let profile = ProfileCatalog.squareTube40x40x2
        func sectionBox(_ loop: [Vec2]) -> (min: Vec2, max: Vec2) {
            var low = Vec2(x: .infinity, y: .infinity), high = Vec2(x: -.infinity, y: -.infinity)
            for point in loop {
                low = Vec2(x: min(low.x, point.x), y: min(low.y, point.y))
                high = Vec2(x: max(high.x, point.x), y: max(high.y, point.y))
            }
            return (low, high)
        }

        // 1. Profilquerschnitte: Vierkantrohr mit Bohrung, Rundstahl, Fase
        let tube = try ProfileSection.crossSection(for: profile)
        try expect(tube.holes.count == 1, "Square tube has one bore")
        let outerBox = sectionBox(tube.outer)
        try close(outerBox.max.x - outerBox.min.x, 40, "Outer section spans the profile width")
        try close(outerBox.max.y - outerBox.min.y, 40, "Outer section spans the profile height")
        let boreBox = sectionBox(tube.holes[0])
        try close(boreBox.max.x - boreBox.min.x, 36, "Bore is the inner contour")
        try expect(ProfileSection.signedArea(tube.outer) > 0 && ProfileSection.signedArea(tube.holes[0]) < 0,
                   "Outer loop CCW, bore CW")
        let barSpec = ProfileCatalog.spec(named: "Ø12")!
        let bar = try ProfileSection.crossSection(for: barSpec)
        try expect(bar.holes.isEmpty, "Round bar has no bore")
        try close(sectionBox(bar.outer).max.x - sectionBox(bar.outer).min.x, 12, "Round bar diameter")
        let chamfered = try ProfileSection.chamferedCrossSection(for: profile)
        try expect(chamfered.outer.count > tube.outer.count, "Chamfer adds corner points")

        // 2. Extrusion entlang der Kontur, stumpfe Enden
        let mesh = try MeshBuilder.sweep(section: tube,
                                         spec: SweepSpec(start: .zero, end: Vec3(x: 100, y: 0, z: 0), up: Vec3(x: 0, y: 1, z: 0)))
        try expect(mesh.isConsistent && mesh.triangleCount > 0, "Sweep yields a consistent mesh")
        let box = mesh.boundingBox()!
        try close(box.min.x, 0, "Sweep starts at the path")
        try close(box.max.x, 100, "Sweep ends at the path")
        try close(box.min.y, -20, "Profile extends below the axis")
        try close(box.max.y, 20, "Profile extends above the axis")

        // 3. Gehrung 45° am Ende: die äußere Ecke reicht über das Pfadende hinaus
        let miter = try MeshBuilder.sweep(section: tube,
                                          spec: SweepSpec(start: .zero, end: Vec3(x: 100, y: 0, z: 0), up: Vec3(x: 0, y: 1, z: 0), endCutDeg: 45))
        try expect(miter.isConsistent && miter.boundingBox()!.max.x > 119.9, "45° miter extends the outer corner")

        // 4. Platzierungen ausschließlich aus den Projektparametern
        func partInput(_ name: String, _ position: Int, role: String, quantity: Int = 1, spec: ProfileSpec) -> ThreeDPartInput {
            .init(id: UUID(), name: name, positionNumber: position, quantity: quantity, role: role, profile: spec)
        }
        let input = ThreeDInput(widthMm: 1200, heightMm: 800, profile: profile, parts: [
            partInput("Rahmen oben", 1, role: "rahmen_oben", spec: profile),
            partInput("Rahmen unten", 2, role: "rahmen_unten", spec: profile),
            partInput("Rahmen links", 3, role: "rahmen_links", spec: profile),
            partInput("Rahmen rechts", 4, role: "rahmen_rechts", spec: profile),
            partInput("Querstrebe", 5, role: "strebe", quantity: 6, spec: barSpec)
        ])
        let instances = try ThreeDModelBuilder.placements(for: input)
        try expect(instances.count == 10, "Four frame members plus six bars")
        let top = instances.first { $0.name == "Rahmen oben" }!
        try close(top.lengthMm, 1200, "Top rail spans the full width")
        var drilledDrawing = CADDrawing()
        try drilledDrawing.add(CADFactory.hole(center: .init(x: 300, y: 780), radiusPoint: .init(x: 305, y: 780)))
        try drilledDrawing.add(CADFactory.hole(center: .init(x: 700, y: 780), radiusPoint: .init(x: 705, y: 780)))
        let projectedDrills = ThreeDModelBuilder.drillMarkers(drawing: drilledDrawing, for: input)
        try expect(projectedDrills.count == 2 && projectedDrills.allSatisfy { $0.partID == top.partID },
                   "CAD drillings map onto the matching 3D profile")
        try close(projectedDrills[0].center.z, 20.2, "Drilling appears on the visible outer face")
        let drillCuts = ThreeDModelBuilder.drillingCuts(drawing: drilledDrawing, for: input)
        try expect(drillCuts.count == 2 && drillCuts.allSatisfy { $0.partID == top.partID && $0.machining.contains("Bohrung Ø10") },
                   "Mapped holes flow into the position-specific cut machining")
        let left = instances.first { $0.name == "Rahmen links" }!
        try close(left.lengthMm, 720, "Side members fit between the rails")
        let barX = instances.filter { $0.name == "Querstrebe" }.map { $0.start.x }.sorted()
        try close(barX.first ?? 0, 200, "First bar evenly spread")
        try close(barX.last ?? 0, 1000, "Last bar evenly spread")

        // 5. Bauen, Union, Determinismus
        let built = try ThreeDModelBuilder.build(instances)
        try expect(built.count == 10 && built.allSatisfy { !$0.mesh.isEmpty && $0.mesh.isConsistent },
                   "Every instance builds a consistent mesh")
        let union = Mesh3D.union(built.map(\.mesh))
        try expect(union.isConsistent && union.triangleCount == built.reduce(0) { $0 + $1.mesh.triangleCount },
                   "Union merges meshes losslessly")
        let again = try ThreeDModelBuilder.build(try ThreeDModelBuilder.placements(for: input))
        try expect(again == built, "Rebuilding the same input is deterministic")

        // 6. Ungültige Eingaben werden nie still geschluckt
        try rejects { _ = try ThreeDModelBuilder.placements(for: ThreeDInput(widthMm: 0, heightMm: 800, profile: profile, parts: [])) }
        try rejects { _ = try MeshBuilder.sweep(section: tube, spec: SweepSpec(start: .zero, end: .zero, up: Vec3(x: 0, y: 1, z: 0))) }
    }

    private static func assembly() throws {
        let profile = ProfileCatalog.squareTube40x40x2
        func part(_ name: String, _ pos: Int, role: String? = nil, quantity: Int = 1,
                  length: Double? = nil) -> AssemblyPartSnapshot {
            .init(id: UUID(), name: name, positionNumber: pos, quantity: quantity, role: role,
                  profileName: role == "hardware" ? nil : "40 × 40 × 2", lengthMm: role == "hardware" ? nil : length)
        }
        let p1 = part("Rahmen oben", 1, role: "rahmen_oben", length: 1200)
        let p2 = part("Rahmen unten", 2, role: "rahmen_unten", length: 1200)
        let p3 = part("Rahmen links", 3, role: "rahmen_links", length: 720)
        let p4 = part("Rahmen rechts", 4, role: "rahmen_rechts", length: 720)
        let bars = part("Querstrebe", 5, role: "strebe", quantity: 6, length: 720)
        let hinge1 = part("Scharnier 1", 6, role: "hardware")
        let hinge2 = part("Scharnier 2", 7, role: "hardware")
        let lock = part("Schloss", 8, role: "hardware")

        let gate = AssemblySnapshot(id: UUID(), name: "Gartentor", positionNumber: 1, quantity: 1,
                                    parentAssemblyID: nil, partIDs: [bars.id, hinge1.id, hinge2.id, lock.id],
                                    childAssemblyIDs: [UUID()])
        let frame = AssemblySnapshot(id: UUID(), name: "Rahmen", positionNumber: 1, quantity: 1,
                                     parentAssemblyID: gate.id, partIDs: [p1.id, p2.id, p3.id, p4.id],
                                     childAssemblyIDs: [])
        var input = AssemblyTreeInput(parts: [p1, p2, p3, p4, bars, hinge1, hinge2, lock],
                                      assemblies: [gate, frame])
        input.assemblies[0].childAssemblyIDs = [frame.id]

        // 1. Hierarchie mit Ebenen, Position, Stückzahl und Ursprung
        let tree = AssemblyTreeBuilder.build(input)
        try expect(tree.count == 1 && tree[0].name == "Gartentor" && tree[0].kind == .assembly,
                   "Exactly one root assembly")
        try expect(tree[0].children.count == 5, "Subassembly plus four direct parts")
        try expect(tree[0].children[0].name == "Rahmen" && tree[0].children[0].children.count == 4,
                   "Frame subassembly holds positions 1–4")
        try expect(tree[0].children[1].positionNumber == 5 && tree[0].children[1].kind == .ownPart,
                   "Bars are an own fabricated part")
        try expect(tree[0].children[2].kind == .referencePart && tree[0].children[2].name == "Scharnier 1",
                   "Hardware nodes are references")
        try expect(tree[0].children[1].quantity == 6 && tree[0].children[1].lengthMm == 720,
                   "Quantity and derived length come from the part")

        // 2. Stückliste mit Mengenmultiplikation
        let bom = AssemblyTreeBuilder.billOfMaterials(tree)
        try expect(bom.count == 8, "All eight positions appear in the bill of materials")
        try expect(bom.first { $0.name == "Scharnier 1" }?.isReference == true, "Hardware flagged as reference")
        try expect(abs((bom.first { $0.name == "Querstrebe" }?.unitLengthMm ?? 0) - 720) < 1e-9,
                   "Bar length derived from the inner height")

        // 3. Maßänderung: Baum und Stückliste folgen dem Parameter
        var widerParts = input.parts
        widerParts[0].lengthMm = 1500
        let wider = AssemblyTreeBuilder.build(AssemblyTreeInput(parts: widerParts, assemblies: input.assemblies))
        try expect(abs((wider[0].children[0].children[0].lengthMm ?? 0) - 1500) < 1e-9,
                   "Tree length follows the parameter")
        try expect(abs((AssemblyTreeBuilder.billOfMaterials(wider).first { $0.name == "Rahmen oben" }?
            .unitLengthMm ?? 0) - 1500) < 1e-9, "Bill of materials follows the parameter")

        // 4. Stückzahlen multiplizieren sich über Ebenen
        var doubled = input
        doubled.assemblies[0].quantity = 2
        let doubledBOM = AssemblyTreeBuilder.billOfMaterials(AssemblyTreeBuilder.build(doubled))
        try expect(doubledBOM.first { $0.name == "Rahmen oben" }?.totalQuantity == 2,
                   "Quantities multiply through the hierarchy")

        // 5. Reihenfolge folgt dem Baum
        var reordered = input
        reordered.assemblies[1].partIDs = [p4.id, p3.id, p2.id, p1.id]
        let reorderedTree = AssemblyTreeBuilder.build(reordered)
        try expect(reorderedTree[0].children[0].children.map(\.name) ==
                   ["Rahmen rechts", "Rahmen links", "Rahmen unten", "Rahmen oben"],
                   "Drag order is respected in the tree")

        // 6. Nicht zugeordnete Bauteile bleiben sichtbar
        var loose = input
        loose.parts.append(part("Reststück", 9, length: 300))
        try expect(AssemblyTreeBuilder.build(loose).count == 2, "Unplaced parts stay visible at the root")

        // 7. Zirkuläre Hierarchie bricht den Baum nicht, wird aber gemeldet
        let cycleA = AssemblySnapshot(id: UUID(), name: "A", positionNumber: 1, quantity: 1,
                                      parentAssemblyID: nil, partIDs: [], childAssemblyIDs: [])
        let cycleB = AssemblySnapshot(id: UUID(), name: "B", positionNumber: 1, quantity: 1,
                                      parentAssemblyID: cycleA.id, partIDs: [], childAssemblyIDs: [cycleA.id])
        var cycleInput = ValidationInput(widthMm: 1200, heightMm: 800, profile: profile, parts: [
            .init(id: hinge1.id, name: "Scharnier 1", positionNumber: 6, quantity: 1,
                  lengthMm: 0, role: "hardware", isParametric: false)
        ], assemblies: [
            .init(id: cycleA.id, name: "A", partIDs: [], childAssemblyIDs: [cycleB.id],
                  parentAssemblyID: nil, stepPartIDs: []),
            .init(id: cycleB.id, name: "B", partIDs: [hinge1.id], childAssemblyIDs: [cycleA.id],
                  parentAssemblyID: cycleA.id, stepPartIDs: [])
        ])
        let cycleReport = ValidationEngine.run(cycleInput)
        try expect(cycleReport.issues.contains { $0.category == .disconnectedAssembly && $0.severity == .error },
                   "Circular hierarchy is reported")

        // 8. Referenzbauteile ohne Länge sind kein Fehler; leere Unterbaugruppe bleibt Warnung
        cycleInput.assemblies = [
            .init(id: cycleA.id, name: "Gartentor", partIDs: [hinge1.id], childAssemblyIDs: [cycleB.id],
                  parentAssemblyID: nil, stepPartIDs: []),
            .init(id: cycleB.id, name: "Rahmen", partIDs: [], childAssemblyIDs: [],
                  parentAssemblyID: cycleA.id, stepPartIDs: [])
        ]
        let cleanReport = ValidationEngine.run(cycleInput)
        try expect(!cleanReport.issues.contains { $0.category == .missingDimension },
                   "Reference parts without length are fine")
        try expect(!cleanReport.issues.contains { $0.category == .disconnectedAssembly && $0.severity == .warning },
                   "Subassembly-only parents are not empty")
    }

    private static func cutList() throws {
        let tube = ProfileCatalog.squareTube40x40x2
        let flat = ProfileCatalog.spec(named: "40 × 5")!

        // 1. Liste aus dem Modell: Position, Profil, Stück, Winkel, Bearbeitung
        let rail = CutListPartInput(id: UUID(), name: "Rahmen oben", positionNumber: 1, quantity: 2,
                                    lengthMm: 1120, profile: tube, isReference: false, remark: "")
        let drilled = CutListPartInput(id: UUID(), name: "Rahmen links", positionNumber: 3, quantity: 1,
                                       lengthMm: 752, profile: tube, isReference: false, remark: "")
        let flatPart = CutListPartInput(id: UUID(), name: "Fußleiste", positionNumber: 4, quantity: 1,
                                        lengthMm: 1180, profile: flat, isReference: false, remark: "")
        let hinge = CutListPartInput(id: UUID(), name: "Scharnier", positionNumber: 6, quantity: 2,
                                     lengthMm: 0, profile: nil, isReference: true, remark: "")
        let cuts = [CutListCutInput(partID: drilled.id, angleADeg: 45, angleBDeg: 45,
                                    machining: "Bohrung Ø10", remark: ""),
                    CutListCutInput(partID: drilled.id, angleADeg: 90, angleBDeg: 90,
                                    machining: "Bohrung Ø8 · X 300 Y 400 mm", remark: "")]
        let entries = CutListBuilder.entries(materialGrade: "S235", parts: [rail, drilled, flatPart, hinge], cuts: cuts)
        try expect(entries.count == 3, "Reference parts without profile are never cut")
        try expect(entries.map(\.positionNumber) == [1, 3, 4], "Entries follow the position numbers")
        try expect(entries[1].angleADeg == 45 && entries[1].machiningNotes == ["Bohrung Ø10", "Bohrung Ø8 · X 300 Y 400 mm"],
                   "Multiple hole patterns and cut item angles flow into the machining list")
        try expect(entries[0].angleLabel == "90° / 90°", "Parts without a cut item are square by default")
        try expect(entries[2].displayLabel == "Flachstahl 40 × 5", "Flat steel keeps its type label")
        try expect(entries[0].materialGrade == "S235", "Material grade travels with the entry")
        try close(entries[0].pieceWeightKg, CalculationEngine.profileWeight(lengthMm: 1120, profile: tube),
                  "Piece weight comes from the profile engine")
        let remarks = CutListBuilder.remarks(for: entries)
        try expect(remarks.map(\.text) == ["Bohrung Ø10 an Pos 3"], "Remarks aggregate per position")
        let summary = CutListBuilder.summary(entries: entries)
        try expect(summary.pieceCount == 4, "Quantities are summed")

        // 2. Optimierer: Verschnitt, Reststücke, Alternativen, deterministisch
        func job(_ lengths: [Double], stock: Double = 6000) -> CuttingJob {
            .init(pieces: lengths.enumerated().map { index, length in
                CuttingPiece(id: "\(index)", entryID: UUID(), positionNumber: index + 1,
                             lengthMm: length, profileLabel: "40 × 40 × 2")
            }, stockLengthMm: stock)
        }
        let demo = try CuttingOptimizer.plans(for: job([1120, 1120, 760, 760]))
        try expect(demo.count == CuttingOptimizer.strategies.count, "One plan per strategy")
        let best = demo[0]
        try expect(best.barCount == 1, "3772 mm of pieces fit on a single 6000 mm bar")
        try close(best.bars[0].offcutMm, 6000 - (1120 * 2 + 760 * 2 + 3 * 4), "The remainder above the limit is an offcut")
        try close(best.totalWasteMm, 0, "A usable remainder produces no waste")
        try expect(best.sequenceDescription.contains("1120"), "The cutting order lists the piece lengths")

        let scrapEntries = CutListBuilder.entries(materialGrade: "S235", parts: [
            CutListPartInput(id: UUID(), name: "Langprofil", positionNumber: 10, quantity: 1,
                             lengthMm: 3900, profile: tube, isReference: false, remark: ""),
            CutListPartInput(id: UUID(), name: "Mittelprofil", positionNumber: 11, quantity: 1,
                             lengthMm: 2000, profile: tube, isReference: false, remark: ""),
            CutListPartInput(id: UUID(), name: "Einzelprofil", positionNumber: 12, quantity: 1,
                             lengthMm: 5900, profile: tube, isReference: false, remark: ""),
            CutListPartInput(id: UUID(), name: "Kurzprofil", positionNumber: 13, quantity: 1,
                             lengthMm: 1000, profile: tube, isReference: false, remark: "")
        ], cuts: [])
        let scrap = try CuttingCostBuilder.estimate(entries: scrapEntries,
                                                      materialPrices: [MaterialPriceInput(grade: "S235", pricePerKg: 5)],
                                                      stockLengthMm: 6000, kerfMm: 3)
        guard let tubeCost = scrap.profiles.first else { throw Failure.assertion("Profile cutting cost exists") }
        try expect(tubeCost.stockBarCount == 3, "Cut estimate reports required stock bars")
        try expect(tubeCost.reusableOffcutsMm.count == 1, "Cut estimate identifies reusable remnants")
        try close(tubeCost.reusableOffcutsMm[0], 4997, "Cut kerf is applied to reusable remnant")
        try close(tubeCost.wasteMm, 191, "Only unusable tails count as scrap")
        try close(tubeCost.stockPurchaseEUR ?? 0, 214.776, "Stock purchase value uses full profile weight and kg price")
        try close(tubeCost.wasteCostEUR ?? 0, 2.279012, "Scrap cost uses scrap mass and the available grade price")
        try close(scrap.wasteTotalEUR ?? 0, 2.279012, "Scrap costs aggregate across profiles")

        let missingScrapPrice = try CuttingCostBuilder.estimate(entries: scrapEntries,
                                                                 materialPrices: [], stockLengthMm: 6000,
                                                                 kerfMm: 3)
        try expect(missingScrapPrice.unpricedProfileCount == 1
                   && missingScrapPrice.profiles[0].wasteCostEUR == nil,
                   "No scrap estimate is invented without a matching material price")
        let impossibleCut = CutListBuilder.entries(materialGrade: "S235", parts: [
            CutListPartInput(id: UUID(), name: "Zu lang", positionNumber: 14, quantity: 1,
                             lengthMm: 7000, profile: tube, isReference: false, remark: "")
        ], cuts: [])
        let flagged = try CuttingCostBuilder.estimate(entries: impossibleCut,
                                                       materialPrices: [MaterialPriceInput(grade: "S235", pricePerKg: 5)],
                                                       stockLengthMm: 6000, kerfMm: 3)
        try expect(flagged.profiles[0].overlongPieceCount == 1 && flagged.profiles[0].stockBarCount == 0,
                   "Pieces longer than stock are reported rather than assigned a false bar")
        try rejects { _ = try CuttingCostBuilder.estimate(entries: scrapEntries, materialPrices: [], stockLengthMm: 0, kerfMm: 3) }

        let kerfCase = try CuttingOptimizer.plans(for: job([2999, 2999]))
        try expect(kerfCase[0].barCount == 2, "Kerf width is part of the packing")
        let mixed = try CuttingOptimizer.plans(for: job([2500, 2500, 2000, 1500, 1500]))
        try expect(mixed.map(\.totalWasteMm) == mixed.map(\.totalWasteMm).sorted(), "Alternatives are ranked by waste")
        let repeatRun = try CuttingOptimizer.plans(for: job([2500, 2500, 2000, 1500, 1500]))
        try expect(mixed == repeatRun, "The optimiser is deterministic")
        let overlong = try CuttingOptimizer.plans(for: job([7000]))
        try expect(overlong[0].bars.isEmpty && overlong[0].overlongPieces.count == 1, "Overlong pieces are flagged")
        let multi = try CuttingOptimizer.plans(for: CuttingJob(pieces: [
            CuttingPiece(id: "a", entryID: UUID(), positionNumber: 1, lengthMm: 1120, profileLabel: "40 × 40 × 2"),
            CuttingPiece(id: "b", entryID: UUID(), positionNumber: 2, lengthMm: 1180, profileLabel: "Flachstahl 40 × 5")
        ], stockLengthMm: 6000))
        try expect(multi[0].barCount == 2, "Different profiles never share a bar")
        try rejects { _ = try CuttingOptimizer.plans(for: CuttingJob(pieces: [], stockLengthMm: 0)) }

        // 3. CSV-Export mit Semikolon und Dezimalkomma
        let csv = CutListCSV.export(entries: entries, plan: best, stockLengthMm: 6000)
        try expect(csv.hasPrefix("Pos;Bezeichnung"), "CSV header row")
        try expect(csv.contains("1120;2;90"), "CSV row carries length, quantity and angle")
        try expect(csv.contains("Bohrung Ø10"), "Machining is exported")
        try expect(csv.contains("Schnittplan"), "The cutting plan is exported")
        try expect(csv.contains("Reststück"), "Offcuts are exported")
    }

    /// Montage-Builder: deterministische Abfolge aus der Baugruppe plus Toleranzbewertung.
    private static func montage() throws {
        func part(_ name: String, _ pos: Int, role: String?, quantity: Int = 1, length: Double = 0) -> SequencePart {
            .init(id: UUID(), name: name, positionNumber: pos, quantity: quantity, role: role,
                  profileName: "40 × 40 × 2", lengthMm: length)
        }
        let base = part("Rahmen unten", 1, role: "rahmen_unten", length: 1200)
        let left = part("Rahmen links", 2, role: "rahmen_links", length: 720)
        let right = part("Rahmen rechts", 3, role: "rahmen_rechts", length: 720)
        let bars = part("Querstrebe", 4, role: "strebe", quantity: 6, length: 720)
        let top = part("Rahmen oben", 5, role: "rahmen_oben", length: 1200)
        let hinge1 = part("Scharnier 1", 6, role: "hardware")
        let hinge2 = part("Scharnier 2", 7, role: "hardware")
        let lock = part("Schloss", 8, role: "hardware")
        let parts = [top, bars, hinge1, base, lock, left, hinge2, right]

        let steps = AssemblySequenceBuilder.blueprints(widthMm: 1200, heightMm: 800, parts: parts)
        try expect(steps.count == 7, "Base, sides, bars, closure and hardware form the sequence")
        try expect(steps[0].title == "Rahmen unten einsetzen", "The base rail sets the reference edge")
        try expect(steps[1].title == "Seitenprofile einsetzen", "Side members share one step")
        try expect(steps[2].title == "Querstreben einsetzen", "Bars share one step")
        try expect(steps[3].title == "Rahmen oben einsetzen", "The top rail closes the frame")
        try expect(steps[0].movement == "ansetzen", "Frame members are welded in place")
        try expect(steps.dropFirst(4).allSatisfy { $0.movement == "montieren" }, "Hardware is mounted, not welded")
        try expect(steps.dropFirst(4).allSatisfy { $0.connection.contains("Verschrauben") }, "Hardware connection is bolted")
        try expect(steps[3].partIDs.contains(top.id), "The closing step contains the top rail")
        try expect(steps[2].partIDs.contains(bars.id), "The bar step contains the bars")

        let diagonal = (1200.0 * 1200.0 + 800.0 * 800.0).squareRoot()
        try expect(steps[3].check?.title == "Diagonalen prüfen", "The closing step carries the diagonal check")
        try close(steps[3].check?.targetMm ?? -1, diagonal, "Diagonal target from the frame dimensions")
        try close(steps[3].check?.toleranceMm ?? -1, 1.0, "Default tolerance is ±1 mm")
        try expect(steps[2].check?.title == "Länge prüfen", "Weld steps check their length")
        try expect(AssemblySequenceBuilder.positionNote(for: "strebe", quantity: 6, heightMm: 800).contains("6"),
                   "The position note reflects the quantity")
        let repeatRun = AssemblySequenceBuilder.blueprints(widthMm: 1200, heightMm: 800, parts: parts)
        try expect(steps.map(\.title) == repeatRun.map(\.title) && steps.map(\.partIDs) == repeatRun.map(\.partIDs),
                   "The sequence is deterministic")

        // Toleranzbewertung: kein stiller Ausgleich, keine NaN-Werte durchgelassen.
        let within = AssemblySequenceBuilder.evaluate(measuredMm: diagonal + 0.9, targetMm: diagonal, toleranceMm: 1.0)
        try expect(within.withinTolerance && abs(within.deviationMm - 0.9) < 1e-9, "Measurement within tolerance passes")
        let outside = AssemblySequenceBuilder.evaluate(measuredMm: diagonal - 2.0, targetMm: diagonal, toleranceMm: 1.0)
        try expect(!outside.withinTolerance && abs(outside.deviationMm - 2.0) < 1e-9, "Deviation outside tolerance fails")
        let invalid = AssemblySequenceBuilder.evaluate(measuredMm: .infinity, targetMm: diagonal, toleranceMm: 1.0)
        try expect(!invalid.withinTolerance, "NaN and infinity never pass a check")

        try expect(AssemblySequenceBuilder.blueprints(widthMm: 1200, heightMm: 800, parts: []).isEmpty,
                   "Without parts there is no sequence")
    }

    /// Schweißmodul: Nahtdaten, Protokoll je Bauteil und Projekt, PDF.
    private static func welding() throws {
        func record(_ label: String, method: String = "wig", feed: Double = 0, partID: UUID? = nil) -> WeldRecord {
            .init(label: label, method: method, material: "S235", thicknessMm: 2,
                  filler: "WIG Ø2,4 · ER70S-6", gas: "Argon 4.6 · 10 l/min", currentA: 95,
                  voltageV: 12.5, wireFeedMMin: feed, position: "PA (flach)",
                  seamType: "Kehlnaht a3", sequence: "1 → 2 → 3", partID: partID)
        }
        let bar = WeldPartInput(id: UUID(), name: "Querstrebe", positionNumber: 3)
        let rail = WeldPartInput(id: UUID(), name: "Rahmen oben", positionNumber: 1)
        let w1 = record("Rahmen links unten", partID: bar.id)
        let w2 = record("Querstrebe Mitte", partID: bar.id)
        let w3 = record("Rahmen rechts unten", partID: bar.id)
        let railWeld = record("Stoß oben", method: "mig", feed: 4.5, partID: rail.id)

        // 1. Protokoll je Bauteil: nach Position sortiert, Reihenfolge im Bauteil bleibt
        let entries = WeldProtocolBuilder.entries(parts: [bar, rail], welds: [w3, w1, railWeld, w2])
        try expect(entries.count == 2, "Two parts carry welds")
        try expect(entries[0].partLabel == "Pos 1 · Rahmen oben", "Entries follow the position numbers")
        try expect(entries[1].partLabel == "Pos 3 · Querstrebe", "Part label carries position and name")
        try expect(entries[1].records.map(\.label) == ["Rahmen links unten", "Querstrebe Mitte", "Rahmen rechts unten"],
                   "Seam order inside a part is preserved")
        try expect(entries[0].records[0].methodLabel == "MIG/MAG", "MIG/MAG label")
        try expect(entries[1].records[0].methodLabel == "WIG", "WIG label")
        try expect(entries[0].records[0].wireFeedLabel == "4,5 m/min", "MIG shows the wire feed")
        try expect(entries[1].records[0].wireFeedLabel == "–", "WIG without wire feed shows a dash")
        try expect(entries[1].records[0].currentLabel == "95 A", "Current is formatted in amps")

        // 2. Dokumentationsgrad: jeder Parameter gesetzt, sonst kein Haken
        try expect(w2.isDocumented, "A complete weld is documented")
        var incomplete = w2
        incomplete.gas = ""
        try expect(!incomplete.isDocumented, "A missing gas value leaves the weld undocumented")
        var noFeed = w2
        noFeed.method = "ehand"
        try expect(noFeed.isDocumented, "The dash stands for a valid empty wire feed")
        let summary = WeldProtocolBuilder.summary(entries: entries)
        try expect(summary.seams == 4, "All seams are counted")
        try expect(summary.documented == 4, "Complete welds are counted as documented")

        // 3. Nähte ohne Bauteilzuordnung bleiben sichtbar
        let orphanEntries = WeldProtocolBuilder.entries(parts: [bar], welds: [record("Restnaht", partID: UUID())])
        try expect(orphanEntries.count == 1 && orphanEntries[0].partLabel == "Ohne Bauteilzuordnung",
                   "Unassigned welds stay visible in the protocol")
        try expect(WeldProtocolBuilder.entries(parts: [bar], welds: []).isEmpty, "No welds, no entries")

        // 4. PDF je Bauteil und Projekt
        let pdf = WeldProtocolPDF.data(entries: entries, projectName: "Gartentor", projectNumber: "2026-001",
                                       materialGrade: "S235", generatedAt: Date(timeIntervalSince1970: 0))
        try expect(pdf.count > 1000, "The PDF carries content")
        try expect(String(data: pdf.prefix(5), encoding: .ascii)?.hasPrefix("%PDF") == true, "PDF header")
        let emptyPDF = WeldProtocolPDF.data(entries: [], projectName: "Leer", projectNumber: "",
                                            materialGrade: "", generatedAt: Date(timeIntervalSince1970: 0))
        try expect(String(data: emptyPDF.prefix(5), encoding: .ascii)?.hasPrefix("%PDF") == true,
                   "An empty protocol still renders a valid PDF")
    }


    /// Lokaler KI-Assistent: strukturierte Aktionen, Geometrie-Validierung, keine Erfindungen.
    private static func assistant() throws {
        let service: AssistantService = LocalRuleAssistant()
        func part(_ name: String, _ position: Int, _ role: String?, _ length: Double,
                  quantity: Int = 1, reference: Bool = false) -> AssistantPartContext {
            .init(id: UUID(), name: name, positionNumber: position, role: role, lengthMm: length,
                  quantity: quantity, isReference: reference,
                  weightPerMeterKg: ProfileCatalog.squareTube40x40x2.weightPerMeterKg)
        }
        var context = AssistantContext(widthMm: 1200, heightMm: 800, profile: ProfileCatalog.squareTube40x40x2,
                                       parts: [part("Rahmen oben", 1, "rahmen_oben", 1200),
                                               part("Querstrebe", 5, "querstrebe", 1120, quantity: 6),
                                               part("Schloss", 7, "hardware", 0, reference: true)],
                                       dimensions: [], assemblyStepCount: 7, hasAssembly: true)
        let smallFrame = AssistantContext(widthMm: 1000, heightMm: 900, profile: ProfileCatalog.squareTube40x40x2,
                                          parts: [], dimensions: [], assemblyStepCount: 0, hasAssembly: true)

        // 1 · Rahmen erstellen → strukturierte CHANGE_PARAMETER-Aktionen
        let frame = try service.respond(to: "Erstelle einen Rahmen 1200x800 aus 40x40x2", context: smallFrame)
        try expect(frame.proposals.count == 2, "Width and height proposals for the frame command")
        try expect(frame.proposals.allSatisfy { $0.kind == .changeParameter && $0.isValid },
                   "Frame proposals are valid CHANGE_PARAMETER actions")
        let bigger = try service.respond(to: "Erstelle einen Rahmen 1200x800 aus 40x40x3", context: smallFrame)
        try expect(bigger.proposals.count == 3, "A changed profile adds its own proposal")
        try expect(bigger.proposals.contains { $0.summary.contains("40 × 40 × 3") }, "Profile change is previewed")
        // Parameter ändern: gültig, mit konkreten Folgeänderungen
        let height = try service.respond(to: "Ändere die Höhe auf 900 mm", context: context)
        try expect(height.proposals.count == 1 && height.proposals[0].isValid, "Height change validates")
        try expect(height.proposals[0].details.contains { $0.contains("820") },
                   "Inner height 800−80=720 → 900−80=820 is previewed")
        try expect(height.proposals[0].details.contains { $0.contains("Zeichnung") }, "Drawing follow-up is stated")
        let tooSmall = try service.respond(to: "Ändere die Höhe auf 50 mm", context: context)
        try expect(!tooSmall.proposals[0].isValid && tooSmall.proposals[0].problem != nil,
                   "The geometry engine rejects a degenerate height")

        // 2 · Querstrebe hinzufügen: parametrische Länge aus dem Modell
        let add = try service.respond(to: "Füge eine Querstrebe in der Mitte hinzu", context: context)
        try expect(add.proposals.count == 1 && add.proposals[0].kind == .addPart && add.proposals[0].isValid,
                   "ADD_PART is valid")
        try expect(add.proposals[0].details.contains { $0.contains("1120") || $0.contains("1.120") },
                   "Parametric inner width length is previewed")
        try expect(add.proposals[0].details.contains { $0.contains("Mitte") }, "Placement is carried into the remark")
        let two = try service.respond(to: "Füge zwei Querstreben hinzu", context: context)
        if case .addPart(_, _, _, _, let quantity, _) = two.proposals[0].action {
            try expect(quantity == 2, "Quantity from the spoken word")
        } else {
            try expect(false, "ADD_PART action shape")
        }
        let noLength = try service.respond(to: "Füge ein Bauteil Halter hinzu", context: context)
        try expect(!noLength.proposals[0].isValid, "A non-parametric part without a length is refused")

        // 3 · Bohrung: passt, passt nicht, fehlende Position
        let hole = try service.respond(to: "Bohre ein Loch Ø10 in Pos 5", context: context)
        try expect(hole.proposals[0].kind == .addHole && hole.proposals[0].isValid, "ADD_HOLE valid for Pos 5")
        let bigHole = try service.respond(to: "Bohre ein Loch Ø60 in Pos 5", context: context)
        try expect(!bigHole.proposals[0].isValid, "A hole larger than the profile is rejected")
        let noPosition = try service.respond(to: "Bohre ein Loch Ø10", context: context)
        try expect(!noPosition.proposals[0].isValid, "A hole without a position asks for one")

        // 4 · Entfernen: per Positionsnummer, unbekannt bleibt abgelehnt
        let remove = try service.respond(to: "Entferne Pos 5", context: context)
        try expect(remove.proposals[0].kind == .removePart && remove.proposals[0].isValid, "REMOVE_PART resolves by position")
        try expect(remove.proposals[0].summary.contains("Querstrebe"), "The part is named in the preview")
        let unknownPart = try service.respond(to: "Entferne das Dach", context: context)
        try expect(!unknownPart.proposals[0].isValid, "An unknown part is refused, never guessed")

        // 5 · Zuschnittliste: reine Anzeige ohne Bestätigung
        let report = try service.respond(to: "Erstelle die Zuschnittliste", context: context)
        try expect(report.proposals[0].isReport && report.proposals[0].kind == .report,
                   "The cut list report needs no confirmation")
        try expect(report.message.contains("Teile"), "The report carries the summary")
        try expect(report.proposals[0].details.isEmpty, "A report changes nothing")

        // 6 · Montageschritt
        let step = try service.respond(to: "Füge einen Montageschritt für Pos 2 hinzu", context: context)
        try expect(step.proposals[0].kind == .createAssemblyStep, "CREATE_ASSEMBLY_STEP is recognised")

        // 7 · Unbekanntes bleibt unerkannt – nichts wird erfunden
        let nonsense = try service.respond(to: "Bestelle sechs Tonnen Blech", context: context)
        try expect(nonsense.proposals.isEmpty, "Unknown commands produce no actions")

        // 8 · Determinismus
        let again = try service.respond(to: "Ändere die Höhe auf 900 mm", context: context)
        try expect(again.message == height.message
                   && again.proposals.map(\.summary) == height.proposals.map(\.summary)
                   && again.proposals.map(\.details) == height.proposals.map(\.details),
                   "The local engine is deterministic")
        _ = context
    }

    /// Export & technische Zeichnungen: Blattaufbau, Renderer, CSV, STL, STEP-Kapselung.
    private static func exports() throws {
        let profile = ProfileCatalog.squareTube40x40x2
        func part(_ name: String, _ pos: Int, _ role: String?, _ length: Double, quantity: Int = 1,
                  reference: Bool = false) -> ExportPartInput {
            .init(id: UUID(), name: name, positionNumber: pos, quantity: quantity, lengthMm: length,
                  role: role, profile: profile, isReference: reference)
        }
        var drawing = CADDrawing()
        try drawing.add(CADFactory.hole(center: .init(x: 300, y: 400), radiusPoint: .init(x: 305, y: 400)))
        drawing = CADOperations.drillPattern(drawing, center: .init(x: 500, y: 500), kind: .linear,
                                             count: 3, spacingMm: 60, pitchCircleDiameterMm: 0,
                                             startAngleDeg: 0, holeDiameterMm: 8) ?? drawing
        let input = ExportInput(projectName: "Gartentor", projectNumber: "2026-001", materialGrade: "S235",
                                revisionLabel: "A", widthMm: 1200, heightMm: 800, profile: profile,
                                parts: [part("Rahmen oben", 1, "rahmen_oben", 1200),
                                        part("Rahmen unten", 2, "rahmen_unten", 1200),
                                        part("Rahmen links", 3, "rahmen_links", 720),
                                        part("Rahmen rechts", 4, "rahmen_rechts", 720),
                                        part("Querstrebe", 5, "strebe", 720, quantity: 6),
                                        part("Schloss", 6, "hardware", 0, reference: true)],
                                drawing: drawing, approved: true, generatedAt: Date(timeIntervalSince1970: 0))

        // 1. Blatt: Ansichten, Maßstab, Stückliste, Schriftfeld; deterministisch auf A4 und A3
        let a4 = try TechnicalDrawingBuilder.sheet(for: input, format: .a4)
        let titles = a4.views.map(\.title)
        try expect(titles.contains("Vorderansicht") && titles.contains("Seitenansicht")
                   && titles.contains("Draufsicht"), "Front, side and top views")
        try expect(titles.contains { $0.hasPrefix("Schnitt A-A") }, "Section with the profile")
        try expect(titles.contains { $0.hasPrefix("Detail Z") }, "Detail view from the hole")
        let frontHoleCount = a4.views.first { $0.title == "Vorderansicht" }?.primitives.reduce(0) { count, primitive in
            if case .circle = primitive { return count + 1 }
            return count
        } ?? 0
        try expect(frontHoleCount == 4, "Every patterned hole is included in the technical drawing export")
        try expect(a4.mainScaleLabel.hasPrefix("1:"), "Standard scale label")
        try expect(a4.partsList.rows.count == 6, "Every part appears in the parts list")
        try expect(a4.partsList.rows.contains { $0.contains("Zukaufteil") }, "Hardware is marked as a purchase part")
        try expect(a4.titleBlock.contains { $0.label == "Zeichnungsnummer" && $0.value == "2026-001-Z01" },
                   "Drawing number from the project number")
        try expect(a4.titleBlock.contains { $0.label == "Datum" && $0.value == "01.01.1970" }, "Deterministic date")
        try expect(a4.titleBlock.contains { $0.label == "Freigabe" && $0.value == "Geometrie freigegeben" },
                   "Approval state in the title block")
        try expect(TechnicalSheet.Format.a3.sizeMm.x > TechnicalSheet.Format.a4.sizeMm.x, "A3 is larger than A4")
        let a3 = try TechnicalDrawingBuilder.sheet(for: input, format: .a3)
        let sameViewCount = a3.views.count == a4.views.count
        let samePartsList = a3.partsList.rows == a4.partsList.rows
        try expect(sameViewCount && samePartsList, "Same content on A3")
        let a4Again = try TechnicalDrawingBuilder.sheet(for: input, format: .a4)
        try expect(a4 == a4Again, "The sheet is deterministic")

        // Alles bleibt endend und auf dem Blatt
        func points(of primitive: SheetPrimitive) -> [Vec2] {
            switch primitive {
            case .line(let a, let b), .dashed(let a, let b): return [a, b]
            case .polyline(let p): return p
            case .circle(let c, _), .arc(let c, _, _, _), .text(let c, _, _): return [c]
            }
        }
        for view in a4.views {
            for primitive in view.primitives {
                for point in points(of: primitive) {
                    try expect(point.isFinite, "Finite sheet coordinates")
                    try expect(point.x >= -1 && point.x <= a4.format.sizeMm.x + 1
                               && point.y >= -1 && point.y <= a4.format.sizeMm.y + 1,
                               "Primitives stay on the sheet")
                }
            }
        }

        // 2. PDF, PNG, JPEG
        let pdf = SheetPDF.data(a4)
        try expect(String(data: pdf.prefix(5), encoding: .ascii)?.hasPrefix("%PDF") == true, "Drawing PDF header")
        try expect(pdf.count > 2000, "The drawing PDF carries content")
        let png = SheetImage.png(a4)
        try expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")
        let jpeg = SheetImage.jpeg(a4)
        try expect(jpeg.count > 1000 && jpeg.prefix(2) == Data([0xFF, 0xD8]), "JPEG signature")

        // 3. SVG und DXF
        let svg = SheetSVG.render(a4)
        try expect(svg.hasPrefix("<svg") && svg.contains("</svg>"), "SVG document")
        try expect(svg.contains("<line") && svg.contains("<circle") && svg.contains("<polyline"), "SVG primitives")
        try expect(!svg.lowercased().contains("nan") && !svg.lowercased().contains("inf"), "No NaN/Infinity in SVG")
        let dxf = SheetDXF.render(a4)
        try expect(dxf.contains("SECTION\n2\nENTITIES"), "DXF entity section")
        try expect(dxf.contains("\nLINE\n") && dxf.contains("\nCIRCLE\n") && dxf.contains("\nPOLYLINE\n"), "DXF entities")
        try expect(dxf.contains("\nARC\n") && dxf.contains("\nTEXT\n"), "DXF arcs and text")
        try expect(dxf.hasSuffix("0\nENDSEC\n0\nEOF\n"), "DXF terminator")

        // 4. Montage-PDF und Materialliste-CSV
        let steps = [MontageStepInput(index: 1, title: "Rahmen unten einsetzen", parts: "Rahmen unten",
                                      movement: "ansetzen", connection: "Anschweißen, Naht a3",
                                      tool: "WIG-Inverter", lengthMm: 1200, positionNote: "unten", note: "",
                                      check: MontageCheck(title: "Diagonalen prüfen", targetMm: 1442.2205, toleranceMm: 1))]
        let montagePDF = MontagePDF.data(steps: steps, projectName: "Gartentor", projectNumber: "2026-001",
                                         generatedAt: Date(timeIntervalSince1970: 0))
        try expect(String(data: montagePDF.prefix(5), encoding: .ascii)?.hasPrefix("%PDF") == true, "Montage PDF")
        let emptyMontage = MontagePDF.data(steps: [], projectName: "Leer", projectNumber: "",
                                           generatedAt: Date(timeIntervalSince1970: 0))
        try expect(String(data: emptyMontage.prefix(5), encoding: .ascii)?.hasPrefix("%PDF") == true,
                   "An empty montage document is still a valid PDF")
        let rows = [MaterialRow(positionNumber: 1, name: "Rahmen oben", profileLabel: "40 × 40 × 2",
                                grade: "S235", quantity: 2, totalLengthMm: 2400, isReference: false),
                    MaterialRow(positionNumber: 6, name: "Schloss", profileLabel: "Zukaufteil",
                                grade: "–", quantity: 1, totalLengthMm: 0, isReference: true)]
        let materialCSV = MaterialListCSV.export(rows: rows, projectName: "Gartentor;Tor",
                                                 projectNumber: "2026-001", generatedAt: Date(timeIntervalSince1970: 0))
        try expect(materialCSV.hasPrefix("Materialliste;\"Gartentor;Tor\""), "CSV field escaping")
        try expect(materialCSV.contains("2400") && materialCSV.contains("Summe"), "Totals are exported")
        try expect(materialCSV.contains("Zukaufteil"), "Purchase parts stay visible")

        // 5. STL aus dem parametrischen Modell: ein Facette je Dreieck
        let built = try STLExporter.buildParts(widthMm: 1200, heightMm: 800, profile: profile, parts: [
            .init(id: UUID(), name: "Rahmen oben", positionNumber: 1, quantity: 1, role: "rahmen_oben", profile: profile)
        ])
        try expect(built.count == 1 && !built[0].mesh.isEmpty, "The part builds for STL")
        let stl = STLExporter.ascii(parts: built, modelName: "Gartentor 2026")
        try expect(stl.hasPrefix("solid Gartentor_2026"), "STL name is sanitized")
        try expect(stl.contains("facet normal") && stl.contains("vertex") && stl.contains("endsolid"), "STL structure")
        try expect(stl.components(separatedBy: "endfacet").count - 1 == built[0].mesh.triangleCount,
                   "One facet per triangle")

        // 6. STEP bleibt gekapselt und als „In Entwicklung" sichtbar
        let step = ExportCatalog.specs.first { $0.id == .modelSTEP }
        try expect(step?.isReady == false, "STEP is never offered as ready")
        if case .inDevelopment(let note) = step?.availability {
            try expect(note.contains("STL"), "The note points to the STL alternative")
        } else {
            try expect(false, "STEP availability shape")
        }
        try expect(ExportCatalog.specs.first { $0.id == .quotePDF }?.isReady == true,
                   "Angebots-PDF is available as a shareable export")
        try expect(ExportCatalog.specs.first { $0.id == .worksiteSurveyPDF }?.isReady == true,
                   "Worksite survey PDF is available as a shareable export")
        try expect(ExportCatalog.specs.count == ExportFormatID.allCases.count, "Every format has a spec")

        let surveyPDFInput = WorksiteSurveyPDFInput(
            projectName: "Gartentor", projectNumber: "2026-001", revisionLabel: "B",
            projectDescription: "Tor am Innenhof", widthMm: 1200, heightMm: 800,
            profileLabel: "40 × 40 × 2", materialGrade: "S235",
            entries: [
                WorksiteSurveyPDFEntry(id: UUID(), label: "Lichte Breite", value: 1187.5, unit: "mm",
                                       partLabel: "Pos. 3 · Rahmen links", note: "Am Torpfosten gemessen",
                                       measuredAt: Date(timeIntervalSince1970: 100)),
                WorksiteSurveyPDFEntry(id: UUID(), label: "Bodenhöhe", value: 0, unit: "cm",
                                       measuredAt: Date(timeIntervalSince1970: 200))
            ], generatedAt: Date(timeIntervalSince1970: 300))
        let surveyPDF = WorksiteSurveyPDF.data(for: surveyPDFInput)
        try expect(String(data: surveyPDF.prefix(5), encoding: .ascii)?.hasPrefix("%PDF") == true
                   && surveyPDF.count > 1000,
                   "Worksite survey export creates a substantial valid PDF")
        guard let surveyDocument = PDFDocument(data: surveyPDF), let surveyText = surveyDocument.string else {
            throw Failure.assertion("The worksite survey PDF opens and contains selectable text")
        }
        try expect(surveyText.contains("Gartentor") && surveyText.contains("2026-001")
                   && surveyText.contains("Rev. B") && surveyText.contains("Tor am Innenhof")
                   && surveyText.contains("40 × 40 × 2") && surveyText.contains("S235"),
                   "Survey PDF includes project identity, revision and project details")
        try expect(surveyText.contains("Lichte Breite") && surveyText.contains("1.187,5 mm")
                   && surveyText.contains("Pos. 3 · Rahmen links") && surveyText.contains("Am Torpfosten gemessen")
                   && surveyText.contains("Bodenhöhe") && surveyText.contains("0 cm"),
                   "Survey PDF includes readings, units, optional part attribution, notes and zero values")
        try expect((surveyText.range(of: "Lichte Breite")?.lowerBound ?? surveyText.endIndex)
                   < (surveyText.range(of: "Bodenhöhe")?.lowerBound ?? surveyText.startIndex),
                   "Survey PDF entries are sorted chronologically")
        let emptySurveyPDF = WorksiteSurveyPDF.data(for: WorksiteSurveyPDFInput(
            projectName: "Leeres Projekt", projectNumber: "P-0", revisionLabel: "A",
            projectDescription: "", widthMm: 0, heightMm: 0, profileLabel: "", materialGrade: "",
            entries: [], generatedAt: Date(timeIntervalSince1970: 0)))
        guard let emptySurveyText = PDFDocument(data: emptySurveyPDF)?.string else {
            throw Failure.assertion("Empty survey PDF remains a valid document")
        }
        try expect(emptySurveyText.contains("Noch keine Baustellenmessungen erfasst")
                   && !emptySurveyText.contains("Bauteil:") && !emptySurveyText.contains("Notiz:"),
                   "Empty survey PDF renders a clear empty state without blank optional fields")
        let manySurveyEntries = (0..<30).map { index in
            WorksiteSurveyPDFEntry(id: UUID(), label: "Messung \(index + 1)", value: Double(index),
                                   unit: "mm", measuredAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let manySurveyPDF = WorksiteSurveyPDF.data(for: WorksiteSurveyPDFInput(
            projectName: "Großprojekt", projectNumber: "P-30", revisionLabel: "A",
            projectDescription: "", widthMm: 1200, heightMm: 800, profileLabel: "40 × 40 × 2",
            materialGrade: "S235", entries: manySurveyEntries,
            generatedAt: Date(timeIntervalSince1970: 1000)))
        guard let manySurveyDocument = PDFDocument(data: manySurveyPDF) else {
            throw Failure.assertion("Long survey document opens")
        }
        try expect(manySurveyDocument.pageCount > 1
                   && manySurveyDocument.string?.contains("Messung 30") == true,
                   "Long survey reports span pages without dropping final measurements")
        let noPartOrNote = WorksiteSurveyPDF.data(for: WorksiteSurveyPDFInput(
            projectName: "Kurz", projectNumber: "K-1", revisionLabel: "A", projectDescription: "",
            widthMm: 1200, heightMm: 800, profileLabel: "40 × 40 × 2", materialGrade: "S235",
            entries: [WorksiteSurveyPDFEntry(id: UUID(), label: "Prüfmaß", value: 10, unit: "mm",
                                              measuredAt: Date(timeIntervalSince1970: 10))],
            generatedAt: Date(timeIntervalSince1970: 20)))
        let noPartText = PDFDocument(data: noPartOrNote)?.string ?? ""
        try expect(noPartText.contains("Prüfmaß") && !noPartText.contains("Bauteil:")
                   && !noPartText.contains("Notiz:"),
                   "Missing optional part assignment and note are omitted cleanly")

        let bridgeSchema = LocalStore.schema
        let bridgeContainer = try ModelContainer(for: bridgeSchema, configurations: [
            ModelConfiguration(schema: bridgeSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let bridgeStore = LocalStore()
        bridgeStore.container = bridgeContainer
        try DemoData.seedIfNeeded(context: bridgeContainer.mainContext)
        guard let surveyProject = try bridgeContainer.mainContext.fetch(FetchDescriptor<MCProject>()).first,
              let surveyPart = surveyProject.parts.first(where: { !$0.isReference }) else {
            throw Failure.assertion("Export integration fixture includes a project part")
        }
        let surveyRecord = try bridgeStore.addWorksiteMeasurement(surveyProject, label: "Breite vor Ort",
                                                                 value: 1180, unit: "mm", part: surveyPart,
                                                                 note: "Am Bestand")
        let bridged = ExportBridge.worksiteSurveyPDFInput(for: surveyProject,
                                                          generatedAt: Date(timeIntervalSince1970: 500))
        try expect(bridged.entries.count == 1 && bridged.entries[0].id == surveyRecord.id
                   && bridged.entries[0].partLabel?.contains(surveyPart.name) == true
                   && bridged.entries[0].note == "Am Bestand",
                   "Project export bridge snapshots site measurements with their part and note")
        let revisionCountBeforeSurveyExport = surveyProject.revisions.count
        try bridgeStore.recordExport(surveyProject, title: "Baustellen-Aufmaß-PDF")
        try expect(surveyProject.revisions.count == revisionCountBeforeSurveyExport + 1
                   && surveyProject.revisions.last?.note == "Export erstellt: Baustellen-Aufmaß-PDF",
                   "Creating a site survey PDF is recorded in the project history")

        let offerEstimate = MaterialCostBuilder.estimate(
            entries: CutListBuilder.entries(materialGrade: "S235", parts: [
                CutListPartInput(id: UUID(), name: "Rahmen oben", positionNumber: 1, quantity: 2,
                                 lengthMm: 1200, profile: profile, isReference: false, remark: "")
            ], cuts: []),
            materialPrices: [MaterialPriceInput(grade: "S235", pricePerKg: 4.5)],
            purchasedParts: [PurchasedPartPriceInput(id: UUID(), positionNumber: 6,
                                                       name: "Schloss", quantity: 1, unitPrice: nil)])
        let quoteInput = QuotePDFInput(projectName: "Gartentor", projectNumber: "2026-001",
                                       revisionLabel: "A", projectDescription: "Werkstattangebot",
                                       widthMm: 1200, heightMm: 800, profileLabel: profile.dimensionLabel,
                                       materialGrade: "S235", estimate: offerEstimate,
                                       generatedAt: Date(timeIntervalSince1970: 0))
        let quotePDF = QuotePDF.data(for: quoteInput)
        try expect(String(data: quotePDF.prefix(5), encoding: .ascii)?.hasPrefix("%PDF") == true
                   && quotePDF.count > 1000,
                   "Offer PDF contains project data and a rendered position-by-position estimate")
        guard let quoteDocument = PDFDocument(data: quotePDF), let quoteText = quoteDocument.string else {
            throw Failure.assertion("The offer PDF opens and contains selectable text")
        }
        try expect(quoteText.contains("Gartentor") && quoteText.contains("Rahmen oben")
                   && quoteText.contains("Schloss") && quoteText.contains("NICHT EINGEPREIST")
                   && quoteText.contains("Zwischensumme"),
                   "Offer PDF includes project and position data and calls out unpriced positions")

        let longEstimate = MaterialCostEstimate(
            lines: (1...40).map { index in
                MaterialCostLine(id: UUID(), positionNumber: index, name: "Profilposition \(index)",
                                 detail: "2 × \(profile.dimensionLabel) · 1200 mm", kind: .fabricated,
                                 quantity: 2, weightKg: 5, amountEUR: 22.5,
                                 priceDescription: "4,50 €/kg · 5,00 kg")
            }, totalEUR: 900, pricedPositionCount: 40, unpricedPositionCount: 0)
        let longPDF = QuotePDF.data(for: QuotePDFInput(
            projectName: "Mehrseitiges Projekt", projectNumber: "2026-003", revisionLabel: "B",
            projectDescription: "", widthMm: 1200, heightMm: 800, profileLabel: profile.dimensionLabel,
            materialGrade: "S235", estimate: longEstimate,
            generatedAt: Date(timeIntervalSince1970: 0)))
        try expect((PDFDocument(data: longPDF)?.pageCount ?? 0) > 1,
                   "Long offer estimates flow across readable PDF pages")

        let emptyQuote = QuotePDF.data(for: QuotePDFInput(
            projectName: "Leeres Projekt", projectNumber: "2026-002", revisionLabel: "A",
            projectDescription: "", widthMm: 1000, heightMm: 800, profileLabel: profile.dimensionLabel,
            materialGrade: "", estimate: MaterialCostBuilder.estimate(entries: [], materialPrices: [], purchasedParts: []),
            generatedAt: Date(timeIntervalSince1970: 0)))
        try expect(String(data: emptyQuote.prefix(5), encoding: .ascii)?.hasPrefix("%PDF") == true,
                   "An offer PDF remains valid when a project has no priced positions")
    }

    private static func photoDocumentation() throws {
        try expect(PhotoCategory.allCases.map(\.label) == ["Vorher", "Geheftet", "Geschweißt", "Geschliffen", "Lackiert", "Fertig", "Aufmaß"],
                   "Manufacturing and site-survey photo categories are available")

        let schema = LocalStore.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = LocalStore()
        store.container = container
        let context = container.mainContext
        try DemoData.seedIfNeeded(context: context)
        guard let project = try context.fetch(FetchDescriptor<MCProject>()).first,
              let part = project.parts.first else {
            throw Failure.assertion("Photo test project and part are available")
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let image = renderer.image { drawing in
            UIColor.systemOrange.setFill()
            drawing.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            throw Failure.assertion("Photo fixture encodes as JPEG")
        }

        try rejects {
            _ = try store.addPhoto(project, imageData: imageData, category: "unknown", caption: "", partID: nil)
        }
        try rejects {
            _ = try store.addPhoto(project, imageData: imageData, category: PhotoCategory.vorher.rawValue,
                                   caption: "", partID: UUID())
        }
        try expect(project.photos.isEmpty, "Rejected photo imports create no model records")

        let revisionCount = project.revisions.count
        let photo = try store.addPhoto(project, imageData: imageData, category: PhotoCategory.vorher.rawValue,
                                       caption: "  Rahmen geheftet  ", partID: part.id)
        let fileName = photo.imageFileName
        defer { PhotoImageStore.delete(fileName) }
        try expect(project.photos.contains { $0.id == photo.id }, "Saved photo belongs to its project")
        try expect(photo.caption == "Rahmen geheftet" && photo.partID == part.id, "Caption and part link are saved")
        try expect(PhotoImageStore.load(fileName) != nil, "Photo bytes are stored locally and readable")
        try expect(project.revisions.count == revisionCount + 1
                   && project.revisions.last?.note.contains("Fertigungsfoto hinzugefügt") == true,
                   "Photo import and change-log entry are one transaction")

        try store.updatePhoto(photo, category: PhotoCategory.geschweisst.rawValue,
                              caption: "Naht fertig", partID: nil)
        try expect(photo.categoryLabel == "Geschweißt" && photo.caption == "Naht fertig" && photo.partID == nil,
                   "Photo review metadata can be updated")
        try expect(project.revisions.last?.note.contains("Fertigungsfoto aktualisiert") == true,
                   "Photo metadata changes are recorded")

        try store.deletePhoto(photo)
        try expect(project.photos.isEmpty, "Deleted photo is removed from the project")
        try expect(fileName.map { !FileManager.default.fileExists(atPath: PhotoImageStore.url(for: $0).path) } == true,
                   "Photo file is removed after the deletion transaction")
        try expect(project.revisions.last?.note.contains("Fertigungsfoto gelöscht") == true,
                   "Photo deletion is recorded")
    }

    private static func materialCosts() throws {
        let profile = ProfileCatalog.squareTube40x40x2
        let partID = UUID()
        let fabricated = CutListPartInput(id: partID, name: "Rahmenprofil", positionNumber: 1,
                                          quantity: 2, lengthMm: 1000, profile: profile,
                                          isReference: false, remark: "")
        let entries = CutListBuilder.entries(materialGrade: "S235", parts: [fabricated], cuts: [])
        let purchaseID = UUID()
        let estimate = MaterialCostBuilder.estimate(
            entries: entries,
            materialPrices: [MaterialPriceInput(grade: "S235", pricePerKg: 5)],
            purchasedParts: [PurchasedPartPriceInput(id: purchaseID, positionNumber: 8,
                                                       name: "Scharnier", quantity: 3, unitPrice: 12.5)])
        try expect(estimate.lines.count == 2, "Estimate includes fabricated and purchased positions")
        try close(estimate.lines.first { $0.id == partID }?.weightKg ?? 0, 4.7728,
                  "Material estimate derives total steel weight from profile and length")
        try close(estimate.lines.first { $0.id == partID }?.amountEUR ?? 0, 23.864,
                  "Material line amount equals total weight times the €/kg rate")
        try close(estimate.lines.first { $0.id == purchaseID }?.amountEUR ?? 0, 37.5,
                  "Purchased line amount equals unit price times quantity")
        try close(estimate.totalEUR ?? 0, 61.364, "Project total sums all priced positions")
        try expect(estimate.pricedPositionCount == 2 && estimate.unpricedPositionCount == 0,
                   "Estimate distinguishes priced and unpriced positions")
        try expect(estimate.topPositions.first?.id == purchaseID, "Largest positions are ranked by amount")

        let withLabor = MaterialCostBuilder.estimate(
            entries: entries,
            materialPrices: [MaterialPriceInput(grade: "S235", pricePerKg: 5)],
            purchasedParts: [PurchasedPartPriceInput(id: purchaseID, positionNumber: 8,
                                                       name: "Scharnier", quantity: 3, unitPrice: 12.5,
                                                       laborHours: 0.5)],
            laborRateEURPerHour: 40,
            laborHoursByPosition: [partID: 2.5])
        try close(withLabor.laborTotalEUR ?? 0, 120, "Labor sum is calculated from position hours at the hourly rate")
        try close(withLabor.totalEUR ?? 0, 61.364, "Material and purchased-part subtotal remains separate")
        try close(withLabor.totalWithLaborEUR ?? 0, 181.364, "Project total adds labor to the materials and purchases subtotal")
        try close(withLabor.lines.first { $0.id == partID }?.laborEUR ?? 0, 100,
                  "Fabricated-part labor is shown on its position")
        try close(withLabor.lines.first { $0.id == purchaseID }?.laborEUR ?? 0, 20,
                  "Purchased-part labor is also calculated per position")

        let wasteEntry = CutListBuilder.entries(materialGrade: "S235", parts: [
            CutListPartInput(id: UUID(), name: "Profil", positionNumber: 9, quantity: 1,
                             lengthMm: 5900, profile: profile, isReference: false, remark: ""),
            CutListPartInput(id: UUID(), name: "Restprofil", positionNumber: 10, quantity: 1,
                             lengthMm: 1000, profile: profile, isReference: false, remark: "")
        ], cuts: [])
        let estimateWithWaste = MaterialCostBuilder.estimate(
            entries: wasteEntry, materialPrices: [MaterialPriceInput(grade: "S235", pricePerKg: 5)],
            purchasedParts: [], stockLengthMm: 6000, kerfMm: 3)
        try close(estimateWithWaste.totalWithLaborEUR ?? 0,
                  (estimateWithWaste.totalEUR ?? 0) + (estimateWithWaste.cuttingSummary?.wasteTotalEUR ?? 0),
                  "Known scrap value is included in the live project total")

        let missingLaborRate = MaterialCostBuilder.estimate(
            entries: entries, materialPrices: [MaterialPriceInput(grade: "S235", pricePerKg: 5)],
            purchasedParts: [], laborHoursByPosition: [partID: 1.25])
        try expect(missingLaborRate.unpricedLaborPositionCount == 1 && missingLaborRate.lines[0].laborEUR == nil,
                   "Entered labor time is visibly unpriced until a rate exists")

        let incomplete = MaterialCostBuilder.estimate(
            entries: entries,
            materialPrices: [MaterialPriceInput(grade: "S235", pricePerKg: 5),
                             MaterialPriceInput(grade: "S235", pricePerKg: 6)],
            purchasedParts: [PurchasedPartPriceInput(id: purchaseID, positionNumber: 8,
                                                       name: "Scharnier", quantity: 3, unitPrice: nil)])
        try expect(incomplete.lines.allSatisfy { $0.amountEUR == nil }
                   && incomplete.unpricedPositionCount == 2,
                   "Missing or conflicting prices are excluded instead of guessed")
        try close(incomplete.totalEUR ?? -1, 0, "Unpriced entries do not inflate the known subtotal")

        let schema = LocalStore.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = LocalStore()
        store.container = container
        let context = container.mainContext
        try DemoData.seedIfNeeded(context: context)
        guard let project = try context.fetch(FetchDescriptor<MCProject>()).first,
              let material = project.materials.first,
              let hardware = project.parts.first(where: \.isReference),
              let fabricatedPart = project.parts.first(where: { !$0.isReference }) else {
            throw Failure.assertion("Seeded material and both part types are available")
        }
        let revisionsBefore = project.revisions.count
        try store.setMaterialPrice(material, pricePerKg: 4.25)
        try store.setPurchasedPartPrice(hardware, unitPrice: 18.75)
        try store.setLaborRate(project, eurosPerHour: 32)
        try store.setLaborHours(fabricatedPart, hours: 1.25)
        try store.setCuttingSettings(project, stockLengthMm: 3000, kerfMm: 4)
        try expect(material.pricePerKg == 4.25 && hardware.unitPrice == 18.75,
                   "Material and purchased part prices persist")
        try expect(project.laborRateEURPerHour == 32 && fabricatedPart.laborHours == 1.25,
                   "Project hourly rate and per-position labor hours persist")
        try expect(project.stockBarLengthMm == 3000 && project.sawKerfMm == 4,
                   "Stock length and saw kerf persist on the project")
        try expect(project.revisions.count == revisionsBefore + 5
                   && project.revisions.suffix(5).contains { $0.note.contains("Materialpreis") }
                   && project.revisions.suffix(5).contains { $0.note.contains("Zukaufteil") }
                   && project.revisions.suffix(5).contains { $0.note.contains("Stundensatz") }
                   && project.revisions.suffix(5).contains { $0.note.contains("Arbeitszeit Pos.") }
                   && project.revisions.suffix(5).contains { $0.note.contains("Schnittparameter") },
                   "Price, labor and cutting-setting changes are recorded in the project history")
        let integratedEstimate = ExportBridge.materialCostEstimate(for: project)
        try close(integratedEstimate.laborTotalEUR ?? -1, 40,
                  "Persisted labor inputs are reflected in the project estimate")
        let beforeOfferExport = project.revisions.count
        try store.recordExport(project, title: "Angebots-PDF")
        try expect(project.revisions.count == beforeOfferExport + 1
                   && project.revisions.last?.note == "Export erstellt: Angebots-PDF",
                   "Creating the shareable offer is recorded in the project history")
        try rejects { try store.setMaterialPrice(material, pricePerKg: -.infinity) }
        try rejects { try store.setPurchasedPartPrice(hardware, unitPrice: -1) }
        try rejects { try store.setLaborRate(project, eurosPerHour: .nan) }
        try rejects { try store.setLaborRate(project, eurosPerHour: 1_000_001) }
        try rejects { try store.setLaborHours(fabricatedPart, hours: -.infinity) }
        try rejects { try store.setLaborHours(fabricatedPart, hours: -0.1) }
        try rejects { try store.setCuttingSettings(project, stockLengthMm: .nan, kerfMm: 3) }
        try rejects { try store.setCuttingSettings(project, stockLengthMm: 1000, kerfMm: 100) }
        try rejects { try store.setCuttingSettings(project, stockLengthMm: 100, kerfMm: 100) }
    }

    private static func worksiteSurvey() throws {
        let schema = LocalStore.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = LocalStore()
        store.container = container
        let context = container.mainContext
        try DemoData.seedIfNeeded(context: context)
        guard let project = try context.fetch(FetchDescriptor<MCProject>()).first,
              let part = project.parts.first(where: { !$0.isReference }) else {
            throw Failure.assertion("A project and fabricated part exist for the site survey")
        }
        let startingRevisions = project.revisions.count
        try rejects {
            _ = try store.addWorksiteMeasurement(project, label: "  ", value: 1200,
                                                 unit: "mm", part: nil, note: "")
        }
        try rejects {
            _ = try store.addWorksiteMeasurement(project, label: "Ungültig", value: .infinity,
                                                 unit: "mm", part: nil, note: "")
        }
        try rejects {
            _ = try store.addWorksiteMeasurement(project, label: "Ungültig", value: 10,
                                                 unit: "  ", part: nil, note: "")
        }
        let foreignProject = MCProject(name: "Fremdprojekt", number: "TEST-FOREIGN")
        let foreignPart = MCPart(name: "Fremdteil", positionNumber: 1, lengthMm: 100)
        foreignProject.parts.append(foreignPart)
        try rejects {
            _ = try store.addWorksiteMeasurement(project, label: "Falsch zugeordnet", value: 10,
                                                 unit: "mm", part: foreignPart, note: "")
        }
        try expect(project.measurements.filter { $0.kind == "worksite" }.isEmpty
                   && project.revisions.count == startingRevisions,
                   "Invalid survey measurements do not create data or project-history entries")

        let measurement = try store.addWorksiteMeasurement(project, label: "  Lichte Breite  ", value: 1187.5,
                                                          unit: " mm ", part: part, note: "  Am Torpfosten gemessen  ")
        try expect(measurement.kind == "worksite" && measurement.displayLabel == "Lichte Breite"
                   && measurement.unit == "mm" && measurement.note == "Am Torpfosten gemessen"
                   && measurement.partID == part.id && measurement.project?.id == project.id,
                   "Site survey stores a cleaned value, unit, note and optional part link locally")
        try expect(measurement.createdAt <= Date()
                   && project.revisions.count == startingRevisions + 1
                   && project.revisions.last?.note.contains("Baustellen-Aufmaß erfasst") == true,
                   "Survey creation is timestamped and recorded in project history")

        let unassigned = try store.addWorksiteMeasurement(project, label: "Bodenhöhe", value: 0,
                                                          unit: "cm", part: nil, note: "")
        try expect(unassigned.partID == nil && unassigned.note == nil,
                   "Survey supports optional part assignment and note")
        guard let secondPart = project.parts.first(where: { $0.id != part.id }) else {
            throw Failure.assertion("A second part is available to verify per-part filters")
        }
        let secondPartMeasurement = MCMeasurement(kind: "worksite", value: 42, unit: "mm", tolerance: 0,
                                                  targetName: "Lochabstand", partID: secondPart.id)
        let nonSurveyMeasurement = MCMeasurement(kind: "montage", value: 800, unit: "mm", tolerance: 1,
                                                 targetName: "Montageprüfung", partID: part.id)
        measurement.createdAt = Date(timeIntervalSince1970: 100)
        unassigned.createdAt = Date(timeIntervalSince1970: 200)
        secondPartMeasurement.createdAt = Date(timeIntervalSince1970: 300)
        nonSurveyMeasurement.createdAt = Date(timeIntervalSince1970: 400)
        let filterFixture = [measurement, unassigned, secondPartMeasurement, nonSurveyMeasurement]
        let allFiltered = WorksiteSurveyFilter.all.apply(to: filterFixture)
        try expect(allFiltered.map(\.id) == [secondPartMeasurement.id, unassigned.id, measurement.id]
                   && allFiltered.count == 3,
                   "All filter shows every site measurement in reverse-chronological order, excluding other measurement types")
        let unassignedFiltered = WorksiteSurveyFilter.unassigned.apply(to: filterFixture)
        try expect(unassignedFiltered.map(\.id) == [unassigned.id] && unassignedFiltered.count == 1,
                   "Unassigned filter shows only measurements without a part")
        let partFiltered = WorksiteSurveyFilter.part(part.id).apply(to: filterFixture)
        try expect(partFiltered.map(\.id) == [measurement.id] && partFiltered.count == 1,
                   "Per-part filter shows only matching measurements and preserves chronology")
        try expect(WorksiteSurveyFilter.part(secondPart.id).apply(to: filterFixture).map(\.id) == [secondPartMeasurement.id],
                   "Each individual part can be selected independently")
        try expect(WorksiteSurveyFilter.part(UUID()).apply(to: filterFixture).isEmpty,
                   "A part with no survey readings has an empty result")
        try expect(project.revisions.count == startingRevisions + 2,
                   "Each new site measurement gets its own history entry")
        try expect(measurement.targetValue == nil && measurement.targetTolerance == nil
                   && measurement.worksiteCheckWithinTolerance == nil
                   && measurement.worksiteCheckSummary == nil,
                   "New site measurements have no inferred expected value or tolerance")

        try rejects {
            try store.setWorksiteMeasurementCheck(measurement, targetValue: 1188, tolerance: nil)
        }
        try rejects {
            try store.setWorksiteMeasurementCheck(measurement, targetValue: nil, tolerance: 1)
        }
        try rejects {
            try store.setWorksiteMeasurementCheck(measurement, targetValue: .nan, tolerance: 1)
        }
        try rejects {
            try store.setWorksiteMeasurementCheck(measurement, targetValue: 1188, tolerance: -.infinity)
        }
        try expect(measurement.targetValue == nil && measurement.targetTolerance == nil
                   && project.revisions.count == startingRevisions + 2,
                   "Incomplete or invalid check data does not alter the measurement or history")

        try store.setWorksiteMeasurementCheck(measurement, targetValue: 1188, tolerance: 0.5)
        try expect(measurement.worksiteCheckWithinTolerance == true
                   && measurement.worksiteCheckSummary?.contains("Innerhalb der Toleranz") == true,
                   "A deviation exactly at the tolerance boundary passes")
        try expect(project.revisions.count == startingRevisions + 3
                   && project.revisions.last?.note.contains("keine Sollprüfung → Soll 1188 ±0,5 mm") == true
                   && project.revisions.last?.note.contains("innerhalb der Toleranz") == true,
                   "Adding an expected value and tolerance is recorded with its result")

        try store.setWorksiteMeasurementCheck(measurement, targetValue: 1188, tolerance: 0.49)
        try expect(measurement.worksiteCheckWithinTolerance == false
                   && measurement.worksiteCheckSummary?.contains("Außerhalb der Toleranz") == true,
                   "A deviation greater than the tolerance fails clearly")
        try expect(project.revisions.count == startingRevisions + 4
                   && project.revisions.last?.note.contains("Soll 1188 ±0,5 mm → Soll 1188 ±0,49 mm") == true
                   && project.revisions.last?.note.contains("außerhalb der Toleranz") == true,
                   "Changing the tolerance and its resulting outcome is recorded")

        let revisionsBeforeNoOp = project.revisions.count
        try store.setWorksiteMeasurementCheck(measurement, targetValue: 1188, tolerance: 0.49)
        try expect(project.revisions.count == revisionsBeforeNoOp,
                   "Saving unchanged check values does not create a duplicate history entry")
        try store.setWorksiteMeasurementCheck(measurement, targetValue: nil, tolerance: nil)
        try expect(measurement.targetValue == nil && measurement.targetTolerance == nil
                   && measurement.worksiteCheckWithinTolerance == nil
                   && project.revisions.last?.note.contains("keine Sollprüfung") == true,
                   "Clearing both optional check fields restores an explicitly unassessed measurement")
        try expect(project.revisions.count == startingRevisions + 5,
                   "Clearing a saved check is recorded")

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let image = renderer.image { drawing in
            UIColor.systemOrange.setFill()
            drawing.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            throw Failure.assertion("A worksite photo fixture encodes as JPEG")
        }
        let existingPhoto = try store.addPhoto(project, imageData: imageData,
                                               category: PhotoCategory.vorher.rawValue,
                                               caption: "Bestand vor Ort", partID: part.id)
        let existingFile = existingPhoto.imageFileName
        defer { PhotoImageStore.delete(existingFile) }
        let beforeAssociation = project.revisions.count
        try store.associateWorksitePhoto(existingPhoto, with: measurement)
        try expect(measurement.photos.contains { $0.id == existingPhoto.id }
                   && project.photos.contains { $0.id == existingPhoto.id }
                   && project.revisions.count == beforeAssociation + 1
                   && project.revisions.last?.note.contains("Baustellen-Aufmaßfoto zugeordnet") == true,
                   "An existing project photo can be linked to a measurement and is recorded")
        let beforeDuplicateLink = project.revisions.count
        try store.associateWorksitePhoto(existingPhoto, with: measurement)
        try expect(project.revisions.count == beforeDuplicateLink,
                   "Linking the same photo twice does not duplicate the relation or history")
        try store.removeWorksitePhoto(existingPhoto, from: measurement)
        try expect(!measurement.photos.contains { $0.id == existingPhoto.id }
                   && project.photos.contains { $0.id == existingPhoto.id }
                   && PhotoImageStore.load(existingFile) != nil
                   && project.revisions.last?.note.contains("Projektfoto bleibt erhalten") == true,
                   "Removing a link preserves the project's photo and local image")
        try store.associateWorksitePhoto(existingPhoto, with: measurement)

        let importedPhoto = try store.addWorksiteMeasurementPhoto(measurement, imageData: imageData)
        let importedFile = importedPhoto.imageFileName
        defer { PhotoImageStore.delete(importedFile) }
        try expect(importedPhoto.category == PhotoCategory.aufmass.rawValue
                   && importedPhoto.caption == measurement.displayLabel
                   && measurement.photos.contains { $0.id == importedPhoto.id }
                   && project.photos.contains { $0.id == importedPhoto.id }
                   && PhotoImageStore.load(importedFile) != nil
                   && project.revisions.last?.note.contains("importiert und zugeordnet") == true,
                   "A new measurement photo is stored locally, added to project documentation and recorded")

        let revisionsBeforeDelete = project.revisions.count
        try store.deleteWorksiteMeasurement(measurement)
        try expect(!project.measurements.contains { $0.id == measurement.id }
                   && project.measurements.contains { $0.id == unassigned.id },
                   "Deleting a site measurement leaves other measurements intact")
        try expect(project.photos.contains { $0.id == existingPhoto.id }
                   && project.photos.contains { $0.id == importedPhoto.id }
                   && PhotoImageStore.load(existingFile) != nil && PhotoImageStore.load(importedFile) != nil,
                   "Deleting a measurement leaves linked project photos and their files intact")
        try expect(project.revisions.count == revisionsBeforeDelete + 1
                   && project.revisions.last?.note.contains("Baustellen-Aufmaß gelöscht: Lichte Breite") == true,
                   "Survey deletion is recorded in project history")
        let assemblyCheck = MCMeasurement(kind: "montage", value: 800, unit: "mm", tolerance: 1,
                                          targetName: "Diagonale")
        project.measurements.append(assemblyCheck)
        try rejects { try store.deleteWorksiteMeasurement(assemblyCheck) }
        try expect(project.measurements.contains { $0.id == assemblyCheck.id },
                   "The survey deletion action cannot remove assembly-check measurements")
    }

    private static func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let schema = LocalStore.schema
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        var projectID = UUID(), partIDs: [UUID] = []
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = container.mainContext
            try DemoData.seedIfNeeded(context: context)
            try DemoData.seedIfNeeded(context: context)
            try expect(context.fetchCount(FetchDescriptor<MCProject>()) == 1, "Idempotent demo seed")
            let project = try context.fetch(FetchDescriptor<MCProject>())[0]
            projectID = project.id; partIDs = project.parts.map(\.id).sorted { $0.uuidString < $1.uuidString }
            project.widthMm = 1500
            project.stockBarLengthMm = 4500
            project.sawKerfMm = 4
            try context.save()
            try close(project.parts.first { $0.role == "rahmen_oben" }!.lengthMm, 1500, "Derived part length")
            try close(project.dimensions.first { $0.parameterKey == "innerWidth" }!.valueMm, 1420, "Derived dimension")
            try expect(project.geometryRecords.first { $0.parameterRole == "outer" }!.element == .rectangle(origin: .zero, width: 1500, height: 800), "Derived contour")
            try SQLiteSnapshot.capture(store: url)
            try expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("recovery-pending").path), "Snapshot marker cleared")
            // A database without its WAL sidecar files but with an intact snapshot is the
            // crash-shaped input the recovery path must handle.
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
            }
            try expect(!FileManager.default.fileExists(atPath: url.path), "Sidecar removal exposed the recovery path")
        }
        let restored = directory.appendingPathComponent("restored.store")
        try FileManager.default.copyItem(at: SQLiteSnapshot.locations(store: url)[0], to: restored)
        try SQLiteSnapshot.verify(restored)
        try autoreleasepool {
            let config = ModelConfiguration(schema: schema, url: restored, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = container.mainContext
            let project = try context.fetch(FetchDescriptor<MCProject>())[0]
            try expect(project.id == projectID, "Recovery UUID")
            try expect(project.parts.map(\.id).sorted { $0.uuidString < $1.uuidString } == partIDs, "Recovery part UUIDs")
            try close(project.widthMm, 1500, "Recovery parameters")
            try expect(project.stockBarLengthMm == 4500 && project.sawKerfMm == 4,
                       "Saved cutting settings survive a local database recovery")
            context.delete(project); try context.save()
            try expect(context.fetchCount(FetchDescriptor<MCPart>()) == 0, "Cascade deletion")
            try DemoData.seedIfNeeded(context: context)
            try expect(context.fetchCount(FetchDescriptor<MCProject>()) == 0, "Deleted demo is not recreated")
            try expect(context.fetchCount(FetchDescriptor<MCProfile>()) > 0, "Catalogue survives project deletion")
        }
    }
}
#endif
