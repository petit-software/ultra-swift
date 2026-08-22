import SwiftUI
import UltraDesign

/// The Settings window (⌘,).
struct UltraSettings: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettings: View {
    @State private var guardState = SleepGuard.shared

    var body: some View {
        Form {
            Section {
                Toggle("Keep this Mac awake while an agent is running",
                       isOn: Binding(get: { guardState.isEnabled },
                                     set: { guardState.isEnabled = $0 }))
                Text(guardState.statusDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Agents")
            } footer: {
                // Says what it does AND what it cannot do. A setting that quietly fails to
                // deliver what its title implies is worse than no setting.
                Text("""
                     An agent can run for many minutes with nobody touching the keyboard, \
                     so the Mac reaches its idle timeout, sleeps the display and locks. \
                     While an agent is running, Ultra asks the system to stay awake, and \
                     stops asking the moment it finishes.

                     This does not override locking you trigger yourself, closing the lid, \
                     or a policy set by your organisation.
                     """)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
    }
}

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Token.Colour.accent)
                .padding(.top, 22)

            Text("Ultra")
                .font(.system(size: 22, weight: .bold))

            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("A split-pane terminal for working alongside agent CLIs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)

            Divider().padding(.horizontal, 40).padding(.vertical, 4)

            Text("Terminal emulation by SwiftTerm.")
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}
