import BudgetKit
import DesignSystem
import SwiftUI

/// First run on a device: there's no demo ledger outside the simulator, so the app starts here until it
/// reaches a Budget server. Checks the URL and token against the server before saving them.
struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var serverURL = UserDefaults.standard.string(forKey: SettingsKeys.serverURL) ?? ""
    @State private var token = Keychain.string(for: SettingsKeys.apiToken) ?? ""
    @State private var isChecking = false
    @State private var problem: String?

    private var trimmedURL: String { serverURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                Text("budget.")
                    .dsFont(.title)
                    .foregroundStyle(Color.ds.ink)
                    .padding(.top, DSSpace.xl)
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    Text("Connect to your server")
                        .dsFont(.headline)
                        .foregroundStyle(Color.ds.ink)
                    Text("Your ledger lives on your server. Open its dashboard, go to Settings → Connect your phone, and copy the server URL and API token.")
                        .dsFont(.callout)
                        .foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DSCard {
                    VStack(alignment: .leading, spacing: DSSpace.md) {
                        DSField("Server URL", isCode: true, isEmpty: serverURL.isEmpty, onClear: { serverURL = "" }) {
                            TextField("Server URL", text: $serverURL, prompt: Text("https://budget.example.com"))
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .accessibilityIdentifier("connectURL")
                        }
                        DSField("API token", isCode: true) {
                            HStack {
                                SecureField("Token", text: $token)
                                    .accessibilityIdentifier("connectToken")
                                PasteButton(payloadType: String.self) { strings in
                                    if let pasted = strings.first { token = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                                }
                                .labelStyle(.titleOnly)
                                .buttonBorderShape(.capsule)
                            }
                        }
                    }
                }

                if let problem {
                    Text(problem)
                        .dsFont(.callout)
                        .foregroundStyle(Color.ds.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(isChecking ? "Checking…" : "Connect") { Task { await connect() } }
                    .buttonStyle(.ds(.primary, size: .large, fullWidth: true))
                    .disabled(isChecking || trimmedURL.isEmpty || trimmedToken.isEmpty)
            }
            .padding(.horizontal, DSSpace.gutter)
            .padding(.bottom, DSSpace.xxl)
        }
        .dsScreenBackground()
    }

    private func connect() async {
        guard let url = URL(string: trimmedURL), url.scheme?.hasPrefix("http") == true, url.host != nil else {
            problem = "That doesn't look like a URL — it starts with https://."
            return
        }
        isChecking = true
        problem = nil
        defer { isChecking = false }
        do {
            _ = try await RemoteBudgetAPI(baseURL: url, token: trimmedToken).serverStatus()
            UserDefaults.standard.set(trimmedURL, forKey: SettingsKeys.serverURL)
            UserDefaults.standard.set(false, forKey: SettingsKeys.useDemo)
            Keychain.set(trimmedToken, for: SettingsKeys.apiToken)
            app.configure(serverURL: trimmedURL, token: trimmedToken, demo: false)
        } catch let error as BudgetAPIError {
            switch error {
            case .unreachable: problem = "Couldn't reach that server. Check the address."
            case .offline, .timedOut: problem = error.localizedDescription
            case let .server(status, _) where status == 401: problem = "The server refused the token. Copy it again from the dashboard: Settings → Connect your phone."
            case let .server(status, _) where status == 421 || status == 404: problem = "That address isn't the Budget API. Check the URL."
            default: problem = error.localizedDescription
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}
