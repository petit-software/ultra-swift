import AppKit
import SwiftUI
import UltraChat
import UltraDesign

/// The Chat tab: which services a Chat pane can talk to, and the keys that let it — or,
/// for the two engines, who is signed in to them.
///
/// Keys go to the keychain the moment the field loses focus; nothing here has an OK
/// button. The engines keep their own sign-in, so their rows only report it and start it.
struct ChatSettings: View {
    @State private var defaultProvider = ChatDefaults.provider
    @State private var anthropicKey = ChatCredentials.apiKey(for: .anthropic)
    @State private var geminiKey = ChatCredentials.apiKey(for: .gemini)
    @State private var openRouterKey = ChatCredentials.apiKey(for: .openRouter)

    var body: some View {
        Form {
            Section {
                Picker("New chats use", selection: $defaultProvider) {
                    ForEach(ChatProviderID.offered) { provider in
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
                EngineRow(engine: .claudeCode)
                EngineRow(engine: .codex)
            } header: {
                Text("Subscriptions")
            } footer: {
                SettingNote("Your Claude or ChatGPT plan, through the vendor's own agent on "
                            + "this Mac: a chat starts `claude` or `codex app-server` in "
                            + "the project and reads what it answers. Ultra never sees a "
                            + "token. Sign-in opens the vendor's page in your browser. The "
                            + "chat can read the project and run read-only commands, not "
                            + "change files.")
            }

            Section {
                keyRow("Anthropic", key: $anthropicKey, provider: .anthropic,
                       placeholder: "sk-ant-…")
                keyRow("Google Gemini", key: $geminiKey, provider: .gemini, placeholder: "AIza…")
                keyRow("OpenRouter", key: $openRouterKey, provider: .openRouter,
                       placeholder: "sk-or-…")
            } header: {
                Text("API keys")
            } footer: {
                SettingNote("Stored in your keychain, never in a file. Each service's own "
                            + "model list is fetched when a pane opens on it. OpenRouter "
                            + "offers many vendors' models — OpenAI's included — behind one "
                            + "key, named vendor/model. Nothing else to set up.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 520)
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

/// One engine: whether it is here, who is signed in, and the one thing to do about
/// either — copy the install command, or start the sign-in.
private struct EngineRow: View {
    let engine: ChatEngine
    @State private var status: Status = .checking
    @State private var isSigningIn = false

    enum Status {
        case checking
        case missing
        case signedOut
        case signedIn(EngineAccount)
        case failed(String)
    }

    var body: some View {
        LabeledContent(engine.title) {
            HStack(spacing: 6) {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .trailing)
                    .help(statusHelp)
                switch status {
                case .checking:
                    ProgressView().controlSize(.small)
                case .missing:
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(engine.installCommand, forType: .string)
                    }
                    .help(engine.installCommand)
                    Button("Check Again") { Task { await refresh() } }
                case .signedOut, .failed:
                    Button(isSigningIn ? "Signing In…" : "Sign In…") { signIn() }
                        .disabled(isSigningIn)
                case .signedIn:
                    Button("Sign In Again…") { signIn() }
                        .disabled(isSigningIn)
                }
            }
        }
        .task(id: engine) { await refresh() }
    }

    private var statusText: String {
        switch status {
        case .checking: "Checking…"
        case .missing: "Not installed"
        case .signedOut: "Not signed in"
        case .signedIn(let account):
            account.description.isEmpty ? "Signed in" : account.description
        case .failed(let reason): reason
        }
    }

    private var statusHelp: String {
        switch status {
        case .missing: "Install with: \(engine.installCommand)"
        case .signedIn(let account): "Signed in to \(engine.planName) as \(account.description)"
        default: statusText
        }
    }

    private func refresh() async {
        // A fresh look for the binary: this is the row the user comes back to after
        // installing it.
        ChatEngine.forgetLocations()
        guard engine.executable != nil else {
            status = .missing
            return
        }
        do {
            status = try await engine.account().map { .signedIn($0) } ?? .signedOut
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func signIn() {
        isSigningIn = true
        Task {
            do {
                try await engine.signIn { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
            } catch {
                status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                isSigningIn = false
                return
            }
            isSigningIn = false
            await refresh()
        }
    }
}
