import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: ConversationViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            controls
        }
        .padding()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duopathy")
                    .font(.title2.weight(.bold))
                Text("Two local Ollama models talking to each other")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("L:\(viewModel.leftCount)  R:\(viewModel.rightCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.statusText)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.gray.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.bottom, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onChange(of: viewModel.transcriptRevision) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: ConversationMessage) -> some View {
        let isLeft = message.speaker == .left
        let isRight = message.speaker == .right

        HStack {
            if isRight { Spacer(minLength: 50) }

            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(color(for: message.speaker))
                )
                .frame(maxWidth: 560, alignment: isRight ? .trailing : .leading)

            if isLeft { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 12)
    }

    private func color(for speaker: ConversationMessage.Speaker) -> Color {
        switch speaker {
        case .left:
            return Color.blue.opacity(0.2)
        case .right:
            return Color.green.opacity(0.2)
        case .system:
            return Color.orange.opacity(0.18)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Left Ollama Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Left Model", selection: $viewModel.leftModel) {
                        ForEach(viewModel.models, id: \.name) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .frame(width: 280)
                    .disabled(viewModel.isRunning)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Right Ollama Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Right Model", selection: $viewModel.rightModel) {
                        ForEach(viewModel.models, id: \.name) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .frame(width: 280)
                    .disabled(viewModel.isRunning)
                }

                Spacer()

                Button("Refresh Models") {
                    Task { await viewModel.refreshModels() }
                }
                .disabled(viewModel.isRunning)

                Button("Load Transcript") {
                    viewModel.loadTranscript()
                }
                .disabled(viewModel.isRunning)

                Button("Save Transcript") {
                    viewModel.saveTranscript()
                }
            }

            HStack(spacing: 14) {
                Text("Topic")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Enter conversation topic", text: $viewModel.topic)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 460)
                    .disabled(viewModel.isRunning)

                Spacer()
            }

            HStack(spacing: 14) {
                Text("Ollama Server")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("http://127.0.0.1:11434", text: $viewModel.ollamaBaseURLInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 460)
                    .disabled(viewModel.isRunning || viewModel.isScanningForOllamaServers)

                Button("Apply") {
                    viewModel.applyOllamaBaseURL()
                }
                .disabled(viewModel.isRunning || viewModel.isScanningForOllamaServers)

                if viewModel.isScanningForOllamaServers {
                    Button("Stop Scan") {
                        viewModel.stopScanningForOllamaServers()
                    }
                } else {
                    Button("Scan Local Network") {
                        viewModel.scanForOllamaServers()
                    }
                    .disabled(viewModel.isRunning)
                }

                Spacer()
            }

            if viewModel.isScanningForOllamaServers {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning local network for Ollama servers...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if !viewModel.discoveredOllamaServers.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    Text("Discovered")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.discoveredOllamaServers, id: \.absoluteString) { server in
                                Button {
                                    viewModel.useDiscoveredServer(server)
                                } label: {
                                    HStack {
                                        Text(server.absoluteString)
                                            .font(.caption.monospaced())
                                        if server.absoluteString == viewModel.ollamaBaseURLInput {
                                            Text("(selected)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 96)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Spacer()
                }
            }

            HStack(spacing: 14) {
                Toggle("Use prior transcript as seed", isOn: $viewModel.usePriorTranscriptAsSeed)
                    .toggleStyle(.checkbox)
                    .disabled(viewModel.isRunning)

                Spacer()
            }

            HStack(spacing: 14) {
                Text("Posts Per Side")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Length", selection: $viewModel.lengthOption) {
                    ForEach(ConversationLengthOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(width: 180)
                .disabled(viewModel.isRunning)

                if viewModel.lengthOption == .custom {
                    TextField("Posts", text: $viewModel.customMessageLimitInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .disabled(viewModel.isRunning)
                }

                Spacer()

                Button("Clear") {
                    viewModel.clearConversation()
                }
                .disabled(viewModel.isRunning)

                if viewModel.isRunning {
                    Button("Stop") {
                        viewModel.stopConversation()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start") {
                        viewModel.startConversation()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.top, 12)
    }
}

#Preview {
    ContentView(viewModel: ConversationViewModel())
}
