import Foundation

/// Actions against the demo ledger. The real server implements the same two steps:
/// `preview` (ledger-computed effects shown on the proposal card) and `perform` (the change).
extension DemoLedger {
    /// Proposal cards, `BudgetAPI.preview` and the checks `perform` runs first all come from here.
    typealias Preview = ActionPreview

    func preview(_ action: AppAction) throws -> Preview {
        let month = interval(for: .thisMonth)
        switch action {
        case let .setCategoryTarget(p):
            let category = try spendingCategory(p.categoryID)
            let new = p.monthlyAmount.money()
            let spent = spent(from: month.start, to: month.end, categoryID: category.id)
            var effects = [Figure(id: "new", label: "New monthly target", detail: nil, value: new),
                           Figure(id: "spent", label: "Spent this month", detail: nil, value: spent)]
            if let current = monthlyTargets[category.id] {
                effects.insert(Figure(id: "current", label: "Current target", detail: nil, value: current), at: 0)
            }
            return Preview(title: "Set the \(category.name) target to \(new.formatted(fractionDigits: 0)) a month",
                           detail: spent > new ? "You're already past that this month." : nil, effects: effects)

        case let .adjustCategoryTarget(p):
            let category = try spendingCategory(p.categoryID)
            let current = monthlyTargets[category.id] ?? .zero
            let change = p.change.money()
            let new = current + change
            guard !new.isNegative else { throw BudgetAPIError.rejected("That would take the \(category.name) target below zero.") }
            return Preview(title: "\(change.isNegative ? "Lower" : "Raise") the \(category.name) target by \(change.magnitude.formatted(fractionDigits: 0))",
                           detail: monthlyTargets[category.id] == nil ? "\(category.name) has no target yet, so this starts from zero." : nil,
                           effects: [Figure(id: "current", label: "Current target", detail: nil, value: current),
                                     Figure(id: "change", label: "Change", detail: nil, value: change),
                                     Figure(id: "new", label: "New monthly target", detail: nil, value: new)])

        case let .removeCategoryTarget(p):
            let category = try spendingCategory(p.categoryID)
            guard let current = monthlyTargets[category.id] else { throw BudgetAPIError.rejected("\(category.name) doesn't have a target.") }
            return Preview(title: "Remove the \(category.name) target", detail: "Spending is still tracked; it just won't count against a plan.",
                           effects: [Figure(id: "current", label: "Current target", detail: nil, value: current),
                                     Figure(id: "spent", label: "Spent this month", detail: nil, value: spent(from: month.start, to: month.end, categoryID: category.id))])

        case let .setMerchantTarget(p):
            let merchant = try knownMerchant(p.merchant)
            let new = p.monthlyAmount.money()
            let thisMonth = merchantSpend(merchant, from: month.start, to: month.end).total
            let average = merchantMonthlyAverage(merchant)
            var effects = [Figure(id: "new", label: "New monthly cap", detail: nil, value: new),
                           Figure(id: "spent", label: "Spent this month", detail: nil, value: thisMonth),
                           Figure(id: "average", label: "3-month average", detail: nil, value: average)]
            if let current = merchantTargets[merchant] { effects.insert(Figure(id: "current", label: "Current cap", detail: nil, value: current), at: 0) }
            return Preview(title: "Cap \(merchant) at \(new.formatted(fractionDigits: 0)) a month",
                           detail: thisMonth > new ? "You're already past that this month." : "Spending past the cap is flagged, never blocked.", effects: effects)

        case let .setMonthlySavings(p):
            let new = p.monthlyAmount.money()
            let flex = flexBudget()
            var next = self
            next.monthlySavings = new
            let after = next.flexBudget()
            return Preview(title: "Set aside \(new.formatted(fractionDigits: 0)) a month, first",
                           detail: after.safeToSpend.isNegative ? "That leaves less flexible money than you've already spent this month." : nil,
                           effects: [Figure(id: "current", label: flex.plannedSavingsIsSet ? "Current plan" : "Saving now (detected)", detail: nil, value: flex.plannedSavings),
                                     Figure(id: "new", label: "New monthly savings", detail: nil, value: new),
                                     Figure(id: "flex", label: "Flex number after", detail: nil, value: after.flexNumber),
                                     Figure(id: "safe", label: "Safe to spend this month after", detail: nil, value: after.safeToSpend)])

        case let .removeMerchantTarget(p):
            let merchant = try knownMerchant(p.merchant)
            guard let current = merchantTargets[merchant] else { throw BudgetAPIError.rejected("\(merchant) doesn't have a cap.") }
            return Preview(title: "Remove the \(merchant) cap", detail: nil,
                           effects: [Figure(id: "current", label: "Current cap", detail: nil, value: current)])

        case let .createCategory(p):
            let (name, archived) = try newCategory(p)
            let target = p.monthlyTarget.map { [Figure(id: "target", label: "Monthly target", detail: nil, value: $0.money())] } ?? []
            if let archived {
                return Preview(title: "Bring back \(categories[archived].name)", detail: "It was merged into another category. New transactions can be filed under it again.", effects: target)
            }
            if p.kind == .moneyIn {
                return Preview(title: "Add a \(name) category", detail: "Counts as money coming in, like income: never spending, never budgeted.")
            }
            let group = p.group ?? .everyday
            let notes = [p.monthlyTarget == nil ? "No target yet." : nil, group == .everyday ? nil : "Budgeted as \(group.label.lowercased()): \(Self.groupEffect(group))"]
                .compactMap { $0 }
            return Preview(title: "Add a \(name) category", detail: notes.isEmpty ? nil : notes.joined(separator: " "), effects: target)

        case let .updateCategory(p):
            let (index, updated) = try updatedCategory(p)
            let old = categories[index]
            var changes: [String] = []
            if updated.symbol != old.symbol { changes.append("icon") }
            if updated.color != old.color { changes.append("color") }
            if updated.group != old.group { changes.append("budget type") }
            let title = updated.name != old.name
                ? "Rename \(old.name) to \(updated.name)" + (changes.isEmpty ? "" : " and change its \(changes.spokenList)")
                : "Change \(old.name)'s \(changes.spokenList)"
            guard updated.group != old.group else { return Preview(title: title) }
            var next = self
            next.categories[index] = updated
            return Preview(title: title, detail: "\(updated.name) becomes \(updated.group.label.lowercased()): \(Self.groupEffect(updated.group))",
                           effects: [Figure(id: "safe-now", label: "Safe to spend now", detail: nil, value: flexBudget().safeToSpend),
                                     Figure(id: "safe-after", label: "Safe to spend after", detail: nil, value: next.flexBudget().safeToSpend)])

        case let .mergeCategory(p):
            let plan = try mergePlan(p)
            let (from, into) = (categories[plan.from], categories[plan.into])
            let rows = plan.rows.map { transactions[$0] }
            var notes = ["Moves \(rows.count == 1 ? "1 transaction" : "\(rows.count) transactions")\(plan.rules.isEmpty ? "" : " and \(plan.rules.count == 1 ? "1 rule" : "\(plan.rules.count) rules")") to \(into.name)."]
            var effects: [Figure] = []
            if let target = monthlyTargets[from.id] {
                if p.combineTargets == true {
                    let after = (monthlyTargets[into.id] ?? .zero) + target
                    notes.append("Its \(target.formatted(fractionDigits: 0)) target is added to \(into.name)'s.")
                    effects.append(Figure(id: "target", label: "\(into.name) target after", detail: nil, value: after))
                } else {
                    notes.append("Its \(target.formatted(fractionDigits: 0)) target is dropped.")
                }
            }
            if into.countsAsSpending, from.group != into.group {
                // Its spending changes budget type with it, so safe to spend moves (as a budget-type change shows).
                var next = self
                next.applyMerge(plan, combineTargets: p.combineTargets == true)
                notes.append("\(into.name) is budgeted as \(into.group.label.lowercased()), so \(from.name)'s spending counts that way and safe to spend changes.")
                effects += [Figure(id: "safe-now", label: "Safe to spend now", detail: nil, value: flexBudget().safeToSpend),
                            Figure(id: "safe-after", label: "Safe to spend after", detail: nil, value: next.flexBudget().safeToSpend)]
            }
            notes.append(Self.isStandard(from) ? "\(from.name) is archived, so it won't come back." : "\(from.name) is removed.")
            return Preview(title: "Merge \(from.name) into \(into.name)", detail: notes.joined(separator: " "), effects: effects,
                           sample: Array(rows.prefix(Preview.sampleSize)), matchCount: rows.count, changeCount: rows.count)

        case let .createBudgetRule(p):
            let category = try activeCategory(p.categoryID)
            let rule = BudgetRule(id: BudgetRule.nextID(after: rules, stampedOn: transactions), match: try validatedMatch(p.match, categoryID: category.id), categoryID: category.id)
            return rulePreview(rule, in: rules + [rule], title: "Always file \(ruleSubject(rule.match)) under \(category.name)", applyToExisting: p.applyToExisting)

        case let .updateBudgetRule(p):
            let (index, rule) = try updatedRule(p)
            let old = rules[index]
            let name = category(rule.categoryID)?.name ?? "a category that's gone"
            var list = rules
            list[index] = rule
            let title = rule.isEnabled == old.isEnabled || rule.match != old.match || rule.categoryID != old.categoryID
                ? "Always file \(ruleSubject(rule.match)) under \(name)"
                : rule.isEnabled ? "Start filing \(ruleSubject(rule.match)) under \(name) again" : "Stop filing \(ruleSubject(rule.match)) under \(name)"
            var preview = rulePreview(rule, in: list, title: title, applyToExisting: p.applyToExisting == true)
            if !rule.isEnabled { preview.detail = "It files nothing while it's off. The transactions it filed keep their category." }
            return preview

        case let .deleteBudgetRule(p):
            guard let rule = rules.first(where: { $0.id == p.ruleID }) else { throw BudgetAPIError.notFound }
            let filed = transactions.filter { $0.categorization?.ruleID == rule.id }
            let name = category(rule.categoryID)?.name ?? "a category that's gone"
            return Preview(title: "Delete the rule filing \(ruleSubject(rule.match)) under \(name)",
                           detail: filed.isEmpty ? "It hasn't filed any transactions." : "The \(filed.count == 1 ? "transaction" : "\(filed.count) transactions") it filed keep\(filed.count == 1 ? "s" : "") \(filed.count == 1 ? "its" : "their") category.",
                           sample: Array(filed.prefix(Preview.sampleSize)), matchCount: filed.count, changeCount: 0)

        case let .recategorize(p):
            let category = try activeCategory(p.categoryID)
            let rows = try p.transactionIDs.map { id in
                guard let row = transactions.first(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
                return row
            }
            return Preview(title: "File \(rows.count) transaction\(rows.count == 1 ? "" : "s") under \(category.name)",
                           detail: Self.merchantList(rows), effects: [], sample: Array(rows.prefix(Preview.sampleSize)), matchCount: rows.count,
                           changeCount: rows.filter { $0.categorization?.categoryID != category.id }.count)

        case let .editTransactions(p):
            return editPreview(try editPlan(p))

        case let .restoreTransactions(p):
            guard !p.rows.isEmpty || !(p.aliases ?? []).isEmpty || !(p.caps ?? []).isEmpty || !(p.forgotten ?? []).isEmpty else {
                throw BudgetAPIError.rejected("Nothing to undo.")
            }
            for id in p.rows.compactMap(\.categorization?.categoryID) { _ = try anyCategory(id) }
            return Preview(title: "Undo the last change",
                           detail: p.rows.isEmpty ? nil : "Puts \(p.rows.count == 1 ? "1 transaction" : "\(p.rows.count) transactions") back as \(p.rows.count == 1 ? "it was" : "they were").",
                           effects: [])

        case let .updateDecisionPolicy(p):
            guard !p.isEmpty else { throw BudgetAPIError.rejected("Nothing to change.") }
            if let percent = p.autoAcceptPercent, !DecisionPolicy.allowedPercents.contains(percent) {
                throw BudgetAPIError.rejected("The auto-accept threshold must be between \(DecisionPolicy.allowedPercents.lowerBound)% and \(DecisionPolicy.allowedPercents.upperBound)%.")
            }
            if let amount = p.reviewAbove, amount.minorUnits < 0 { throw BudgetAPIError.rejected("The amount to check above can't be negative.") }
            let next = p.applied(to: decisionPolicy)
            var notes: [String] = []
            if next.usesJev {
                notes.append("Jev receives the merchant, a cleaned descriptor and an amount band for each \(next.provider == .jev ? "" : "escalated ")transaction — no names, accounts, dates or exact amounts.")
            }
            if next.reviewNewMerchants != decisionPolicy.reviewNewMerchants {
                notes.append(next.reviewNewMerchants ? "New merchants come to you before they're filed." : "The decision model files new merchants it's sure about.")
            }
            if next.reviewAbove != decisionPolicy.reviewAbove {
                notes.append(next.reviewAbove.map { "Anything over \($0.money().formatted(fractionDigits: 0)) that a rule doesn't cover comes to you." }
                             ?? "Big amounts are filed on their own again.")
            }
            if next.holdPending != decisionPolicy.holdPending {
                notes.append(next.holdPending ? "Pending charges wait until they post before they come to you." : "Pending charges come to you right away.")
            }
            // Re-checking uses the policy's queue, so count it under the new settings.
            var after = self
            after.decisionPolicy = next
            let pending = after.reviewItems.count
            if next.isActive, p.reruns, pending > 0 {
                notes.append("Re-checks the \(pending) transaction\(pending == 1 ? "" : "s") waiting for review.")
            }
            let escalation = next.provider.runsLocally && next.escalateToJev ? ", unsure ones to Jev" : ""
            let title = !p.changesModel && !p.reruns ? "Change what comes to you for review"
                : next.isActive ? "Decide with \(next.provider.displayName)\(escalation), auto-accept at \(next.autoAcceptPercent)%+" : "Turn off the decision model"
            return Preview(title: title, detail: notes.isEmpty ? nil : notes.joined(separator: " "), effects: [])

        case let .forgetMerchant(p):
            let (entry, rows) = try forgetPlan(p)
            return Preview(title: "Forget \(entry.merchant)",
                           detail: "New \(entry.merchant) transactions are decided afresh until you file one yourself. The \(rows.count == 1 ? "past one keeps its" : "\(rows.count) past ones keep their") category.",
                           sample: Array(rows.prefix(Preview.sampleSize)), matchCount: rows.count, changeCount: 0)

        case let .setRecurring(p):
            let plan = try recurringPlan(p)
            let things = plan.rows.count == 1 ? "Its transaction keeps its" : "Its \(plan.rows.count) transactions keep their"
            switch plan.next {
            case nil:
                return Preview(title: "Let Budget decide whether \(plan.merchant) recurs", detail: "\(things) category.",
                               sample: Array(plan.rows.prefix(Preview.sampleSize)), matchCount: plan.rows.count, changeCount: 0)
            case let next? where !next.isRecurring:
                return Preview(title: "Take \(plan.merchant) off recurring",
                               detail: "It won't be expected or counted as a yearly charge. \(things) category.",
                               sample: Array(plan.rows.prefix(Preview.sampleSize)), matchCount: plan.rows.count, changeCount: 0)
            case let next?:
                let how = [next.cadence.map(\.every), next.kind.map { "as a \($0.rawValue)" }].compactMap { $0 }.joined(separator: ", ")
                let yearly = next.cadence == .yearly ? " Its charges count a twelfth a month for a year." : ""
                return Preview(title: "\(plan.merchant) repeats \(how)", detail: "\(things) category.\(yearly)",
                               sample: Array(plan.rows.prefix(Preview.sampleSize)), matchCount: plan.rows.count, changeCount: 0)
            }

        case let .reviewRecurring(p):
            return try reviewRecurringPreview(p)

        case let .navigate(p):
            let month = p.month.flatMap(monthStart).map { " · \($0.formatted(Self.monthStyle(calendar)))" }
            let focus = p.categoryID.flatMap(category).map { " · \($0.name)" } ?? month ?? p.search.map { " · “\($0)”" } ?? ""
            return Preview(title: "Open \(p.screen.rawValue.capitalized)\(focus)", detail: nil, effects: [])
        }
    }

    mutating func perform(_ action: AppAction) throws -> ActionResult {
        let preview = try preview(action) // same validation as the proposal
        _ = preview
        switch action {
        case let .setCategoryTarget(p):
            let category = try spendingCategory(p.categoryID)
            monthlyTargets[category.id] = p.monthlyAmount.money()
            return ActionResult(message: "\(category.name) target is now \(p.monthlyAmount.money().formatted(fractionDigits: 0)) a month.")

        case let .adjustCategoryTarget(p):
            let category = try spendingCategory(p.categoryID)
            let new = (monthlyTargets[category.id] ?? .zero) + p.change.money()
            monthlyTargets[category.id] = new
            return ActionResult(message: "\(category.name) target is now \(new.formatted(fractionDigits: 0)) a month.")

        case let .removeCategoryTarget(p):
            let category = try spendingCategory(p.categoryID)
            monthlyTargets[category.id] = nil
            return ActionResult(message: "Removed the \(category.name) target.")

        case let .setMerchantTarget(p):
            let merchant = try knownMerchant(p.merchant)
            merchantTargets[merchant] = p.monthlyAmount.money()
            return ActionResult(message: "\(merchant) is capped at \(p.monthlyAmount.money().formatted(fractionDigits: 0)) a month.")

        case let .setMonthlySavings(p):
            monthlySavings = p.monthlyAmount.money()
            return ActionResult(message: "You'll set aside \(p.monthlyAmount.money().formatted(fractionDigits: 0)) a month first. Safe to spend is now \(flexBudget().safeToSpend.formatted(fractionDigits: 0)).")

        case let .removeMerchantTarget(p):
            let merchant = try knownMerchant(p.merchant)
            merchantTargets[merchant] = nil
            return ActionResult(message: "Removed the \(merchant) cap.")

        case let .createCategory(p):
            let (name, archived) = try newCategory(p)
            let id: String
            if let archived {
                categories[archived].isArchived = false
                categories[archived].mergedInto = nil
                if let symbol = p.symbol { categories[archived].symbol = symbol }
                if let color = p.color { categories[archived].color = color }
                if let group = p.group, categories[archived].countsAsSpending { categories[archived].group = group }
                id = categories[archived].id
            } else {
                let kind = p.kind ?? .spending
                // Money in isn't budgeted, so a budget type given for it is left out.
                let category = BudgetCategory(id: Self.slug(name), name: name, symbol: p.symbol ?? (kind == .moneyIn ? "arrow.down.circle" : "tag"),
                                              group: kind == .moneyIn ? .everyday : p.group ?? .everyday,
                                              color: p.color ?? leastUsedColor().rawValue, kind: kind)
                // Spending before the rest; money in after Income (and the money-in categories made before it); Transfer last.
                let index = kind == .moneyIn ? categories.lastIndex(where: \.isMoneyIn).map { $0 + 1 } : categories.firstIndex { !$0.countsAsSpending }
                categories.insert(category, at: index ?? categories.firstIndex { !$0.countsAsSpending } ?? categories.endIndex)
                id = category.id
            }
            if let target = p.monthlyTarget { monthlyTargets[id] = target.money() }
            return ActionResult(message: archived == nil ? "Added \(name)." : "Brought back \(category(id)?.name ?? name).")

        case let .updateCategory(p):
            let (index, updated) = try updatedCategory(p)
            let old = categories[index]
            categories[index] = updated
            return ActionResult(message: updated.name != old.name ? "Renamed \(old.name) to \(updated.name)." : "Saved \(updated.name).")

        case let .mergeCategory(p):
            let plan = try mergePlan(p)
            let (from, into) = (categories[plan.from], categories[plan.into])
            applyMerge(plan, combineTargets: p.combineTargets == true)
            let moved = [plan.rows.count == 1 ? "1 transaction" : "\(plan.rows.count) transactions",
                         plan.rules.isEmpty ? nil : plan.rules.count == 1 ? "1 rule" : "\(plan.rules.count) rules"].compactMap { $0 }
            return ActionResult(message: "Merged \(from.name) into \(into.name): moved \(moved.spokenList).", affectedTransactions: plan.rows.count)

        case let .createBudgetRule(p):
            let category = try activeCategory(p.categoryID)
            let rule = BudgetRule(id: BudgetRule.nextID(after: rules, stampedOn: transactions), match: try validatedMatch(p.match, categoryID: category.id), categoryID: category.id,
                                  createdAt: now, createdBy: p.createdBy ?? .person)
            rules.append(rule)
            let changed = p.applyToExisting ? refile(with: rule) : 0
            return ActionResult(message: changed > 0 ? "Rule saved. Filed \(changed) transaction\(changed == 1 ? "" : "s") under \(category.name)." : "Rule saved.",
                                affectedTransactions: changed)

        case let .updateBudgetRule(p):
            let (index, rule) = try updatedRule(p)
            let wasOn = rules[index].isEnabled
            rules[index] = rule
            let changed = p.applyToExisting == true ? refile(with: rule) : 0
            let name = category(rule.categoryID)?.name ?? "its category"
            let message = !rule.isEnabled ? "Rule turned off. The transactions it filed keep their category."
                : changed > 0 ? "Rule saved. Filed \(changed) transaction\(changed == 1 ? "" : "s") under \(name)."
                : wasOn ? "Rule saved." : "Rule turned on."
            return ActionResult(message: message, affectedTransactions: changed)

        case let .deleteBudgetRule(p):
            guard let index = rules.firstIndex(where: { $0.id == p.ruleID }) else { throw BudgetAPIError.notFound }
            let filed = transactions.filter { $0.categorization?.ruleID == p.ruleID }.count
            rules.remove(at: index)
            return ActionResult(message: filed == 0 ? "Rule deleted." : "Rule deleted. The \(filed == 1 ? "transaction it filed keeps its" : "\(filed) transactions it filed keep their") category.")

        case let .recategorize(p):
            let ids = Set(p.transactionIDs)
            let indices = transactions.indices.filter { ids.contains(transactions[$0].id) }
            let undo = restoring(indices)
            for index in indices { file(index, under: p.categoryID) }
            return ActionResult(message: "Re-filed \(indices.count) transaction\(indices.count == 1 ? "" : "s").",
                                affectedTransactions: indices.count, undo: undo)

        case let .editTransactions(p):
            let plan = try editPlan(p)
            return apply(plan)

        case let .restoreTransactions(p):
            let index = Dictionary(transactions.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            var restored = 0
            // Rows that have since left the ledger (rolled back, removed by the provider) are skipped.
            for row in p.rows {
                guard let i = index[row.transactionID] else { continue }
                transactions[i].merchant = row.merchant
                transactions[i].originalMerchant = row.originalMerchant
                transactions[i].categorization = row.categorization
                // A category merged away since the change files the row where its rows went.
                if let id = row.categorization?.categoryID, case let target = mergeTarget(id), target != id {
                    transactions[i].categorization?.categoryID = target
                }
                transactions[i].isHidden = row.isHidden
                transactions[i].note = row.note
                transactions[i].transferPeerID = row.transferPeerID
                transactions[i].isYearly = row.isYearly
                suggestions[row.transactionID] = row.suggestions
                restored += 1
            }
            for alias in p.aliases ?? [] { merchantAliases[alias.descriptor] = alias.merchant }
            for cap in p.caps ?? [] { merchantTargets[cap.merchant] = cap.monthlyAmount?.money() }
            forgottenMerchants.formUnion(p.forgotten ?? [])
            for recurring in p.recurring ?? [] { recurringChoices[recurring.key] = recurring.choice }
            return ActionResult(message: "Undone.", affectedTransactions: restored)

        case let .updateDecisionPolicy(p):
            let previous = decisionPolicy
            decisionPolicy = p.applied(to: decisionPolicy)
            // Rows waiting because the model couldn't be reached aren't sent to a different model (or kept waiting for one
            // that's now off) unless the person asked for the queue to be re-checked. A threshold change keeps them waiting.
            if !p.reruns, previous.provider != decisionPolicy.provider || previous.isActive != decisionPolicy.isActive { releaseAwaitingModel() }
            guard p.changesModel || p.reruns else { return ActionResult(message: "Review settings saved.") }
            return ActionResult(message: decisionPolicy.isActive
                ? "Decision model set to \(decisionPolicy.provider.displayName)\(decisionPolicy.provider.runsLocally && decisionPolicy.escalateToJev ? " with Jev for unsure ones" : ""), auto-accepting at \(decisionPolicy.autoAcceptPercent)%+."
                : "Decision model is off. Uncertain transactions come to you.")

        case let .forgetMerchant(p):
            let (entry, _) = try forgetPlan(p)
            forgottenMerchants.insert(entry.descriptor)
            return ActionResult(message: "Forgot \(entry.merchant). Past transactions keep their category.")

        case let .setRecurring(p):
            let plan = try recurringPlan(p)
            let undo = AppAction.setRecurring(plan.previous.map {
                SetRecurring(merchant: $0.merchant, isRecurring: $0.isRecurring, cadence: $0.cadence, kind: $0.kind,
                             amount: $0.amount.map(DecimalAmount.init), restores: true)
            } ?? SetRecurring(merchant: plan.merchant, isRecurring: nil, restores: true))
            recurringChoices[plan.key] = plan.next
            let message = switch plan.next {
            case nil: "Budget decides whether \(plan.merchant) recurs again."
            case let next? where !next.isRecurring: "Took \(plan.merchant) off recurring."
            case let next?: "\(plan.merchant) repeats \([next.cadence.map(\.every), next.kind.map { "as a \($0.rawValue)" }].compactMap { $0 }.joined(separator: ", "))."
            }
            return ActionResult(message: message, affectedTransactions: 0, undo: undo)

        case let .reviewRecurring(p):
            return try performReviewRecurring(p)

        case .navigate:
            throw BudgetAPIError.rejected("Navigation is handled on the device.")
        }
    }

    /// What a recurring choice changes, worked out once for its preview and for the change itself.
    struct RecurringPlan {
        var key: String
        /// The merchant as its rows show it.
        var merchant: String
        var previous: RecurringChoice?
        /// Nil: the choice is removed, and Budget decides again.
        var next: RecurringChoice?
        /// The merchant's money out, newest first.
        var rows: [LedgerTransaction]
    }

    func recurringPlan(_ p: SetRecurring) throws -> RecurringPlan {
        let key = RecurringChoice.key(p.merchant)
        guard !key.isEmpty else { throw BudgetAPIError.rejected("Choose a merchant.") }
        let rows = transactions.filter { RecurringChoice.key($0.merchant) == key && $0.amount.isNegative }
        let previous = recurringChoices[key]
        // An undo puts the choice back exactly, even for a merchant whose rows have since gone.
        if p.restores == true {
            let merchant = rows.first?.merchant ?? p.merchant
            let next = p.isRecurring.map { RecurringChoice(merchant: merchant, isRecurring: $0, cadence: p.cadence, kind: p.kind, amount: p.amount?.money()) }
            return RecurringPlan(key: key, merchant: merchant, previous: previous, next: next, rows: rows)
        }
        guard let merchant = rows.first?.merchant else { throw BudgetAPIError.rejected("No charges from \(p.merchant.trimmingCharacters(in: .whitespaces)) to go on.") }
        var next: RecurringChoice?
        switch p.isRecurring {
        case nil: next = nil
        case false?: next = RecurringChoice(merchant: merchant, isRecurring: false)
        case true?:
            let cadence = p.cadence ?? previous?.cadence
            let found = recurringSeries().contains { RecurringChoice.key($0.merchant) == key }
            guard cadence != nil || found else { throw BudgetAPIError.rejected("Say how often \(merchant) repeats.") }
            guard p.cadence != nil || p.kind != nil else { throw BudgetAPIError.rejected("Say how often \(merchant) repeats, or whether it's a bill.") }
            // With a cadence, the charge that recurs: the one given, the one it had, else the latest.
            let amount = cadence == nil ? nil : p.amount?.money() ?? previous?.amount ?? rows.first?.amount.magnitude
            next = RecurringChoice(merchant: merchant, isRecurring: true, cadence: cadence, kind: p.kind ?? previous?.kind, amount: amount)
        }
        return RecurringPlan(key: key, merchant: merchant, previous: previous, next: next, rows: rows)
    }

    /// Applies decision-model answers to rows waiting for review.
    /// Returns (auto-accepted, still pending).
    /// `agreed` files a row under the category the model and the bank's own label agree on, even below the bar.
    /// The review toggles hold back what would be filed: new merchants, when asked, and big amounts. As at ingest,
    /// money going out is never filed as money in (that answer goes to review with transfer first), and money coming
    /// in on a card never as Income (review, with the card's honest suggestions).
    mutating func applyDecisions(_ answers: [(transactionID: String, answer: DecisionAnswer?, label: String)],
                                 agreed: [String: String] = [:]) -> (accepted: Int, pending: Int) {
        let known = Set(activeCategories.map(\.id))
        var accepted = 0, pending = 0
        for (id, given, label) in answers {
            guard let index = transactions.firstIndex(where: { $0.id == id }) else { continue }
            let row = transactions[index]
            // The model answered this time, so a "couldn't be reached" note no longer applies.
            if reviewReasons[id] == Categorizer.modelUnreachableReason { reviewReasons[id] = Categorizer.reviewReason(for: row, modelIsOn: true) }
            let (answer, held) = Categorizer.guarded(given, for: row, in: self)
            var filed: (categoryID: String, confidence: Double, label: String)?
            var ranked: [CategorySuggestion] = []
            if let pick = agreed[id], !(isMoneyIn(pick) && row.amount.isNegative), !(pick == BudgetCategory.incomeID && isCardCredit(row)) {
                filed = (pick, answer?.confidence ?? Categorizer.agreementFloor, "\(label) · agrees with the bank")
            } else {
                switch CategoryDecisions.outcome(answer, policy: decisionPolicy, knownCategoryIDs: known) {
                case let .accept(categoryID, confidence): filed = (categoryID, confidence, label)
                case let .review(suggestions): ranked = suggestions
                }
            }
            if let filed {
                guard let reason = decisionPolicy.reviewReason(for: transactions[index], newMerchant: true) else {
                    transactions[index].categorization = Categorization(categoryID: filed.categoryID, confidence: filed.confidence, tier: .decisionModel,
                                                                        needsReview: false, decidedBy: filed.label)
                    suggestions[id] = nil
                    reviewReasons[id] = nil
                    accepted += 1
                    continue
                }
                ranked = CategoryDecisions.suggestions(leadingWith: CategorySuggestion(categoryID: filed.categoryID, confidence: filed.confidence),
                                                       answer, knownCategoryIDs: known)
                reviewReasons[id] = reason
            }
            if let held {
                Categorizer.guardSuggestions(&ranked, held: held, for: row, in: self, known: known)
                reviewReasons[id] = held.reason
            }
            ranked = Categorizer.offerable(ranked, for: row, in: self)
            if let best = ranked.first {
                transactions[index].categorization = Categorization(categoryID: best.categoryID, confidence: best.confidence, tier: .decisionModel,
                                                                    needsReview: true, decidedBy: filed?.label ?? label)
                suggestions[id] = ranked
            }
            pending += 1
        }
        return (accepted, pending)
    }

    // MARK: Editing rows

    /// What an edit touches, worked out once for its preview and for the change itself.
    struct EditPlan {
        /// The chosen rows (indices into `transactions`), each once, in the order given.
        var rows: [Int]
        var category: BudgetCategory?
        /// Keep what each row is filed as, as the person's answer.
        var keep: Bool
        var isHidden: Bool?
        var isYearly: Bool?
        var changesNote: Bool
        /// The note as it's stored; nil removes it.
        var note: String?
        var merchant: String?
        /// Every row the rename reaches: the chosen ones, plus rows sharing their descriptor with `renameSimilar`.
        var renamed: [Int]
        /// Descriptors whose new rows get the new name.
        var aliases: [String]
        /// Merchant caps that follow the rename (every row under the old name is renamed).
        var capMoves: [(from: String, to: String)]
        /// Recurring choices that follow the rename, the same way.
        var recurringMoves: [(from: String, to: String)] = []
        /// A chosen row's generic descriptor ("Withdrawal"): renamed on its own, no alias.
        var genericDescriptor: String?
    }

    func editPlan(_ p: EditTransactions) throws -> EditPlan {
        guard !p.transactionIDs.isEmpty else { throw BudgetAPIError.rejected("Choose at least one transaction.") }
        let index = Dictionary(transactions.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let rows = try p.transactionIDs.filter { seen.insert($0).inserted }.map { id in
            guard let i = index[id] else { throw BudgetAPIError.notFound }
            return i
        }
        let category = try p.categoryID.map(activeCategory)
        let keep = p.acceptGuess == true
        if category != nil, keep { throw BudgetAPIError.rejected("Choose a category or keep the one it has, not both.") }
        if keep, let unfiled = rows.first(where: { keptCategory(transactions[$0]) == nil }) {
            throw BudgetAPIError.rejected("\(transactions[unfiled].merchant) isn't filed yet, so there's nothing to keep.")
        }
        let merchant = p.merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let merchant, merchant.isEmpty { throw BudgetAPIError.rejected("A merchant needs a name.") }
        if let merchant, merchant.count > 60 { throw BudgetAPIError.rejected("Keep the merchant name to 60 characters.") }
        if p.renameSimilar == true, merchant == nil { throw BudgetAPIError.rejected("Renaming similar transactions needs the new name.") }
        let note = p.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note, note.count > 500 { throw BudgetAPIError.rejected("Keep the note to 500 characters.") }
        guard category != nil || keep || p.isHidden != nil || p.isYearly != nil || note != nil || merchant != nil else {
            throw BudgetAPIError.rejected("Nothing to change.")
        }

        var renamed = rows, aliases: [String] = [], capMoves: [(from: String, to: String)] = [], recurringMoves: [(from: String, to: String)] = []
        let generic = rows.map { transactions[$0].rawDescription }.first(where: Descriptor.isGeneric)
        if let merchant {
            if p.renameSimilar == true {
                // Like merchant memory: a descriptor that names no merchant can't carry a name to other rows.
                let descriptors = Set(rows.map { transactions[$0].rawDescription }.filter { !Descriptor.isGeneric($0) }.map(Descriptor.normalize))
                let chosen = Set(rows)
                renamed += transactions.indices.filter { !chosen.contains($0) && descriptors.contains(Descriptor.normalize(transactions[$0].rawDescription)) }
                aliases = descriptors.sorted()
            }
            // A cap is kept by merchant name, so it moves when every row under the old name gets the new one.
            let reached = Set(renamed)
            for old in Set(renamed.map { transactions[$0].merchant }).sorted() where old != merchant {
                guard let cap = merchantTargets.keys.first(where: { $0.caseInsensitiveCompare(old) == .orderedSame }),
                      !merchantTargets.keys.contains(where: { $0.caseInsensitiveCompare(merchant) == .orderedSame }), capMoves.isEmpty,
                      !transactions.indices.contains(where: { !reached.contains($0) && transactions[$0].merchant.caseInsensitiveCompare(old) == .orderedSame })
                else { continue }
                capMoves.append((cap, merchant))
            }
            // So does the person's say on whether the merchant recurs.
            let newKey = RecurringChoice.key(merchant)
            for old in Set(renamed.map { transactions[$0].merchant }).sorted() where RecurringChoice.key(old) != newKey {
                let oldKey = RecurringChoice.key(old)
                guard recurringChoices[oldKey] != nil, recurringChoices[newKey] == nil, !recurringMoves.contains(where: { RecurringChoice.key($0.from) == oldKey }),
                      !transactions.indices.contains(where: { !reached.contains($0) && RecurringChoice.key(transactions[$0].merchant) == oldKey })
                else { continue }
                recurringMoves.append((old, merchant))
            }
        }
        return EditPlan(rows: rows, category: category, keep: keep, isHidden: p.isHidden, isYearly: p.isYearly, changesNote: note != nil,
                        note: note.flatMap { $0.isEmpty ? nil : $0 }, merchant: merchant, renamed: renamed, aliases: aliases,
                        capMoves: capMoves, recurringMoves: recurringMoves, genericDescriptor: p.renameSimilar == true ? generic : nil)
    }

    /// The category "keep" files a row under: what it's filed as, else the top suggestion.
    func keptCategory(_ row: LedgerTransaction) -> String? {
        row.categorization?.categoryID ?? suggestions[row.id]?.first?.categoryID
    }

    func editPreview(_ plan: EditPlan) -> Preview {
        let rows = plan.rows.map { transactions[$0] }
        let things = rows.count == 1 ? "1 transaction" : "\(rows.count) transactions"
        var titles: [String] = [], changes: [String] = []
        if let category = plan.category {
            titles.append("File \(things) under \(category.name)")
            changes.append("file under \(category.name)")
        }
        if plan.keep {
            let kept = Set(rows.compactMap(keptCategory)).compactMap(category)
            let name = kept.count == 1 ? kept[0].name : nil
            titles.append(name.map { "Keep \(things) as \($0)" } ?? "Keep \(things) as filed")
            changes.append(name.map { "keep as \($0)" } ?? "keep as filed")
        }
        if let hidden = plan.isHidden {
            titles.append(hidden ? "Hide \(things) from your totals" : "Count \(things) in your totals again")
            changes.append(hidden ? "hide from your totals" : "count in your totals again")
        }
        if let yearly = plan.isYearly {
            titles.append(yearly ? "Spread \(things) over the year" : "Count \(things) in the month charged")
            changes.append(yearly ? "spread over the year" : "count in the month charged")
        }
        if plan.changesNote {
            titles.append(plan.note == nil ? (rows.count == 1 ? "Remove the note" : "Remove the notes from \(things)")
                                           : (rows.count == 1 ? "Add a note" : "Add a note to \(things)"))
            changes.append(plan.note == nil ? "remove the note" : "add a note")
        }
        if let merchant = plan.merchant {
            titles.append("Rename \(plan.renamed.count == 1 ? "1 transaction" : "\(plan.renamed.count) transactions") to “\(merchant)”")
            changes.append("rename to “\(merchant)”")
        }
        var notes: [String] = []
        if plan.isHidden == true { notes.append("Balances still include \(rows.count == 1 ? "it" : "them").") }
        if plan.isYearly == true { notes.append("The budget counts a twelfth a month for a year; \(rows.count == 1 ? "it keeps its" : "they keep their") category.") }
        if !plan.aliases.isEmpty { notes.append("New ones get the name too.") }
        if let generic = plan.genericDescriptor { notes.append("“\(generic)” doesn't name a merchant, so other rows like it keep their name.") }
        for move in plan.capMoves { notes.append("The \(move.from) cap moves with it.") }
        if !plan.recurringMoves.isEmpty { notes.append("Its recurring setting moves with it.") }
        var effects: [Figure] = []
        if plan.isHidden == true {
            let out = netSpend(rows.filter { !$0.isHidden })
            if out.minorUnits > 0 { effects.append(Figure(id: "hidden-spend", label: "Taken out of spending", detail: nil, value: out)) }
        }
        if plan.isYearly == true {
            let out = netSpend(rows)
            if out.minorUnits > 0 {
                effects.append(Figure(id: "yearly-month", label: "Counted a month", detail: "A twelfth, for 12 months", value: Money(minorUnits: out.minorUnits / 12)))
            }
        }
        let merchants = Self.merchantList(rows)
        let touched = Array(Set(plan.rows + plan.renamed)).sorted().map { transactions[$0] } // newest first, like the ledger
        let refiled = plan.category.map { category in rows.filter { $0.categorization?.categoryID != category.id }.count }
            ?? (plan.keep ? rows.filter { $0.categorization?.categoryID != keptCategory($0) }.count : nil)
        return Preview(title: titles.count == 1 ? titles[0] : "Edit \(things): \(changes.spokenList)",
                       detail: notes.isEmpty ? merchants : "\(merchants). " + notes.joined(separator: " "), effects: effects,
                       sample: Array(touched.prefix(Preview.sampleSize)), matchCount: touched.count, changeCount: refiled)
    }

    mutating func apply(_ plan: EditPlan) -> ActionResult {
        let caps = plan.capMoves.flatMap { move in
            [RestoreTransactions.Cap(merchant: move.to, monthlyAmount: nil),
             RestoreTransactions.Cap(merchant: move.from, monthlyAmount: merchantTargets[move.from].map(DecimalAmount.init))]
        }
        let touched = Array(Set(plan.rows + plan.renamed)).sorted()
        let recurring = plan.recurringMoves.flatMap { move in
            [RestoreTransactions.Recurring(key: RecurringChoice.key(move.from), choice: recurringChoices[RecurringChoice.key(move.from)]),
             RestoreTransactions.Recurring(key: RecurringChoice.key(move.to), choice: nil)]
        }
        let undo = restoring(touched, aliases: plan.aliases, caps: caps, recurring: recurring)
        for index in plan.rows {
            if let category = plan.category { file(index, under: category.id) }
            if plan.keep, let kept = keptCategory(transactions[index]) { file(index, under: kept) }
            if let hidden = plan.isHidden { setHidden(index, hidden) }
            if let yearly = plan.isYearly { transactions[index].isYearly = yearly }
            if plan.changesNote { transactions[index].note = plan.note }
        }
        if let merchant = plan.merchant {
            for index in plan.renamed { rename(index, to: merchant) }
            for descriptor in plan.aliases { merchantAliases[descriptor] = merchant }
            for move in plan.capMoves { merchantTargets[move.to] = merchantTargets.removeValue(forKey: move.from) }
            for move in plan.recurringMoves {
                var choice = recurringChoices.removeValue(forKey: RecurringChoice.key(move.from))
                choice?.merchant = move.to
                recurringChoices[RecurringChoice.key(move.to)] = choice
            }
        }
        let n = plan.rows.count, many = n == 1 ? "" : " \(n) transactions"
        var messages: [String] = []
        if let category = plan.category { messages.append("Filed\(many) under \(category.name).") }
        if plan.keep { messages.append(n == 1 ? "Kept as \(transactions[plan.rows[0]].categorization.flatMap { category($0.categoryID) }?.name ?? "filed")." : "Kept\(many) as filed.") }
        if let hidden = plan.isHidden { messages.append(hidden ? (n == 1 ? "Hidden from your totals." : "Hid\(many) from your totals.") : "Counted\(many) in your totals again.") }
        if let yearly = plan.isYearly { messages.append(yearly ? "Spread\(many) over the year." : "Counted\(many) in the month charged.") }
        if plan.changesNote { messages.append(plan.note == nil ? "Note removed." : "Note saved.") }
        if let merchant = plan.merchant { messages.append("Renamed\(plan.renamed.count == 1 ? "" : " \(plan.renamed.count) transactions") to “\(merchant)”.") }
        return ActionResult(message: messages.count == 1 ? messages[0] : "Updated \(n == 1 ? "1 transaction" : "\(n) transactions").",
                            affectedTransactions: touched.count, undo: undo)
    }

    /// Files a row as the person's own answer. A row filed as anything but a transfer is no longer one side of a
    /// move, and a descriptor memory was told to forget is remembered again from this answer.
    mutating func file(_ index: Int, under categoryID: String) {
        transactions[index].categorization = Categorization(categoryID: categoryID, confidence: 1, tier: .user, needsReview: false)
        suggestions[transactions[index].id] = nil
        if categoryID != "transfer" { unpair(index) }
        forgottenMerchants.remove(Descriptor.normalize(transactions[index].rawDescription))
    }

    /// Hiding also takes the row out of review: the person has decided it doesn't count.
    mutating func setHidden(_ index: Int, _ hidden: Bool) {
        transactions[index].isHidden = hidden
        if hidden, transactions[index].categorization?.needsReview == true {
            transactions[index].categorization?.needsReview = false
            suggestions[transactions[index].id] = nil
        }
    }

    /// Renames a row's merchant, remembering the name the bank data gave (so it can be told apart and carried over).
    mutating func rename(_ index: Int, to name: String) {
        let row = transactions[index]
        guard row.merchant != name else { return }
        let original = row.originalMerchant ?? row.merchant
        transactions[index].merchant = name
        transactions[index].originalMerchant = original == name ? nil : original
    }

    /// Ends a pairing on both sides.
    mutating func unpair(_ index: Int) {
        guard let peer = transactions[index].transferPeerID else { return }
        transactions[index].transferPeerID = nil
        if let other = transactions.firstIndex(where: { $0.id == peer }), transactions[other].transferPeerID == transactions[index].id {
            transactions[other].transferPeerID = nil
        }
    }

    /// An undo that puts these rows — and the other side of any transfer among them — back as they are now,
    /// with the named descriptors' merchant names and the given caps.
    func restoring(_ indices: [Int], aliases: [String] = [], caps: [RestoreTransactions.Cap] = [],
                   recurring: [RestoreTransactions.Recurring] = []) -> AppAction {
        var ids = Set<String>(), rows: [RestoreTransactions.Row] = []
        func add(_ row: LedgerTransaction) {
            guard ids.insert(row.id).inserted else { return }
            rows.append(RestoreTransactions.Row(row, suggestions: suggestions[row.id]))
        }
        for index in indices { add(transactions[index]) }
        let peers = Set(indices.compactMap { transactions[$0].transferPeerID }).subtracting(ids)
        for row in transactions where peers.contains(row.id) { add(row) }
        // Filing a row remembers its descriptor again (`file`), so the undo forgets it again.
        let forgotten = Set(indices.map { Descriptor.normalize(transactions[$0].rawDescription) }).intersection(forgottenMerchants).sorted()
        return .restoreTransactions(RestoreTransactions(
            rows: rows, aliases: aliases.isEmpty ? nil : aliases.map { RestoreTransactions.Alias(descriptor: $0, merchant: merchantAliases[$0]) },
            caps: caps.isEmpty ? nil : caps, forgotten: forgotten.isEmpty ? nil : forgotten, recurring: recurring.isEmpty ? nil : recurring))
    }

    /// "Blue Bottle, Harvest Table and Olive Grill", or the first three and how many more.
    static func merchantList(_ rows: [LedgerTransaction]) -> String {
        let names = Array(Set(rows.map(\.merchant))).sorted()
        return names.count <= 3 ? names.spokenList : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }

    // MARK: Helpers

    func knownMerchant(_ query: String) throws -> String {
        guard let merchant = canonicalMerchant(query.trimmingCharacters(in: .whitespaces)) else {
            throw BudgetAPIError.rejected("No transactions from “\(query)” in the ledger.")
        }
        return merchant
    }

    func merchantMonthlyAverage(_ merchant: String, months: Int = 3) -> Money {
        let totals = (1...months).map { back -> Money in
            let start = calendar.date(byAdding: .month, value: -back, to: startOfMonth)!
            return merchantSpend(merchant, from: start, to: calendar.date(byAdding: .month, value: 1, to: start)!).total
        }
        return Money(minorUnits: totals.map(\.minorUnits).reduce(0, +) / Int64(months))
    }

    private func spendingCategory(_ id: String) throws -> BudgetCategory {
        let category = try activeCategory(id)
        guard category.countsAsSpending else { throw BudgetAPIError.rejected("\(category.name) isn't a spending category, so it can't have a target.") }
        return category
    }

    /// A category old rows may name, merged-away ones included (restoring an undo).
    private func anyCategory(_ id: String) throws -> BudgetCategory {
        guard let category = category(id) else { throw BudgetAPIError.rejected("Unknown category “\(id)”.") }
        return category
    }

    /// A category something new can be filed under.
    func activeCategory(_ id: String) throws -> BudgetCategory {
        let category = try anyCategory(id)
        guard !category.isArchived else { throw BudgetAPIError.rejected(Self.archivedMessage(category)) }
        return category
    }

    static func archivedMessage(_ category: BudgetCategory) -> String {
        "\(category.name) was merged into another category, so nothing new can be filed under it."
    }

    // MARK: Categories

    /// One of the standard categories (archived rather than removed when merged away, so it isn't added back).
    static func isStandard(_ category: BudgetCategory) -> Bool { categoryList.contains { $0.id == category.id } }

    /// What a budget type means for safe to spend, for previews.
    static func groupEffect(_ group: CategoryGroup) -> String {
        switch group {
        case .bills: "a usual month is set aside for it before safe to spend is worked out."
        case .subscriptions: "a usual month is set aside for it before safe to spend is worked out."
        case .everyday: "its spending comes out of safe to spend."
        }
    }

    /// The color a new category gets: whichever the active categories wear least (the palette's order breaks ties).
    func leastUsedColor() -> CategoryColor {
        let used = Dictionary(grouping: activeCategories.map(\.effectiveColor), by: { $0 }).mapValues(\.count)
        return CategoryColor.allCases.min { (used[$0] ?? 0) < (used[$1] ?? 0) } ?? .amber
    }

    static func validate(symbol: String?) throws {
        if let symbol, symbol.wholeMatch(of: /[a-z0-9.]{1,40}/) == nil { throw BudgetAPIError.rejected("“\(symbol)” isn't an icon name.") }
    }

    static func validate(color: String?) throws {
        if let color, CategoryColor(rawValue: color) == nil { throw BudgetAPIError.rejected("“\(color)” isn't one of the category colors.") }
    }

    /// A new category's trimmed name, or the archived category it brings back (one merged away under that name). A
    /// money-in category takes no target; one brought back keeps the kind it had.
    func newCategory(_ p: CreateCategory) throws -> (name: String, archived: Int?) {
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !Self.slug(name).isEmpty else { throw BudgetAPIError.rejected("A category needs a name.") }
        guard name.count <= 32 else { throw BudgetAPIError.rejected("Keep the name to 32 characters.") }
        try Self.validate(symbol: p.symbol)
        try Self.validate(color: p.color)
        let kind = p.kind ?? .spending
        if kind == .moneyIn, p.monthlyTarget != nil {
            throw BudgetAPIError.rejected("\(name) counts as money in, so it can't have a spending target.")
        }
        let same = categories.indices.filter { categories[$0].id == Self.slug(name) || categories[$0].name.caseInsensitiveCompare(name) == .orderedSame }
        if let archived = same.first(where: { categories[$0].isArchived }), same.count == 1 {
            let old = categories[archived]
            guard old.kind == kind else {
                throw BudgetAPIError.rejected("\(old.name) was a \(old.kind.label.lowercased()) category, so it comes back as one. Pick another name for a \(kind.label.lowercased()) category.")
            }
            return (name, archived)
        }
        guard same.isEmpty else { throw BudgetAPIError.rejected("There's already a \(name) category.") }
        return (name, nil)
    }

    /// The category as `p` would leave it. Income and Transfer keep their names and aren't budgeted, so only
    /// their icon and color change; a money-in category the person made can be renamed but isn't budgeted either.
    /// A category's kind never changes.
    func updatedCategory(_ p: UpdateCategory) throws -> (index: Int, category: BudgetCategory) {
        guard let index = categories.firstIndex(where: { $0.id == p.categoryID }) else { throw BudgetAPIError.rejected("Unknown category “\(p.categoryID)”.") }
        var category = categories[index]
        guard !category.isArchived else { throw BudgetAPIError.rejected(Self.archivedMessage(category)) }
        let name = p.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let regroups = p.group.map { $0 != category.group } ?? false
        if category.isSystem || (!category.countsAsSpending && !category.isMoneyIn), (name.map { $0 != category.name } ?? false) || regroups {
            throw BudgetAPIError.rejected("\(category.name) keeps its name and isn't budgeted; you can change its icon and color.")
        }
        if category.isMoneyIn, regroups {
            throw BudgetAPIError.rejected("\(category.name) counts as money in, so it has no budget type.")
        }
        if let name {
            guard !name.isEmpty else { throw BudgetAPIError.rejected("A category needs a name.") }
            guard name.count <= 32 else { throw BudgetAPIError.rejected("Keep the name to 32 characters.") }
            if categories.contains(where: { $0.id != category.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw BudgetAPIError.rejected("There's already a \(name) category.")
            }
            category.name = name
        }
        try Self.validate(symbol: p.symbol)
        try Self.validate(color: p.color)
        if let symbol = p.symbol { category.symbol = symbol }
        if let color = p.color { category.color = color }
        if let group = p.group { category.group = group }
        guard category != categories[index] else { throw BudgetAPIError.rejected("Nothing to change.") }
        return (index, category)
    }

    /// What a merge moves: the category indices, and the rows and rules filed under `from`.
    struct MergePlan {
        var from: Int
        var into: Int
        var rows: [Int]
        var rules: [Int]
    }

    /// Moves `plan`'s rows, rules, suggestions and target into the category it merges into, then archives a
    /// standard category (remembering where it went) or removes one the person made.
    mutating func applyMerge(_ plan: MergePlan, combineTargets: Bool) {
        let (from, into) = (categories[plan.from], categories[plan.into])
        // Each row keeps how it was filed (your answer stays yours, a rule's stays the rule's), now under `into`.
        for index in plan.rows { transactions[index].categorization?.categoryID = into.id }
        for index in plan.rules { rules[index].categoryID = into.id }
        for (id, list) in suggestions where list.contains(where: { $0.categoryID == from.id }) {
            var merged: [CategorySuggestion] = []
            for suggestion in list.map({ $0.categoryID == from.id ? CategorySuggestion(categoryID: into.id, confidence: $0.confidence) : $0 }) {
                if let i = merged.firstIndex(where: { $0.categoryID == suggestion.categoryID }) {
                    merged[i].confidence = max(merged[i].confidence, suggestion.confidence)
                } else {
                    merged.append(suggestion)
                }
            }
            suggestions[id] = merged
        }
        if let target = monthlyTargets.removeValue(forKey: from.id), combineTargets {
            monthlyTargets[into.id] = (monthlyTargets[into.id] ?? .zero) + target
        }
        // Categories merged into this one earlier now lead here too.
        for index in categories.indices where categories[index].mergedInto == from.id { categories[index].mergedInto = into.id }
        if Self.isStandard(from) {
            categories[plan.from].isArchived = true
            categories[plan.from].mergedInto = into.id
        } else {
            categories.remove(at: plan.from)
        }
    }

    /// Where rows filed under `id` go now: the category it was merged into (following later merges), or `id` itself.
    func mergeTarget(_ id: String) -> String {
        var current = id, seen: Set<String> = []
        while let c = category(current), c.isArchived, let next = c.mergedInto, seen.insert(current).inserted { current = next }
        return current
    }

    func mergePlan(_ p: MergeCategory) throws -> MergePlan {
        guard p.from != p.into else { throw BudgetAPIError.rejected("Pick a different category to merge into.") }
        guard let from = categories.firstIndex(where: { $0.id == p.from }) else { throw BudgetAPIError.rejected("Unknown category “\(p.from)”.") }
        guard let into = categories.firstIndex(where: { $0.id == p.into }) else { throw BudgetAPIError.rejected("Unknown category “\(p.into)”.") }
        for category in [categories[from], categories[into]] {
            guard !category.isArchived else { throw BudgetAPIError.rejected(Self.archivedMessage(category)) }
            // Transfer is neither spending nor money in: folding anything into or out of it would change what counts.
            guard category.countsAsSpending || category.isMoneyIn else {
                throw BudgetAPIError.rejected("\(category.name) can't be merged; it counts as neither spending nor money in.")
            }
        }
        let (a, b) = (categories[from], categories[into])
        // Spending folds into spending and money in into money in; either way across would change what counts.
        guard a.kind == b.kind else {
            throw BudgetAPIError.rejected("\(a.name) is \(a.kind.label.lowercased()) and \(b.name) is \(b.kind.label.lowercased()), so one can't be merged into the other.")
        }
        guard a.id != BudgetCategory.incomeID else {
            throw BudgetAPIError.rejected("Income is built in, so it can't be merged away. Merge the other category into it instead.")
        }
        return MergePlan(from: from, into: into, rows: transactions.indices.filter { transactions[$0].categorization?.categoryID == p.from },
                         rules: rules.indices.filter { rules[$0].categoryID == p.from })
    }

    // MARK: Rules

    /// The preview for a rule about to be saved, as it would stand among `list` (the rules after the change).
    func rulePreview(_ rule: BudgetRule, in list: [BudgetRule], title: String, applyToExisting: Bool) -> Preview {
        let known = Set(activeCategories.map(\.id))
        let (candidate, book) = (RuleMatcher(rule, filesMoneyIn: isMoneyIn(rule.categoryID)), ruleBook(list))
        var rows: [LedgerTransaction] = [], moving = 0, settling = 0, yours = 0
        for row in transactions {
            let text = RuleText(row)
            guard candidate.applies(to: row, text) else { continue }
            rows.append(row)
            // Re-filing reaches only the rows this rule would win (a newer rule that also matches keeps its rows), and
            // never a row the person filed themselves — the same test `refile` makes.
            guard book.winner(for: row, text, known: known)?.id == rule.id else { continue }
            switch Self.refiling(row, under: rule.categoryID) {
            case .moves: moving += 1
            case .leavesReview: settling += 1
            case .yours: yours += 1
            case nil: break
            }
        }
        let name = category(rule.categoryID)?.name ?? "its category"
        let conflicts = conflicts(of: rule)
        var notes: [String] = []
        if rows.isEmpty {
            notes.append("No existing transactions match.")
        } else {
            let matched = "\(rows.count) existing transaction\(rows.count == 1 ? "" : "s") match\(rows.count == 1 ? "es" : "")"
            let moves = "\(moving) move\(moving == 1 ? "s" : "") to \(name)"
            let settles = "\(settling) waiting for review get\(settling == 1 ? "s" : "") filed under \(name)"
            notes.append(!applyToExisting ? "\(matched); \(rows.count == 1 ? "it keeps its" : "they keep their") category."
                         : moving + settling == 0 ? "\(matched), already under \(name)."
                         : "\(matched); \([moving > 0 ? moves : nil, settling > 0 ? settles : nil].compactMap { $0 }.spokenList).")
            if applyToExisting, yours > 0 {
                notes.append(yours == 1 ? "The 1 you filed yourself keeps its category." : "The \(yours) you filed yourself keep their category.")
            }
        }
        if rule.isEnabled { notes.append("New matches are filed automatically.") }
        if !conflicts.isEmpty {
            notes.append("It disagrees with \(conflicts.count == 1 ? "another rule" : "\(conflicts.count) other rules") on some transactions; the newer rule wins.")
        }
        return Preview(title: title, detail: notes.joined(separator: " "), sample: Array(rows.prefix(Preview.sampleSize)),
                       matchCount: rows.count, changeCount: moving + settling, conflicts: conflicts)
    }

    /// What re-filing with a rule does to a row it wins: moves it to another category, takes it out of review under the
    /// category it already has, or leaves it — the person's own answer always stays, as confirm and re-check leave it.
    enum Refiling { case moves, leavesReview, yours }

    static func refiling(_ row: LedgerTransaction, under categoryID: String) -> Refiling? {
        let c = row.categorization
        if c?.tier == .user { return .yours }
        if c?.categoryID != categoryID { return .moves }
        return c?.needsReview != false ? .leavesReview : nil
    }

    /// The rule as `p` would leave it.
    func updatedRule(_ p: UpdateBudgetRule) throws -> (index: Int, rule: BudgetRule) {
        guard let index = rules.firstIndex(where: { $0.id == p.ruleID }) else { throw BudgetAPIError.notFound }
        guard p.match != nil || p.categoryID != nil || p.isEnabled != nil || p.applyToExisting == true else { throw BudgetAPIError.rejected("Nothing to change.") }
        var rule = rules[index]
        if let id = p.categoryID { rule.categoryID = try activeCategory(id).id }
        let match = try validatedMatch(p.match ?? rule.match, categoryID: rule.categoryID)
        // Turning a rule off or on leaves its conditions exactly as they were saved.
        if p.match != nil || p.categoryID != nil { rule.match = match }
        if let enabled = p.isEnabled { rule.isEnabled = enabled }
        if p.applyToExisting == true {
            guard rule.isEnabled else { throw BudgetAPIError.rejected("Turn the rule on to re-file with it.") }
            _ = try activeCategory(rule.categoryID)
        }
        return (index, rule)
    }

    /// Files every row `rule` wins as the rule's, except rows the person filed themselves; returns how many changed
    /// category or left review.
    mutating func refile(with rule: BudgetRule) -> Int {
        let known = Set(activeCategories.map(\.id))
        let book = ruleBook()
        var changed = 0
        for index in transactions.indices where book.winner(for: transactions[index], RuleText(transactions[index]), known: known)?.id == rule.id {
            let refiling = Self.refiling(transactions[index], under: rule.categoryID)
            if refiling == .yours { continue }
            if refiling != nil { changed += 1 }
            transactions[index].categorization = Categorization(categoryID: rule.categoryID, confidence: 1, tier: .rule, needsReview: false, decidedBy: rule.stamp)
            suggestions[transactions[index].id] = nil
            if rule.categoryID != "transfer" { unpair(index) }
        }
        return changed
    }

    // MARK: Memory

    /// The memory entry `p` forgets, and the rows with its descriptor.
    func forgetPlan(_ p: ForgetMerchant) throws -> (entry: RememberedMerchant, rows: [LedgerTransaction]) {
        let descriptor = Descriptor.normalize(p.descriptor)
        guard let entry = merchantMemoryEntries().first(where: { $0.descriptor == descriptor }) else {
            throw BudgetAPIError.rejected("Budget hasn't learned anything from “\(p.descriptor)”.")
        }
        return (entry, transactions.filter { Descriptor.normalize($0.rawDescription) == descriptor })
    }

    static func slug(_ name: String) -> String {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
    }
}
