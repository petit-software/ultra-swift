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
    @State private var openRouterKey = ChatCredentials.apiKey(for: .openRouter)

    var body: some View {
        Form {
            Section {
                Picker("New chats use", selection: $defaultProvider) {
                    ForEach(ChatProviderID.Group.allCases) { group in
                        Section(group.title) {
                            ForEach(group.providers) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }
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
                            + "token. Sign-in opens the vendor's page in your browser. A chat on "
                            + "either can read and change the project's files and run "
                            + "commands there.")
            }

            Section {
                keyRow("Anthropic", key: $anthropicKey, provider: .anthropic,
                       placeholder: "sk-ant-…")
                keyRow("OpenRouter", key: $openRouterKey, provider: .openRouter,
                       placeholder: "sk-or-…")
            } header: {
                Text("API keys")
            } footer: {
                SettingNote("Stored in your keychain, never in a file. Each service's own "
                            + "model list is fetched when a pane opens on it. OpenRouter "
                            + "offers many vendors' models — OpenAI's and Google's included — "
                            + "behind one key, named vendor/model. Nothing else to set up.")
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

/// One engine: whether it is here, who is signed in, and the sign-in itself as it
/// happens — the page is open, approve it there; checking; signed in, just now — so the
/// row says at every step what is going on and what, if anything, is wanted of the user.
private struct EngineRow: View {
    let engine: ChatEngine
    @State private var status: Status = .checking
    @State private var session: EngineSignIn?
    @State private var code = ""
    /// Whether the account shown was just signed in here, for a line saying so. Cleared
    /// after a while, or by the next check.
    @State private var confirmedAt: Date?

    enum Status: Equatable {
        case checking
        case missing
        case signedOut
        case signedIn(EngineAccount)
        case signingIn(EngineSignInState)
        case failed(String)
    }

    var body: some View {
        LabeledContent(engine.title) {
            VStack(alignment: .trailing, spacing: 6) {
                // The buttons beside the account, on one line: what is signed in and
                // what to do about it, read together.
                HStack(spacing: 8) {
                    statusLine
                    buttons
                }
                if case .signingIn(.waitingForBrowser) = status, engine == .claudeCode {
                    codeField
                }
            }
        }
        .task(id: engine) { await refresh() }
        .animation(.default, value: status)
    }

    // MARK: Status

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 5) {
            switch status {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…")
            case .missing:
                Image(systemName: "arrow.down.circle")
                Text("Not installed")
            case .signedOut:
                Image(systemName: "person.crop.circle.badge.xmark")
                Text("Not signed in")
            case .signedIn(let account):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(account.description.isEmpty ? "Signed in" : account.description)
                        .foregroundStyle(.primary)
                    if confirmedAt != nil {
                        Text("Approved in the browser just now")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            case .signingIn(let state):
                ProgressView().controlSize(.small)
                Text(signingInText(state))
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 260, alignment: .trailing)
        .help(statusHelp)
    }

    private func signingInText(_ state: EngineSignInState) -> String {
        switch state {
        case .starting: "Starting \(engine.title)…"
        case .waitingForBrowser: "Approve in the browser — the \(engine.planName) page is open"
        case .verifying: "Approved. Checking with \(engine.title)…"
        case .signedIn, .failed, .cancelled: ""
        }
    }

    private var statusHelp: String {
        switch status {
        case .missing: "Install with: \(engine.installCommand)"
        case .signedIn(let account): "Signed in to \(engine.planName) as \(account.description)"
        case .signingIn: "\(engine.title) runs its own sign-in; Ultra only waits for it to finish"
        default: ""
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            switch status {
            case .checking:
                EmptyView()
            case .missing:
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.installCommand, forType: .string)
                }
                .help(engine.installCommand)
                Button("Check Again") { Task { await refresh() } }
            case .signedOut:
                Button("Sign In…") { signIn() }
            case .signedIn:
                Button("Sign Out") { signOut() }
            case .signingIn(let state):
                if case .waitingForBrowser(let url?) = state {
                    Button("Open Page Again") { NSWorkspace.shared.open(url) }
                }
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
            case .failed:
                Button("Try Again") { signIn() }
                Button("Check Again") { Task { await refresh() } }
            }
        }
        .controlSize(.small)
    }

    /// Claude Code's fallback: when the browser cannot reach its callback it shows a code
    /// instead, and the code goes to the prompt this row is keeping open.
    private var codeField: some View {
        HStack(spacing: 6) {
            TextField("Code, if the browser shows one", text: $code)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(submitCode)
            Button("Use Code", action: submitCode)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
    }

    // MARK: Actions

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
        confirmedAt = nil
        code = ""
        let session = engine.beginSignIn()
        self.session = session
        status = .signingIn(.starting)
        Task {
            for await state in session.states {
                switch state {
                case .signedIn(let account):
                    status = .signedIn(account)
                    confirmedAt = Date()
                    // The confirmation says its piece and goes; the account line stays.
                    try? await Task.sleep(for: .seconds(12))
                    if confirmedAt != nil { confirmedAt = nil }
                case .failed(let reason):
                    status = .failed(reason)
                case .cancelled:
                    await refresh()
                default:
                    status = .signingIn(state)
                }
            }
            self.session = nil
        }
    }

    private func cancel() {
        guard let session else { return }
        Task { await session.cancel() }
    }

    private func submitCode() {
        guard let session else { return }
        let entered = code
        code = ""
        status = .signingIn(.verifying)
        Task { await session.submit(code: entered) }
    }

    private func signOut() {
        confirmedAt = nil
        status = .checking
        Task {
            do {
                try await engine.signOut()
            } catch {
                status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }
            await refresh()
        }
    }
}
