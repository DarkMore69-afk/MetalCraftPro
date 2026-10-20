//
//  AssemblyModel.swift
//  MetalCraftPro
//
//  Hierarchische Baugruppen als reine, deterministische Domäne: Der Baum und die
//  Stückliste werden vollständig aus dem parametrischen Modell abgeleitet –
//  Längen und Mengen leben in den Bauteilen, nie in einer zweiten Kopie.
//

import Foundation

/// Schnappschuss eines Bauteils für den Baugruppenbaum.
public struct AssemblyPartSnapshot: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var positionNumber: Int
    public var quantity: Int
    /// nil = Referenz-/Zukaufteil (kein Fertigungsprofil, keine Länge).
    public var role: String?
    public var profileName: String?
    public var lengthMm: Double?

    public init(id: UUID, name: String, positionNumber: Int, quantity: Int,
                role: String?, profileName: String?, lengthMm: Double?) {
        self.id = id; self.name = name; self.positionNumber = positionNumber
        self.quantity = quantity; self.role = role
        self.profileName = profileName; self.lengthMm = lengthMm
    }
}

/// Schnappschuss einer Baugruppe mit ihrer geordneten Kinderliste.
public struct AssemblySnapshot: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var positionNumber: Int
    public var quantity: Int
    public var parentAssemblyID: UUID?
    public var partIDs: [UUID]
    public var childAssemblyIDs: [UUID]

    public init(id: UUID, name: String, positionNumber: Int, quantity: Int,
                parentAssemblyID: UUID?, partIDs: [UUID], childAssemblyIDs: [UUID]) {
        self.id = id; self.name = name; self.positionNumber = positionNumber
        self.quantity = quantity; self.parentAssemblyID = parentAssemblyID
        self.partIDs = partIDs; self.childAssemblyIDs = childAssemblyIDs
    }
}

public struct AssemblyTreeInput: Sendable, Equatable {
    public var parts: [AssemblyPartSnapshot]
    public var assemblies: [AssemblySnapshot]

    public init(parts: [AssemblyPartSnapshot], assemblies: [AssemblySnapshot]) {
        self.parts = parts; self.assemblies = assemblies
    }
}

/// Ein Knoten des Baums: Baugruppe, eigenes Bauteil oder Referenzteil.
public struct AssemblyNode: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case assembly, ownPart, referencePart

        public var label: String {
            switch self {
            case .assembly: return "Baugruppe"
            case .ownPart: return "Eigen"
            case .referencePart: return "Referenz"
            }
        }
    }

    /// Stabiler Anzeige-Schlüssel (Baugruppen-UUID bzw. Bauteil-UUID mit Pfad).
    public var id: String
    public var kind: Kind
    public var assemblyID: UUID?
    public var partID: UUID?
    public var name: String
    public var positionNumber: Int
    public var quantity: Int
    /// Abgeleitete Fertigungslänge (nil bei Referenz- und Baugruppenknoten).
    public var lengthMm: Double?
    public var profileName: String?
    public var children: [AssemblyNode]

    public var isAssembly: Bool { kind == .assembly }
}

/// Eine Zeile der abgeleiteten Stückliste.
public struct BOMRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var partID: UUID
    public var positionNumber: Int
    public var name: String
    public var profileName: String?
    /// Fertigungslänge je Stück (nil bei Referenzteilen).
    public var unitLengthMm: Double?
    /// Gesamtmenge: Produkt der Stückzahlen entlang des Pfades.
    public var totalQuantity: Int
    public var isReference: Bool
}

public enum AssemblyTreeBuilder {

    /// Baut die Hierarchie: Unterbaugruppen in ihrer Reihenfolge, dann Bauteile.
    /// Wurzelebenen sind Baugruppen ohne gültigen Elternverweis (nach Positionsnummer)
    /// plus Bauteile, die keiner Baugruppe zugeordnet sind.
    public static func build(_ input: AssemblyTreeInput) -> [AssemblyNode] {
        let partsByID = Dictionary(uniqueKeysWithValues: input.parts.map { ($0.id, $0) })
        let assembliesByID = Dictionary(uniqueKeysWithValues: input.assemblies.map { ($0.id, $0) })
        let placedPartIDs = Set(input.assemblies.flatMap(\.partIDs))

        func children(of assembly: AssemblySnapshot, path: Set<UUID>) -> [AssemblyNode] {
            var nodes: [AssemblyNode] = []
            for childID in assembly.childAssemblyIDs {
                guard let child = assembliesByID[childID], !path.contains(child.id) else { continue }
                nodes.append(node(for: child, path: path))
            }
            for partID in assembly.partIDs {
                guard let part = partsByID[partID] else { continue }
                nodes.append(node(for: part))
            }
            return nodes
        }

        func node(for assembly: AssemblySnapshot, path: Set<UUID>) -> AssemblyNode {
            let nextPath = path.union([assembly.id])
            return AssemblyNode(
                id: "a:\(assembly.id.uuidString)", kind: .assembly,
                assemblyID: assembly.id, partID: nil,
                name: assembly.name, positionNumber: assembly.positionNumber,
                quantity: max(1, assembly.quantity), lengthMm: nil, profileName: nil,
                children: children(of: assembly, path: nextPath)
            )
        }

        func node(for part: AssemblyPartSnapshot) -> AssemblyNode {
            AssemblyNode(
                id: "p:\(part.id.uuidString)",
                kind: part.role == "hardware" ? .referencePart : .ownPart,
                assemblyID: nil, partID: part.id,
                name: part.name, positionNumber: part.positionNumber,
                quantity: max(1, part.quantity), lengthMm: part.lengthMm,
                profileName: part.profileName, children: []
            )
        }

        var roots: [AssemblyNode] = []
        // Wurzel = Baugruppen ohne Elternverweis oder mit zirkulärem/ungültigem Verweis.
        let rootAssemblies = input.assemblies
            .filter { assembly in
                guard let parentID = assembly.parentAssemblyID,
                      assembliesByID[parentID] != nil else { return true }
                // Zirkelprüfung: folgt der Elternpfad zurück zu diesem Knoten?
                var visited: Set<UUID> = [assembly.id]
                var current: UUID? = parentID
                while let step = current {
                    if step == assembly.id { return true }
                    guard visited.insert(step).inserted,
                          let next = assembliesByID[step] else { return true }
                    current = next.parentAssemblyID
                }
                return false
            }
            .sorted { $0.positionNumber < $1.positionNumber }

        roots.append(contentsOf: rootAssemblies.map { node(for: $0, path: []) })
        for part in input.parts.sorted(by: { $0.positionNumber < $1.positionNumber })
        where !placedPartIDs.contains(part.id) {
            roots.append(node(for: part))
        }
        return roots
    }

    /// Stückliste: Bauteile mit Gesamtmengen (Produkt der Stückzahlen am Pfad),
    /// sortiert nach Positionsnummer.
    public static func billOfMaterials(_ roots: [AssemblyNode]) -> [BOMRow] {
        var totals: [UUID: (row: BOMRow, quantity: Int)] = [:]

        func walk(_ nodes: [AssemblyNode], multiplier: Int) {
            for node in nodes {
                switch node.kind {
                case .assembly:
                    walk(node.children, multiplier: multiplier * node.quantity)
                case .ownPart, .referencePart:
                    guard let partID = node.partID else { continue }
                    let total = multiplier * node.quantity
                    if var existing = totals[partID] {
                        existing.quantity += total
                        totals[partID] = existing
                    } else {
                        totals[partID] = (BOMRow(
                            id: "bom:\(partID.uuidString)", partID: partID,
                            positionNumber: node.positionNumber, name: node.name,
                            profileName: node.profileName, unitLengthMm: node.lengthMm,
                            totalQuantity: total, isReference: node.kind == .referencePart
                        ), total)
                    }
                }
            }
        }

        walk(roots, multiplier: 1)
        return totals.values.map(\.row).sorted { $0.positionNumber < $1.positionNumber }
    }
}
