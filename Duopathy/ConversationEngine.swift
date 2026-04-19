import Foundation
import AppKit

struct ConversationMessage: Identifiable, Hashable, Codable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
    }

    enum Speaker: String, Codable {
        case left
        case right
        case system
    }

    var id: UUID = UUID()
    var role: Role
    var speaker: Speaker
    var text: String
}

enum ConversationLengthOption: String, CaseIterable, Identifiable {
    case fifty = "50 each"
    case hundred = "100 each"
    case twoHundred = "200 each"
    case custom = "Custom"

    var id: String { rawValue }

    var fixedValue: Int? {
        switch self {
        case .fifty: return 50
        case .hundred: return 100
        case .twoHundred: return 200
        case .custom: return nil
        }
    }
}

private struct TranscriptFile: Codable {
    let exportedAt: Date
    let leftModel: String
    let rightModel: String
    let postsPerSide: Int
    let messages: [ConversationMessage]
}

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published var models: [OllamaModel] = []
    @Published var leftModel: String = ""
    @Published var rightModel: String = ""
    @Published var messages: [ConversationMessage] = []
    @Published var isRunning = false
    @Published var statusText = "Idle"
    @Published var lengthOption: ConversationLengthOption = .fifty
    @Published var customMessageLimitInput = "150"
    @Published var transcriptRevision = 0

    private var shouldStop = false
    private var conversationTask: Task<Void, Never>?
    private let ollama: OllamaService

    init(ollama: OllamaService = OllamaService()) {
        self.ollama = ollama
        Task {
            await refreshModels()
        }
    }

    var leftCount: Int {
        messages.filter { $0.speaker == .left }.count
    }

    var rightCount: Int {
        messages.filter { $0.speaker == .right }.count
    }

    func refreshModels() async {
        statusText = "Loading models..."
        do {
            let fetched = try await ollama.listModels()
            models = fetched

            if leftModel.isEmpty {
                leftModel = fetched.first?.name ?? ""
            }
            if rightModel.isEmpty {
                rightModel = fetched.dropFirst().first?.name ?? fetched.first?.name ?? ""
            }

            statusText = fetched.isEmpty ? "No local Ollama models found." : "Ready"
        } catch {
            statusText = "Failed to load models: \(error.localizedDescription)"
        }
    }

    func stopConversation() {
        shouldStop = true
        statusText = "Stopping..."
        conversationTask?.cancel()
    }

    func clearConversation() {
        messages.removeAll()
        transcriptRevision += 1
        statusText = "Cleared"
    }

    func saveTranscript() {
        guard !messages.isEmpty else {
            statusText = "No messages to save."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "duopathy-transcript-\(timestamp()).json"

        guard panel.runModal() == .OK, let url = panel.url else {
            statusText = "Save canceled"
            return
        }

        let payload = TranscriptFile(
            exportedAt: Date(),
            leftModel: leftModel,
            rightModel: rightModel,
            postsPerSide: resolvedMessageLimit(),
            messages: messages
        )

        do {
            let data = try JSONEncoder.pretty.encode(payload)
            try data.write(to: url, options: .atomic)
            statusText = "Saved transcript"
        } catch {
            statusText = "Save failed: \(error.localizedDescription)"
        }
    }

    func loadTranscript() {
        guard !isRunning else {
            statusText = "Stop the conversation before loading a transcript."
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            statusText = "Load canceled"
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let transcript = try JSONDecoder.transcript.decode(TranscriptFile.self, from: data)
            leftModel = transcript.leftModel
            rightModel = transcript.rightModel
            messages = transcript.messages
            transcriptRevision += 1
            statusText = "Transcript loaded"
        } catch {
            statusText = "Load failed: \(error.localizedDescription)"
        }
    }

    func startConversation() {
        guard !leftModel.isEmpty, !rightModel.isEmpty else {
            statusText = "Select both models before starting."
            return
        }

        let limitPerSide = resolvedMessageLimit()
        guard limitPerSide > 0 else {
            statusText = "Posts per side must be greater than zero."
            return
        }

        messages.removeAll()
        transcriptRevision += 1
        statusText = "Running \(limitPerSide) posts per side..."
        isRunning = true
        shouldStop = false

        conversationTask = Task {
            await runConversation(limitPerSide: limitPerSide)
        }
    }

    private func resolvedMessageLimit() -> Int {
        if let fixed = lengthOption.fixedValue {
            return fixed
        }
        return Int(customMessageLimitInput) ?? 0
    }

    private func appendMessage(_ message: ConversationMessage) {
        messages.append(message)
        transcriptRevision += 1
    }

    private func updateMessageText(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        transcriptRevision += 1
    }

    private func appendDeltaToMessage(id: UUID, delta: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += delta
        transcriptRevision += 1
    }

    private func messageText(id: UUID) -> String {
        messages.first(where: { $0.id == id })?.text ?? ""
    }

    private func runConversation(limitPerSide: Int) async {
        let starterPrompt = "Introduce yourself in one sentence and ask one interesting question."

        appendMessage(.init(role: .system, speaker: .system, text: "Conversation started. Left model: \(leftModel), Right model: \(rightModel), \(limitPerSide) posts per side."))

        var transcript: [ConversationMessage] = []
        var nextSpeaker: ConversationMessage.Speaker = .left
        var seedText = starterPrompt
        var leftPosts = 0
        var rightPosts = 0

        while leftPosts < limitPerSide || rightPosts < limitPerSide {
            if shouldStop || Task.isCancelled {
                appendMessage(.init(role: .system, speaker: .system, text: "Conversation stopped by user."))
                statusText = "Stopped"
                isRunning = false
                return
            }

            if nextSpeaker == .left && leftPosts >= limitPerSide {
                nextSpeaker = .right
            } else if nextSpeaker == .right && rightPosts >= limitPerSide {
                nextSpeaker = .left
            }

            let activeModel = (nextSpeaker == .left) ? leftModel : rightModel
            let passiveSpeaker = (nextSpeaker == .left) ? "RIGHT" : "LEFT"

            var prompt = "You are model \(nextSpeaker.rawValue.uppercased()) in a two-model chat. Keep replies short (1-3 sentences). End with a question for \(passiveSpeaker)."
            prompt += "\n\nMost recent message to respond to:\n\(seedText)"

            let contextWindow = transcript.suffix(14)
            var requestMessages: [ConversationMessage] = [
                .init(role: .system, speaker: .system, text: prompt)
            ]
            requestMessages.append(contentsOf: contextWindow.map {
                .init(role: .user, speaker: .system, text: "\($0.speaker == .left ? "LEFT" : "RIGHT"): \($0.text)")
            })

            let placeholder = ConversationMessage(role: .assistant, speaker: nextSpeaker, text: "")
            appendMessage(placeholder)

            do {
                try await ollama.chatStream(model: activeModel, messages: requestMessages) { delta in
                    await MainActor.run {
                        self.appendDeltaToMessage(id: placeholder.id, delta: delta)
                    }
                }

                let finalized = messageText(id: placeholder.id).trimmingCharacters(in: .whitespacesAndNewlines)
                let safeText = finalized.isEmpty ? "(No response)" : finalized
                updateMessageText(id: placeholder.id, text: safeText)

                let committed = ConversationMessage(id: placeholder.id, role: .assistant, speaker: nextSpeaker, text: safeText)
                transcript.append(committed)
                seedText = safeText

                if nextSpeaker == .left {
                    leftPosts += 1
                } else {
                    rightPosts += 1
                }

                statusText = "Posted L:\(leftPosts)/\(limitPerSide)  R:\(rightPosts)/\(limitPerSide)"
            } catch is CancellationError {
                appendMessage(.init(role: .system, speaker: .system, text: "Conversation canceled."))
                statusText = "Stopped"
                isRunning = false
                return
            } catch {
                appendMessage(.init(role: .system, speaker: .system, text: "Error from \(activeModel): \(error.localizedDescription)"))
                statusText = "Failed"
                isRunning = false
                return
            }

            nextSpeaker = (nextSpeaker == .left) ? .right : .left
        }

        appendMessage(.init(role: .system, speaker: .system, text: "Conversation completed. Left posted \(leftPosts), right posted \(rightPosts)."))
        statusText = "Completed"
        isRunning = false
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var transcript: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
