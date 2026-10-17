import BudgetKit
import DesignSystem
import SwiftUI

/// Changing an account's kind, nickname or last digits, from its row: a pencil that opens `AccountEditSheet`. Shown only
/// when the server keeps account edits (`ServerStatus.accountEditsSince`), and always in the demo.
struct AccountEditButton: View {
    let account: Account

    @Environment(AppModel.self) private var app
    @State private var canEdit = false
    @State private var isEditing = false
    /// What the save says to check (a card with a positive balance) or what went back to review: held while the sheet
    /// is up and shown once it's gone, since the row can't present an alert while it's still presenting the sheet.
    @State private var pendingOutcome: String?
    @State private var outcome: String?

    var body: some View {
        // A ZStack, not a Group: with nothing in it (before the check), a Group is no view at all, so its `.task` never
        // runs and the pencil never shows. An empty ZStack is still there, with no size.
        ZStack {
            if canEdit {
                Button { isEditing = true } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(Color.ds.inkSecondary)
                        .frame(minWidth: DSSize.hitTarget, minHeight: DSSize.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(account.displayName)")
                .accessibilityIdentifier("editAccount")
            }
        }
        .task(id: app.revision) { canEdit = await app.serverSupports(ServerStatus.accountEditsSince) }
        .sheet(isPresented: $isEditing, onDismiss: {
            outcome = pendingOutcome
            pendingOutcome = nil
        }) {
            AccountEditSheet(account: account) { change in
                do {
                    let result = try await app.api.updateAccount(id: account.id, change)
                    await app.didWrite()
                    pendingOutcome = AccountEditSheet.outcome(result)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }
        .alert("Saved", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(outcome ?? "")
        }
    }
}

/// Kind, nickname and last digits for one account. The bank's own name keeps updating underneath a nickname; digits the
/// person sets aren't replaced by a sync. Saving sends only what changed.
struct AccountEditSheet: View {
    let account: Account
    /// Returns nil when it worked; otherwise what went wrong, shown in the sheet, which stays open to try again.
    let onSave: (AccountChange) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var kind: AccountKind = .checking
    @State private var nickname = ""
    @State private var mask = ""
    @State private var isSaving = false
    @State private var failure: String?

    /// The most characters a nickname keeps (the server refuses more).
    static let nicknameLimit = 60

    private var trimmedNickname: String { nickname.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedMask: String { mask.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { trimmedNickname.count > Self.nicknameLimit }
    /// Six or more digits in a row is most likely an account number; the server refuses it in a nickname.
    private var nicknameHasNumber: Bool { trimmedNickname.firstMatch(of: /[0-9]{6,}/) != nil }
    private var nicknameError: String? {
        tooLong ? "Keep it to \(Self.nicknameLimit) characters."
            : nicknameHasNumber ? "Leave the account number out; its last digits go below." : nil
    }
    private var badMask: Bool {
        !trimmedMask.isEmpty && !((2...5).contains(trimmedMask.count) && trimmedMask.allSatisfy { $0.isASCII && $0.isNumber })
    }
    /// A SimpleFIN account's kind is a guess from its name until the person says; saving confirms it even unchanged, which
    /// the Kind footer says.
    private var kindIsGuess: Bool { account.source == .simplefin && account.kindSetByPerson != true }

    /// Only the fields that differ from the account as it is (and the kind, while it's still a guess).
    private var change: AccountChange {
        AccountChange(kind: kind != account.kind || kindIsGuess ? kind : nil,
                      nickname: trimmedNickname != (account.nickname ?? "") ? trimmedNickname : nil,
                      mask: trimmedMask != (account.mask ?? "") ? trimmedMask : nil)
    }
    private var hasChanges: Bool { change != AccountChange() }

    private var bankFooter: String {
        "Your bank calls it “\(account.name)”."
            + (kindIsGuess ? " SimpleFIN doesn't say what kind of account this is, so Budget guessed from its name." : "")
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    // The server's refusal, whichever field it's about (a nickname or the digits).
                    Section {
                        DSNoticeCard("Couldn't save", message: failure).settingsCardRow()
                    }
                }
                DSListSection("Kind", footer: kindFooter) {
                    DSSegmented("Kind", selection: $kind, options: AccountKind.allCases) { $0.shortTitle }
                        .padding(.vertical, DSSpace.xs)
                        .accessibilityIdentifier("accountKind")
                }
                DSListSection("Nickname", footer: bankFooter) {
                    DSField(nil, style: .inline, error: nicknameError,
                            counter: trimmedNickname.isEmpty ? nil : "\(trimmedNickname.count) / \(Self.nicknameLimit)") {
                        TextField(account.name, text: $nickname)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .accessibilityIdentifier("accountNickname")
                    }
                }
                DSListSection("Last digits", footer: "2 to 5 numbers, as on the card or statement. Leave it empty to use what the bank sends.") {
                    DSField(nil, style: .inline, error: badMask ? "Use 2 to 5 numbers, like 0909." : nil) {
                        TextField("0909", text: $mask)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("accountMask")
                    }
                }
            }
            .dsGroupedList()
            .navigationTitle("Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(!hasChanges || nicknameError != nil || badMask || isSaving)
                        .accessibilityIdentifier("saveAccount")
                }
            }
            .onChange(of: change) { failure = nil }
            .announcesProblem(failure)
        }
        .presentationDetents([.large])
        .presentationBackground(Color.ds.canvas)
        .onAppear {
            kind = account.kind
            nickname = account.nickname ?? ""
            mask = account.mask ?? ""
        }
    }

    private var kindFooter: String {
        let counts = switch kind {
        case .credit: "What a card owes is counted as owed, not as cash."
        case .investment: "Counted in net worth only, never as cash."
        case .checking, .savings: "Counted as cash on hand."
        }
        let whose = kindIsGuess ? " Saving confirms the kind, even unchanged."
            : account.kindSetByPerson == true ? " Set by you." : ""
        return counts + whose
    }

    private func save() {
        guard hasChanges, nicknameError == nil, !badMask, !isSaving else { return }
        Task {
            isSaving = true
            failure = await onSave(change)
            isSaving = false
            if failure == nil { dismiss() }
        }
    }

    /// What to tell the person after a save, beyond "saved": something to check, and rows sent back to review.
    static func outcome(_ result: AccountChangeResult) -> String? {
        let review = result.sentToReview == 0 ? nil
            : "\(result.sentToReview) money-in \(result.sentToReview == 1 ? "row" : "rows") filed as Income went back to review."
        let text = [result.warning, review].compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

private extension AccountKind {
    /// A segment's title: short enough that four fit across a phone.
    var shortTitle: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .credit: "Card"
        case .investment: "Investment"
        }
    }
}
