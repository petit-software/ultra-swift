import SwiftUI
import UltraChat
import UltraDesign

/// The Chat tab: which services a Chat pane can talk to, and the keys that let it.
///
/// Keys go to the keychain the moment the field loses focus; nothing here has an OK
/// button. A base URL is asked for only where one makes sense — the OpenAI-compatible
/// row, which is nothing BUT a base URL.
struct ChatSettings: View {
    @State private var defaultProvider = ChatDefaults.provider
    @State private var anthropicKey = ChatCredentials.apiKey(for: .anthropic)
    @State private var openAIKey = ChatCredentials.apiKey(for: .openAI)
    @State private var geminiKey = ChatCredentials.apiKey(for: .gemini)
    @State private var compatibleKey = ChatCredentials.apiKey(for: .compatible)
    @State private var compatibleURL = ChatCredentials.baseURL(for: .compatible)?.absoluteString ?? ""

    var body: some View {
        Form {
            Section {
                Picker("New chats use", selection: $defaultProvider) {
                    ForEach(ChatProviderID.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .onChange(of: defaultProvider) { _, new in ChatDefaults.provider = new }
            } header: {
                Text("Default")
            } footer: {
                SettingNote("Every conversation can switch provider and model from the pane's "
                            + "footer. A default that has no key falls back to Apple "
                            + "Intelligence, which needs none."
                            + (AppleProvider.unavailableReason.map { " " + $0 } ?? ""))
            }

            Section {
                keyRow("Anthropic", key: $anthropicKey, provider: .anthropic,
                       placeholder: "sk-ant-…")
                keyRow("OpenAI", key: $openAIKey, provider: .openAI, placeholder: "sk-…")
                keyRow("Google Gemini", key: $geminiKey, provider: .gemini, placeholder: "AIza…")
            } header: {
                Text("API keys")
            } footer: {
                SettingNote("Stored in your keychain, never in a file. Each service's own "
                            + "model list is fetched when a pane opens on it.")
            }

            Section {
                LabeledContent("Base URL") {
                    TextField(OpenAIProvider.defaultCompatibleBaseURL.absoluteString,
                              text: $compatibleURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit { ChatCredentials.setBaseURL(compatibleURL, for: .compatible) }
                        .onChange(of: compatibleURL) { _, new in
                            ChatCredentials.setBaseURL(new, for: .compatible)
                        }
                }
                keyRow("API key", key: $compatibleKey, provider: .compatible,
                       placeholder: "optional")
            } header: {
                Text("OpenAI-compatible")
            } footer: {
                SettingNote("Anything speaking OpenAI's chat API: Ollama and LM Studio on "
                            + "this Mac, OpenRouter, a proxy at work. The default is "
                            + "Ollama's local endpoint, which needs no key.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 480)
    }

    private func keyRow(_ title: String, key: Binding<String>, provider: ChatProviderID,
                        placeholder: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                SecureField(placeholder, text: key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onChange(of: key.wrappedValue) { _, new in
                        ChatCredentials.setAPIKey(new, for: provider)
                    }
                // Dimmed rather than absent when there is nothing to clear, so the row
                // has the same shape whether or not a key is in it.
                Button("Clear") {
                    key.wrappedValue = ""
                    ChatCredentials.setAPIKey("", for: provider)
                }
                .disabled(key.wrappedValue.isEmpty)
            }
        }
    }
}
