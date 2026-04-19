import Foundation
import AppKit
import UniformTypeIdentifiers

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
    case five = "5 each"
    case ten = "10 each"
    case twentyFive = "25 each"
    case custom = "Custom"

    var id: String { rawValue }

    var fixedValue: Int? {
        switch self {
        case .five: return 5
        case .ten: return 10
        case .twentyFive: return 25
        case .custom: return nil
        }
    }
}

private enum TranscriptSaveFormat: CaseIterable {
    case json
    case txt
    case html
}

private struct TranscriptFile: Codable {
    let exportedAt: Date
    let leftModel: String
    let rightModel: String
    let postsPerSide: Int
    let topic: String
    let messages: [ConversationMessage]
}

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published var models: [OllamaModel] = []
    @Published var leftModel: String = ""
    @Published var rightModel: String = ""
    @Published var topic: String = ""
    @Published var messages: [ConversationMessage] = []
    @Published var isRunning = false
    @Published var statusText = "Idle"
    @Published var lengthOption: ConversationLengthOption = .ten
    @Published var customMessageLimitInput = "10"
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
        panel.allowedContentTypes = [.json, .plainText, .html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "duopathy-transcript-\(timestamp()).json"
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false

        let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24), pullsDown: false)
        formatPopup.addItems(withTitles: TranscriptSaveFormat.allCases.map { displayName(for: $0).uppercased() })
        formatPopup.selectItem(at: 0)

        let formatLabel = NSTextField(labelWithString: "Format:")
        let leadingSpacer = NSView(frame: .zero)
        leadingSpacer.translatesAutoresizingMaskIntoConstraints = false
        leadingSpacer.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let row = NSStackView(views: [leadingSpacer, formatLabel, formatPopup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let topSpacer = NSView(frame: .zero)
        topSpacer.translatesAutoresizingMaskIntoConstraints = false
        topSpacer.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let bottomSpacer = NSView(frame: .zero)
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomSpacer.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let accessory = NSStackView(views: [topSpacer, row, bottomSpacer])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 0
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else {
            statusText = "Save canceled"
            return
        }

        let payload = TranscriptFile(
            exportedAt: Date(),
            leftModel: leftModel,
            rightModel: rightModel,
            postsPerSide: resolvedMessageLimit(),
            topic: resolvedTopic(),
            messages: messages
        )

        do {
            let selectedIndex = max(0, formatPopup.indexOfSelectedItem)
            let format = TranscriptSaveFormat.allCases[min(selectedIndex, TranscriptSaveFormat.allCases.count - 1)]
            let finalURL = url.deletingPathExtension().appendingPathExtension(fileExtension(for: format))
            let data = try encodedTranscript(payload, format: format)
            try data.write(to: finalURL, options: .atomic)
            statusText = "Saved transcript (\(displayName(for: format)))"
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
            topic = transcript.topic
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

        let foundationTopic = resolvedTopic()

        messages.removeAll()
        transcriptRevision += 1
        statusText = "Running \(limitPerSide) posts per side..."
        isRunning = true
        shouldStop = false

        conversationTask = Task {
            await runConversation(limitPerSide: limitPerSide, topic: foundationTopic)
        }
    }

    private func resolvedMessageLimit() -> Int {
        if let fixed = lengthOption.fixedValue {
            return fixed
        }
        return Int(customMessageLimitInput) ?? 0
    }

    private func resolvedTopic() -> String {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "General discussion" : trimmed
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

    private func runConversation(limitPerSide: Int, topic: String) async {
        let starterPrompt = "The topic is: \(topic). Introduce yourself in one sentence and ask one interesting question about this topic."

        appendMessage(.init(role: .system, speaker: .system, text: "Conversation started. Topic: \(topic). Left model: \(leftModel), Right model: \(rightModel), \(limitPerSide) posts per side."))

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

            var prompt = "You are model \(nextSpeaker.rawValue.uppercased()) in a two-model chat."
            prompt += " The foundation topic is: \(topic). Stay on-topic throughout the dialog."
            prompt += " Keep replies short (1-3 sentences). End with a question for \(passiveSpeaker)."
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

        await appendFinalSummaries(topic: topic, transcript: transcript)
        appendMessage(.init(role: .system, speaker: .system, text: "Conversation completed. Left posted \(leftPosts), right posted \(rightPosts)."))
        statusText = "Completed"
        isRunning = false
    }

    private func appendFinalSummaries(topic: String, transcript: [ConversationMessage]) async {
        let speakers: [(ConversationMessage.Speaker, String)] = [(.left, leftModel), (.right, rightModel)]

        for (speaker, model) in speakers {
            let ownPosts = transcript
                .filter { $0.speaker == speaker }
                .map(\.text)
                .joined(separator: "\n- ")

            guard !ownPosts.isEmpty else { continue }

            let summaryPrompt = """
You are writing your final summary in a two-model discussion.
Topic: \(topic)
Summarize your own contributions in 3-5 bullet points.
Do not add new ideas beyond your earlier posts.

Your posts:
- \(ownPosts)
"""

            let requestMessages: [ConversationMessage] = [
                .init(role: .system, speaker: .system, text: "Provide a concise final summary."),
                .init(role: .user, speaker: .system, text: summaryPrompt)
            ]

            do {
                let summary = try await ollama.chat(model: model, messages: requestMessages)
                let finalText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                appendMessage(.init(
                    role: .assistant,
                    speaker: speaker,
                    text: finalText.isEmpty ? "(Summary unavailable)" : "Final summary:\n\(finalText)"
                ))
            } catch {
                appendMessage(.init(
                    role: .system,
                    speaker: .system,
                    text: "Failed to generate \(speaker.rawValue) summary: \(error.localizedDescription)"
                ))
            }
        }
    }

    private func displayName(for format: TranscriptSaveFormat) -> String {
        switch format {
        case .json: return "json"
        case .txt: return "txt"
        case .html: return "html"
        }
    }

    private func fileExtension(for format: TranscriptSaveFormat) -> String {
        switch format {
        case .json: return "json"
        case .txt: return "txt"
        case .html: return "html"
        }
    }

    private func encodedTranscript(_ payload: TranscriptFile, format: TranscriptSaveFormat) throws -> Data {
        switch format {
        case .json:
            return try JSONEncoder.pretty.encode(payload)
        case .txt:
            return plainTextTranscript(payload).data(using: .utf8) ?? Data()
        case .html:
            return htmlTranscript(payload).data(using: .utf8) ?? Data()
        }
    }

    private func plainTextTranscript(_ payload: TranscriptFile) -> String {
        let dateString = ISO8601DateFormatter().string(from: payload.exportedAt)
        var lines: [String] = [
            "Duopathy Transcript",
            "Exported: \(dateString)",
            "Topic: \(payload.topic)",
            "Left Model: \(payload.leftModel)",
            "Right Model: \(payload.rightModel)",
            "Posts Per Side: \(payload.postsPerSide)",
            "",
            "Messages:",
            ""
        ]

        for message in payload.messages {
            lines.append("[\(message.speaker.rawValue.uppercased())] \(message.text)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func htmlTranscript(_ payload: TranscriptFile) -> String {
        let dateString = ISO8601DateFormatter().string(from: payload.exportedAt)
        let messageBlocks = payload.messages.map { message in
            let speaker = htmlEscaped(message.speaker.rawValue.uppercased())
            let body = htmlEscaped(message.text).replacingOccurrences(of: "\n", with: "<br>")
            return "<div class=\"msg\"><div class=\"speaker\">\(speaker)</div><div>\(body)</div></div>"
        }.joined(separator: "\n")

        return """
<!doctype html>
<html>
<head>
  <meta charset=\"utf-8\">
  <title>Duopathy Transcript</title>
  <style>
    body { font-family: -apple-system, Helvetica, Arial, sans-serif; margin: 24px; }
    .meta { margin-bottom: 20px; }
    .meta div { margin: 2px 0; }
    .msg { border: 1px solid #ddd; border-radius: 10px; padding: 10px; margin-bottom: 10px; }
    .speaker { font-size: 12px; color: #666; margin-bottom: 6px; font-weight: 600; }
  </style>
</head>
<body>
  <h1>Duopathy Transcript</h1>
  <div class=\"meta\">
    <div><strong>Exported:</strong> \(htmlEscaped(dateString))</div>
    <div><strong>Topic:</strong> \(htmlEscaped(payload.topic))</div>
    <div><strong>Left Model:</strong> \(htmlEscaped(payload.leftModel))</div>
    <div><strong>Right Model:</strong> \(htmlEscaped(payload.rightModel))</div>
    <div><strong>Posts Per Side:</strong> \(payload.postsPerSide)</div>
  </div>
  \(messageBlocks)
</body>
</html>
"""
    }

    private func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
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
