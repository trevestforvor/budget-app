import BudgetKit
import DesignSystem
import SwiftUI
import UIKit

/// Every transaction, newest first: what's waiting for an answer at the top, then the ledger by day. Sort,
/// quick filters and the Filters sheet narrow it (with a summary of what's showing); Select files, hides or
/// notes many rows at once. Every change goes through the one write path and can be undone from its toast.
struct ActivityView: View {
    @Environment(AppModel.self) private var app
    @State private var filter = TransactionFilter.activity
    @State private var query = ""
    @State private var rows: [LedgerTransaction] = []
    @State private var phase: Phase = .loading
    @State private var loadedFilter: TransactionFilter?
    @State private var hasMore = false
    @State private var isLoadingMore = false
    /// The next page didn't come back; the list ends in "Couldn't load more" with a way to try again.
    @State private var loadMoreFailed = false
    @State private var summary: TransactionSummary?
    /// The totals didn't come back; the summary card says so instead of staying a placeholder.
    @State private var summaryFailed = false
    @AppStorage("activity.summaryCollapsed") private var summaryCollapsed = false
    @State private var showsFilters = false
    @State private var detail: LedgerTransaction?
    @State private var triage: TriageStart?
    @State private var isSelecting = false
    /// The selection bar uses the bottom edge; the price-check button steps aside for it.
    @Environment(\.dsBottomEdge) private var bottomEdge
    @State private var selection: Set<String> = []
    @State private var picking: PickTarget?
    @State private var noting: NoteTarget?
    @State private var tagging: TagTarget?
    /// One row re-filed from its menu, filed (or offered with the rows like it) once the picker has gone.
    @State private var pendingPick: (row: LedgerTransaction, category: BudgetCategory)?
    @State private var similarOffer: SimilarOffer?
    /// The server can write the CSV (0.5.0 on); an older one has no export to offer.
    @State private var canExport = false
    @State private var toast: DSToastMessage?
    @State private var workingGroups: Set<String> = []
    @State private var isWorking = false

    enum Phase: Equatable { case loading, loaded, failed(String) }

    struct TriageStart: Identifiable {
        let id = UUID()
        var groupID: String?
    }

    struct PickTarget: Identifiable {
        let id = UUID()
        var ids: [String]
        var selected: String?
        var suggestions: [CategorySuggestion] = []
    }

    struct NoteTarget: Identifiable {
        let id = UUID()
        var ids: [String]
        var initial: String
    }

    struct TagTarget: Identifiable {
        let id = UUID()
        var ids: [String]
        /// Tags on any of the rows now.
        var current: [String]
    }

    private var edits: RowEdits { RowEdits(app: app, toast: $toast) }

    /// The filter with the search box folded in: what the list, the summary and paging all read.
    private var effectiveFilter: TransactionFilter {
        var f = filter
        let search = query.trimmingCharacters(in: .whitespaces)
        f.search = search.isEmpty ? nil : search
        f.offset = 0
        f.limit = TransactionFilter.pageSize
        return f
    }

    private var showsReviewCard: Bool { !effectiveFilter.narrows && !isSelecting && !app.reviewGroups.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpace.lg) {
                    VStack(alignment: .leading, spacing: DSSpace.md) {
                        PageTitle("Activity", eyebrow: "Ledger")
                        controls
                        quickChips
                    }
                    if showsReviewCard {
                        ActivityReviewCard(groups: app.reviewGroups, working: workingGroups,
                                           onOpen: { triage = TriageStart(groupID: $0.id) },
                                           onFile: { group, category in Task { await fileGroup(group, as: category) } },
                                           onReviewAll: { triage = TriageStart() })
                    }
                    if effectiveFilter.narrows, phase == .loaded, !rows.isEmpty {
                        ActivitySummaryCard(summary: summary, failed: summaryFailed, direction: effectiveFilter.direction,
                                            isCollapsed: $summaryCollapsed) {
                            filter.needsReviewOnly = true
                        }
                    }
                    if phase == .loaded, !query.isEmpty, !isSelecting { MerchantSearchLink(query: query, rows: rows) }
                    content
                }
                .padding(.horizontal, DSSpace.gutter)
                .padding(.bottom, DSSpace.xxl)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .dsScreenBackground()
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $query, prompt: "Merchants, notes, amounts")
            .reloadable(button: false) { await reload() } // pull to refresh; no button over the amounts
            .dsToast($toast)
            .onChange(of: isSelecting) { _, selecting in bottomEdge?.mark("selection", selecting) }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionBar }
            }
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .transactionDetailSheet(item: $detail) { accountID in
                query = ""
                filter = TransactionFilter.activity
                filter.accountIDs = [accountID]
            }
            .sheet(item: $triage) { start in
                ReviewTriageView(startingAt: start.groupID)
            }
            .sheet(isPresented: $showsFilters) {
                ActivityFilterSheet(filter: effectiveFilter) { applied in
                    var next = applied
                    next.search = nil
                    filter = next
                }
            }
            .sheet(item: $picking, onDismiss: offerSimilar) { target in
                CategoryPickerSheet(title: target.ids.count == 1 ? "Category" : "File \(target.ids.count) as",
                                    selected: target.selected, suggestions: target.suggestions,
                                    footnote: target.ids.count > 1 ? "Files all \(target.ids.count) as your answer." : nil) { category in
                    if target.ids.count == 1, let row = rows.first(where: { $0.id == target.ids[0] }),
                       row.categorization?.needsReview != true, category.id != row.categorization?.categoryID {
                        pendingPick = (row, category)
                    } else {
                        Task { await bulk { await edits.file(target.ids, as: category.id) } }
                    }
                }
            }
            .sheet(item: $similarOffer) { FileSimilarSheet(offer: $0, edits: edits) }
            .sheet(item: $tagging) { target in
                TagSheet(title: target.ids.count == 1 ? "Tags" : "Tags for \(target.ids.count)", current: target.current, rowCount: target.ids.count) { add, remove in
                    await bulk { await edits.setTags(target.ids, add: add, remove: remove) }
                }
            }
            .toolbar {
                if !isSelecting, canExport, let tools = app.transactionTools {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: TransactionsCSV(filter: effectiveFilter, tools: tools),
                                  preview: SharePreview(effectiveFilter.narrows ? "Transactions (filtered).csv" : "Transactions.csv")) {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityHint(effectiveFilter.narrows ? "Saves the transactions showing as a spreadsheet file" : "Saves every transaction as a spreadsheet file")
                        .accessibilityIdentifier("exportCSV")
                    }
                }
            }
            .sheet(item: $noting) { target in
                NoteSheet(title: target.ids.count == 1 ? "Note" : "Note for \(target.ids.count)", initial: target.initial) { note in
                    await bulk { await edits.setNote(target.ids, note) }
                }
            }
        }
        .onChange(of: app.activitySearch, initial: true) {
            if let search = app.activitySearch {
                query = search
                filter = TransactionFilter.activity
                app.activitySearch = nil
            }
        }
        .onChange(of: app.activityDay, initial: true) {
            if let day = app.activityDay {
                query = ""
                var next = TransactionFilter.activity
                next.since = Calendar.current.startOfDay(for: day)
                next.until = Calendar.current.date(byAdding: .day, value: 1, to: next.since!)
                filter = next
                app.activityDay = nil
            }
        }
        .onChange(of: app.reviewCount, initial: true) {
            if app.opensFirstReview, !app.reviewGroups.isEmpty {
                app.opensFirstReview = false
                triage = TriageStart()
            }
        }
        // Settings → Review → "Open review" while Activity is already loaded.
        .onChange(of: app.opensFirstReview) { _, opens in
            guard opens, !app.reviewGroups.isEmpty else { return }
            app.opensFirstReview = false
            triage = TriageStart()
        }
        .task(id: app.revision) { canExport = await app.serverSupports(ServerStatus.transactionExportSince) }
        .task(id: "\(effectiveFilter.hashValue)|\(app.revision)") {
            if !query.isEmpty, loadedFilter?.search != effectiveFilter.search { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        #if targetEnvironment(simulator)
        .task { await applyScreenshotState() }
        #endif
    }

    // MARK: - Controls

    private var controls: some View {
        let count = filter.choiceCount
        let sort = Menu {
            Picker("Sort", selection: $filter.sort) {
                ForEach(TransactionFilter.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            DSChipLabel(filter.sort.title, systemImage: "arrow.up.arrow.down", trailingSystemImage: "chevron.down")
        }
        .accessibilityLabel("Sort")
        .accessibilityValue(filter.sort.title)
        .accessibilityIdentifier("sortMenu")
        let filters = DSChip(count > 0 ? "Filters · \(count)" : "Filters", systemImage: "line.3.horizontal.decrease", isSelected: count > 0) {
            showsFilters = true
        }
        .accessibilityLabel(count > 0 ? "Filters, \(count) on" : "Filters")
        .accessibilityIdentifier("filtersButton")
        let select = DSChip(isSelecting ? "Done" : "Select", systemImage: isSelecting ? nil : "checkmark.circle", isSelected: isSelecting) {
            withAnimation(DSMotion.standard) {
                isSelecting.toggle()
                selection = []
            }
        }
        .disabled(rows.isEmpty && !isSelecting)
        .accessibilityIdentifier("selectButton")
        // Chips never wrap their words: when the row doesn't fit (large text), they flow onto two lines instead.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpace.xs) {
                sort.fixedSize()
                Spacer(minLength: DSSpace.xs)
                filters.fixedSize()
                select.fixedSize()
            }
            DSFlowLayout(spacing: DSSpace.xs) {
                sort
                filters
                select
            }
        }
    }

    /// The day the filter shows, when it's exactly one.
    private var singleDay: Date? {
        guard let since = filter.since, let until = filter.until,
              Calendar.current.date(byAdding: .day, value: 1, to: since) == until else { return nil }
        return since
    }

    private var quickChips: some View {
        // No count here: the review card counts decisions (like the tab badge), and this filter shows rows.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpace.xs) {
                // One day, from a tap on Home's week strip: said up front, and one tap shows every day again.
                if let day = singleDay {
                    DSChip(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), systemImage: "calendar", isSelected: true) {
                        filter.since = nil
                        filter.until = nil
                    }
                    .accessibilityHint("Shows every day again")
                    .accessibilityIdentifier("dayChip")
                }
                if let tags = filter.tags, !tags.isEmpty {
                    DSChip(tags.count == 1 ? tags[0] : "\(tags.count) tags", systemImage: "tag", isSelected: true) { filter.tags = nil }
                        .accessibilityHint("Shows every tag again")
                        .accessibilityIdentifier("tagChip")
                }
                DSChip("Needs review", isSelected: filter.needsReviewOnly) {
                    filter.needsReviewOnly.toggle()
                }
                DSChip("This month", isSelected: filter.activePeriod == .thisMonth) {
                    filter.setPeriod(filter.activePeriod == .thisMonth ? .all : .thisMonth)
                }
                DSChip("Money out", isSelected: filter.direction == .moneyOut) {
                    filter.direction = filter.direction == .moneyOut ? nil : .moneyOut
                }
                DSChip("Not counted", isSelected: filter.visibility == .notCounted) {
                    filter.visibility = filter.visibility == .notCounted ? .all : .notCounted
                }
                DSChip("Filed by the model", isSelected: filter.modelFiledOnly) {
                    filter.modelFiledOnly.toggle()
                }
            }
        }
        .contentMargins(.horizontal, DSSpace.gutter, for: .scrollContent)
        .padding(.horizontal, -DSSpace.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick filters")
    }

    // MARK: - Rows

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            LoadingPlaceholder()
        case let .failed(message):
            DSStateView(systemImage: "wifi.slash", title: "Can't load activity", message: message, actionTitle: "Try again") {
                Task { await load() }
            }
        case .loaded where rows.isEmpty:
            if effectiveFilter.narrows {
                DSStateView(systemImage: "line.3.horizontal.decrease", title: "Nothing matches",
                            message: filter.choiceCount > 0 ? "Try fewer filters, or search for something else." : "Try a merchant, part of the bank description, a note or an amount.",
                            actionTitle: filter.choiceCount > 0 ? "Clear filters" : nil) {
                    filter = filter.clearingChoices
                }
            } else {
                DSStateView(systemImage: "tray", title: "No transactions yet",
                            message: "Link a bank or import a statement on your server's dashboard, and they'll show up here.")
            }
        case .loaded:
            ForEach(sections, id: \.id) { section in
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    if let day = section.day { dayHeader(day, rows: section.rows) }
                    DSCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                                rowView(row)
                                if index < section.rows.count - 1 { DSDivider() }
                            }
                        }
                        .padding(.horizontal, DSSpace.md)
                        .padding(.vertical, DSSpace.xxs)
                    }
                }
            }
            if hasMore, !app.isDemo, app.freshness.isOffline {
                // Offline, only the newest page is saved on the phone; there's no next page to wait for.
                Text("Showing the offline copy: the newest \(rows.count.formatted()) transactions. The rest load when your Olares answers.")
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, DSSpace.md)
            } else if hasMore, loadMoreFailed {
                VStack(spacing: DSSpace.xs) {
                    Text("Couldn't load more.").dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                    Button("Try again") {
                        loadMoreFailed = false
                        Task { await loadMore() }
                    }
                    .buttonStyle(.ds(.quiet))
                    .frame(minHeight: DSSize.hitTarget)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpace.sm)
            } else if hasMore {
                DSThinkingLine("Loading more…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DSSpace.md)
                    .onAppear { Task { await loadMore() } }
            } else if rows.count > TransactionFilter.pageSize {
                Text("That's everything: \(rows.count.formatted()) transactions.")
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private struct DaySection {
        var id: String
        var day: Date?
        var rows: [LedgerTransaction]
    }

    /// Days in the list's order; one flat card when sorted by size, where the day is on each row instead.
    private var sections: [DaySection] {
        if filter.sort == .largest { return [DaySection(id: "all", day: nil, rows: rows)] }
        let calendar = Calendar.current
        var result: [DaySection] = []
        for row in rows {
            let day = calendar.startOfDay(for: row.postedAt)
            if result.last?.day == day { result[result.count - 1].rows.append(row) }
            else { result.append(DaySection(id: day.ISO8601Format(), day: day, rows: [row])) }
        }
        return result
    }

    private func dayHeader(_ day: Date, rows: [LedgerTransaction]) -> some View {
        HStack(alignment: .center) {
            DSEyebrow(day.ledgerDay)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if isSelecting {
                let ids = Set(rows.map(\.id))
                let all = ids.isSubset(of: selection)
                Button(all ? "Deselect day" : "Select day") {
                    if all { selection.subtract(ids) } else { selection.formUnion(ids) }
                }
                .buttonStyle(.ds(.quiet))
                .frame(minHeight: DSSize.hitTarget)
            }
        }
        .frame(minHeight: isSelecting ? DSSize.hitTarget : nil)
    }

    private func rowView(_ row: LedgerTransaction) -> some View {
        let isSelected = selection.contains(row.id)
        return Button {
            if isSelecting {
                if isSelected { selection.remove(row.id) } else { selection.insert(row.id) }
            } else {
                detail = row
            }
        } label: {
            HStack(spacing: DSSpace.sm) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: DSIconSize.xl))
                        .foregroundStyle(isSelected ? Color.ds.accent : Color.ds.inkTertiary)
                        .accessibilityHidden(true)
                }
                LedgerRow(transaction: row, detail: filter.sort == .largest ? .day : .account)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { if !isSelecting { rowMenu(row) } }
        .accessibilityAddTraits(isSelecting && isSelected ? .isSelected : [])
        .accessibilityHint(isSelecting ? (isSelected ? "Deselects it" : "Selects it") : "Opens details")
        .accessibilityActions { if !isSelecting { rowMenu(row) } }
        .accessibilityIdentifier("activityRow")
    }

    @ViewBuilder
    private func rowMenu(_ row: LedgerTransaction) -> some View {
        let category = app.category(row.categorization?.categoryID)
        if row.categorization?.needsReview == true, let category {
            Button("Keep \(category.name)", systemImage: "checkmark") { Task { await edits.keepGuess([row.id]) } }
        }
        Button("Change category…", systemImage: "tag") {
            picking = PickTarget(ids: [row.id], selected: category?.id,
                                 suggestions: app.reviewItems.first { $0.id == row.id }?.suggestions ?? [])
        }
        if row.isHidden {
            Button("Count in totals", systemImage: "eye") { Task { await edits.setHidden([row.id], false) } }
        } else {
            Button("Hide from totals", systemImage: "eye.slash") { Task { await edits.setHidden([row.id], true) } }
        }
        Button(row.note == nil ? "Add a note…" : "Edit note…", systemImage: "note.text") {
            noting = NoteTarget(ids: [row.id], initial: row.note ?? "")
        }
        Button((row.tags ?? []).isEmpty ? "Add tags…" : "Edit tags…", systemImage: "tag") {
            tagging = TagTarget(ids: [row.id], current: row.tags ?? [])
        }
        Button("All from \(row.merchant)", systemImage: "magnifyingglass") {
            filter = TransactionFilter.activity
            query = row.merchant
        }
        Button("Copy amount", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = DSAmountFormat.string(row.amount.decimal, currencyCode: row.amount.currencyCode, sign: .magnitude)
        }
        Button("Select", systemImage: "checkmark.circle") {
            isSelecting = true
            selection = [row.id]
        }
    }

    // MARK: - Selection

    private var selectionBar: some View {
        let selected = rows.filter { selection.contains($0.id) }
        let outflow = selected.filter(\.amount.isNegative).map(\.amount.magnitude).sum(currencyCode: rows.first?.amount.currencyCode ?? "USD")
        let ids = rows.map(\.id).filter { selection.contains($0) }
        return ActivitySelectionBar(
            count: selection.count, outflow: outflow, isWorking: isWorking,
            onCategorize: { picking = PickTarget(ids: ids, selected: nil) },
            onHide: { Task { await bulk { await edits.setHidden(ids, true) } } },
            onKeep: { Task { await bulk { await edits.keepGuess(ids) } } },
            onCount: { Task { await bulk { await edits.setHidden(ids, false) } } },
            onNote: { noting = NoteTarget(ids: ids, initial: "") },
            onTags: { tagging = TagTarget(ids: ids, current: TransactionTags.cleaned(selected.flatMap { $0.tags ?? [] })) })
    }

    /// After the picker has gone: file the one row, or offer the rows like it first.
    private func offerSimilar() {
        guard let pick = pendingPick else { return }
        pendingPick = nil
        Task { similarOffer = await edits.fileOrOffer(pick.row, as: pick.category) }
    }

    /// Runs a bulk edit; when it works, selecting ends.
    @discardableResult
    private func bulk(_ edit: () async -> Bool) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        let done = await edit()
        if done, isSelecting {
            withAnimation(DSMotion.standard) {
                isSelecting = false
                selection = []
            }
        }
        return done
    }

    private func fileGroup(_ group: ReviewGroup, as category: BudgetCategory) async {
        workingGroups.insert(group.id)
        defer { workingGroups.remove(group.id) }
        // One row keeps its guess ("Kept as Dining."); a group is filed by name ("Filed 4 transactions under Transfer.").
        if group.count == 1, category.id == group.first.transaction.categorization?.categoryID {
            await edits.keepGuess(group.transactionIDs)
        } else {
            await edits.file(group.transactionIDs, as: category.id)
        }
    }

    // MARK: - Loading

    /// Pull to refresh: the list, and the review queue behind the badge.
    private func reload() async -> String? {
        async let shared: Void = app.refreshShared()
        let error = await load()
        await shared
        return error
    }

    /// The first page — or, after a change to the same list, as many rows as were showing, so an edit far
    /// down doesn't snap the list back to the top page.
    @discardableResult
    private func load() async -> String? {
        let api = app.api
        var f = effectiveFilter
        let sameList = loadedFilter == f
        if sameList { f.limit = max(TransactionFilter.pageSize, rows.count) }
        let request = f
        // The first time the plain list opens, last time's first page shows at once while the fresh one loads.
        let first = phase == .loading && rows.isEmpty
        if first, request.isDefault, let saved: [LedgerTransaction] = await app.saved(.transactions) {
            rows = saved
            hasMore = saved.count >= TransactionFilter.pageSize
            loadedFilter = request
            phase = .loaded
        }
        let updating = app.beginUpdating(showingSaved: first && !rows.isEmpty)
        defer { app.endUpdating(updating) }
        async let totals = Self.totals(api, request)
        do {
            let page = try await api.transactions(request)
            if !sameList { summary = nil }
            rows = page
            hasMore = page.count == request.limit
            loadMoreFailed = false
            loadedFilter = effectiveFilter
            phase = .loaded
            switch await totals {
            case let .success(value)?: (summary, summaryFailed) = (value, false)
            case .failure?: summaryFailed = summary == nil
            case nil: (summary, summaryFailed) = (nil, false)
            }
            if isSelecting { selection.formIntersection(Set(page.map(\.id))) }
            return nil
        } catch {
            if Task.isCancelled { return nil }
            if phase != .loaded || !sameList { phase = .failed(error.localizedDescription) }
            return error.localizedDescription
        }
    }

    /// The summary for a narrowed list, or why it couldn't be had; nil when the list isn't narrowed (no card).
    private static func totals(_ api: any BudgetAPI, _ request: TransactionFilter) async -> Result<TransactionSummary, any Error>? {
        guard request.narrows else { return nil }
        do { return .success(try await api.transactionSummary(request)) } catch { return .failure(error) }
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var f = effectiveFilter
        f.offset = rows.count
        guard let page = try? await app.api.transactions(f) else {
            loadMoreFailed = true
            return
        }
        let known = Set(rows.map(\.id))
        rows += page.filter { !known.contains($0.id) }
        hasMore = page.count == f.limit
    }

    #if targetEnvironment(simulator)
    /// `-activity <state>` for screenshots: filters, select, summary, sort, search:<text>, detail:<id>, triage.
    private func applyScreenshotState() async {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-activity"), args.indices.contains(index + 1) else { return }
        let state = args[index + 1]
        try? await Task.sleep(for: .milliseconds(600))
        switch state {
        case "filters": showsFilters = true
        case "summary": filter.setPeriod(.thisMonth); filter.direction = .moneyOut
        case "largest": filter.sort = .largest
        case "notCounted": filter.visibility = .notCounted
        case "select":
            isSelecting = true
            selection = Set(rows.filter { !($0.categorization?.needsReview ?? false) }.prefix(3).map(\.id))
        case "triage": triage = TriageStart()
        default:
            if state.hasPrefix("search:") { query = String(state.dropFirst(7)) }
            if state.hasPrefix("detail:") {
                // An id ("tx-12") or a search whose newest match opens ("Transfer to Savings").
                let key = String(state.dropFirst(7))
                detail = key.hasPrefix("tx-") ? try? await app.api.transaction(id: key)
                    : try? await app.api.transactions(TransactionFilter(search: key, limit: 1)).first
            }
        }
    }
    #endif
}
