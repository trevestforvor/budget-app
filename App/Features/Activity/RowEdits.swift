import BudgetKit
import DesignSystem
import SwiftUI

/// Row edits from Activity and a transaction's details, each through the one write path (`AppAction` →
/// `perform`) with a toast that says what changed and offers Undo when the ledger gave one back.
@MainActor
struct RowEdits {
    let app: AppModel
    let toast: Binding<DSToastMessage?>

    /// Runs `action`; true when it went through. A refusal or a lost connection becomes the toast.
    @discardableResult
    func run(_ action: AppAction, rule: RuleMatch? = nil, ruleCategory: String? = nil) async -> Bool {
        do {
            try await app.checkServer(for: action)
            let result = try await app.api.perform(action)
            var undo = result.undo.map { [$0] } ?? []
            var message = result.message
            // "Always file these this way": saved after the rows are filed; Undo takes both back.
            if let rule, let ruleCategory {
                do {
                    _ = try await app.api.perform(.createBudgetRule(CreateBudgetRule(match: rule, categoryID: ruleCategory, applyToExisting: false,
                                                                                     createdBy: .person)))
                    if let saved = try? await app.api.rules().first(where: { $0.rule.match.normalized == rule.normalized && $0.rule.categoryID == ruleCategory }) {
                        undo.append(.deleteBudgetRule(DeleteBudgetRule(ruleID: saved.rule.id)))
                    }
                    message += " New ones will be filed the same way."
                } catch {
                    // The rows are filed either way; say the rule didn't take, in the ledger's words.
                    message += " The rule wasn't saved: \(error.localizedDescription)"
                }
            }
            await app.didWrite()
            toast.wrappedValue = undo.isEmpty ? DSToastMessage(message) : .undo(message) { [app, toast] in
                Task { await RowEdits(app: app, toast: toast).revert(undo) }
            }
            return true
        } catch {
            toast.wrappedValue = DSToastMessage(error.localizedDescription)
            return false
        }
    }

    private func revert(_ actions: [AppAction]) async {
        do {
            for action in actions { _ = try await app.api.perform(action) }
            await app.didWrite()
            toast.wrappedValue = DSToastMessage("Put back the way it was.")
        } catch {
            await app.didWrite()
            toast.wrappedValue = DSToastMessage("Couldn't undo that. \(error.localizedDescription)")
        }
    }

    // MARK: - The edits

    @discardableResult
    func file(_ ids: [String], as categoryID: String, rule: RuleMatch? = nil) async -> Bool {
        await run(.editTransactions(EditTransactions(transactionIDs: ids, categoryID: categoryID)), rule: rule, ruleCategory: rule == nil ? nil : categoryID)
    }

    @discardableResult
    func keepGuess(_ ids: [String]) async -> Bool {
        await run(.editTransactions(EditTransactions(transactionIDs: ids, acceptGuess: true)))
    }

    @discardableResult
    func setHidden(_ ids: [String], _ hidden: Bool) async -> Bool {
        await run(.editTransactions(EditTransactions(transactionIDs: ids, isHidden: hidden)))
    }

    @discardableResult
    func setYearly(_ ids: [String], _ yearly: Bool) async -> Bool {
        await run(.editTransactions(EditTransactions(transactionIDs: ids, isYearly: yearly)))
    }

    /// The person's say on a merchant's recurring charges; nil `isRecurring` hands it back to Budget.
    @discardableResult
    func setRecurring(_ merchant: String, _ isRecurring: Bool?, cadence: Subscription.Cadence? = nil, kind: Subscription.Kind? = nil) async -> Bool {
        await run(.setRecurring(SetRecurring(merchant: merchant, isRecurring: isRecurring, cadence: cadence, kind: kind)))
    }

    @discardableResult
    func setNote(_ ids: [String], _ note: String) async -> Bool {
        await run(.editTransactions(EditTransactions(transactionIDs: ids, note: note)))
    }

    @discardableResult
    func rename(_ ids: [String], to merchant: String, similar: Bool) async -> Bool {
        await run(.editTransactions(EditTransactions(transactionIDs: ids, merchant: merchant, renameSimilar: similar ? true : nil)))
    }
}

extension ReviewGroup {
    /// "“Withdrawal” going out of Cash Account ••3321". The rule is only offered for descriptors that name no
    /// merchant — for the rest, answering teaches merchant memory, which already files the next one.
    func scopeDescription(account: Account?) -> String {
        let text = "“\(first.transaction.rawDescription.trimmingCharacters(in: .whitespaces))”"
        let place = account.map { " \(key.isOutflow ? "going out of" : "coming into") \($0.shortLabel)" }
            ?? (key.isOutflow ? " going out" : " coming in")
        return text + place
    }
}
