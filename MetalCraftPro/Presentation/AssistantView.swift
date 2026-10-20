//
//  AssistantView.swift
//  MetalCraftPro
//
//  Lokaler KI-Assistent: Chat mit Vorschau-Karten. Jede Aktion wird vor der Anwendung
//  validiert und erst nach Bestätigung ausgeführt – nichts verändert das Modell ungeprüft.
//

import SwiftUI

struct AssistantView: View {
    @Environment(LocalStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: MCProject

    private struct ChatMessage: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
    }

    @State private var messages: [ChatMessage] = []
    @State private var proposals: [AssistantProposal] = []
    @State private var appliedIDs: Set<UUID> = []
    @State private var input = ""
    private let service: AssistantService = LocalRuleAssistant()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Color(white: 0.15))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(messages) { message in
                            bubble(message).id(message.id)
                        }
                        ForEach(proposals) { proposal in
                            proposalCard(proposal)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last?.id {
                        withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onChange(of: proposals.count) { _, _ in
                    if let last = proposals.last?.id {
                        withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            inputBar
        }
        .background(Theme.appBackground)
        .onAppear {
            if messages.isEmpty {
                messages.append(ChatMessage(isUser: false, text: """
                    Hallo! Ich bin dein lokaler Assistent – alles läuft auf dem Gerät, nichts verlässt die App. \
                    Ich schlage Änderungen als Vorschau vor und wende sie erst an, wenn du sie bestätigst. \
                    Zum Start: „\(LocalRuleAssistant.exampleCommands[0])“.
                    """))
            }
        }
    }

    // MARK: Kopfzeile

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Zurück")
            VStack(alignment: .leading, spacing: 4) {
                Text("KI-Assistent").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("\(project.name) · lokal & offline").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(Array(LocalRuleAssistant.exampleCommands.enumerated()), id: \.offset) { _, command in
                    Button(command) { input = command }
                }
            } label: {
                Image(systemName: "sparkles").frame(width: 30, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white).accessibilityLabel("Beispiele")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Chat

    private func bubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.isUser { Spacer(minLength: 48) }
            Text(message.text)
                .font(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 18).fill(message.isUser ? Theme.accent.opacity(0.18) : Color(white: 0.13)))
            if !message.isUser { Spacer(minLength: 48) }
        }
    }

    // MARK: Vorschau-Karte

    private func proposalCard(_ proposal: AssistantProposal) -> some View {
        let applied = appliedIDs.contains(proposal.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(proposal.kind.rawValue)
                    .font(.caption2.weight(.bold)).monospaced()
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.22)))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title).font(.subheadline.weight(.semibold))
                    if !proposal.summary.isEmpty {
                        Text(proposal.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if proposal.isReport {
                    Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                } else if applied {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if proposal.isValid {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            if !proposal.isReport {
                ForEach(proposal.details, id: \.self) { detail in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(.top, 6)
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let problem = proposal.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red)
            }
            if applied {
                Label("Angewendet und protokolliert", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(.green)
            } else if proposal.isValid && !proposal.isReport {
                Button {
                    apply(proposal)
                } label: {
                    Text("Übernehmen").font(.headline).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
            } else if proposal.isReport {
                Label("Nur Anzeige – es wird nichts geändert.", systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).background(Theme.card(cornerRadius: 18))
    }

    // MARK: Eingabe

    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Anweisung …", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.13)))
                    .submitLabel(.send)
                    .accessibilityIdentifier("assistantInput")
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up").font(.headline)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.black)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("assistantSend")
                .accessibilityLabel("Senden")
            }
            Text("Vorschläge werden lokal erzeugt und nur nach Bestätigung ausgeführt.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 14)
        .background(Color(white: 0.09))
    }

    // MARK: Aktionen

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        messages.append(ChatMessage(isUser: true, text: text))
        do {
            let response = try service.respond(to: text, context: makeContext())
            messages.append(ChatMessage(isUser: false, text: response.message))
            proposals = response.proposals
        } catch {
            messages.append(ChatMessage(isUser: false, text: "Da ist mir ein Fehler unterlaufen. Bitte versuche es erneut."))
        }
    }

    private func apply(_ proposal: AssistantProposal) {
        do {
            let note = try store.applyAssistant(project, action: proposal.action)
            appliedIDs.insert(proposal.id)
            messages.append(ChatMessage(isUser: false, text: note))
        } catch {
            messages.append(ChatMessage(isUser: false, text: error.localizedDescription))
        }
    }

    /// Unveränderlicher Schnappschuss des Projektstands für die Engine.
    private func makeContext() -> AssistantContext {
        AssistantContext(
            widthMm: project.widthMm,
            heightMm: project.heightMm,
            profile: project.profileSpec,
            parts: project.parts.map { part in
                AssistantPartContext(id: part.id, name: part.name, positionNumber: part.positionNumber,
                                     role: part.role, lengthMm: part.lengthMm, quantity: part.quantity,
                                     isReference: part.isReference,
                                     weightPerMeterKg: (part.profileSpec ?? project.profileSpec).weightPerMeterKg)
            },
            dimensions: project.dimensions.map { dimension in
                AssistantDimensionContext(label: dimension.label, valueMm: dimension.valueMm,
                                          isParametric: dimension.parameterKey != nil)
            },
            assemblyStepCount: project.assemblies.first?.orderedSteps.count ?? 0,
            hasAssembly: !project.assemblies.isEmpty
        )
    }
}
