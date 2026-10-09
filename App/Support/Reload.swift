import BudgetKit
import DesignSystem
import SwiftUI

/// Every screen reloads the same way: pull to refresh, or a toolbar button that spins while it works,
/// then a short note — "Updated 3:41 PM" or "Couldn't refresh". A reload that brings back the same
/// numbers still reads as done, and a failed one no longer hides behind the last good answer.
struct ReloadControl: ViewModifier {
    /// Home hides its navigation bar; it keeps pull-to-refresh and the note.
    var showsButton: Bool
    var label: String
    let reload: @MainActor () async -> String?

    @State private var running = false
    @State private var note: Note?

    struct Note: Equatable {
        var text: String
        var failed: Bool
        var id = UUID()
    }

    func body(content: Content) -> some View {
        content
            .refreshable { await run() }
            .toolbar {
                if showsButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await run() } } label: {
                            if running { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }
                        .disabled(running)
                        .accessibilityLabel(running ? "Refreshing" : label)
                        .accessibilityIdentifier("reloadButton")
                    }
                }
            }
            .overlay(alignment: .top) {
                if let note {
                    Label(note.text, systemImage: note.failed ? "exclamationmark.triangle" : "checkmark")
                        .dsFont(.caption)
                        .foregroundStyle(note.failed ? Color.ds.caution : Color.ds.inkSoft)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("reloadNote")
                }
            }
            .animation(.snappy, value: note)
    }

    private func run() async {
        guard !running else { return }
        running = true
        let started = Date()
        let error = await reload()
        // A beat of spinner at least, so a fast answer still reads as a reload.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 0.4 { try? await Task.sleep(for: .seconds(0.4 - elapsed)) }
        running = false
        let shown = error.map { Note(text: "Couldn't refresh — \($0)", failed: true) }
            ?? Note(text: "Updated \(Date.now.formatted(date: .omitted, time: .shortened))", failed: false)
        note = shown
        try? await Task.sleep(for: .seconds(shown.failed ? 4 : 1.8))
        if note?.id == shown.id { note = nil }
    }
}

extension View {
    /// `reload` refetches and returns an error message, or nil when it worked.
    func reloadable(_ label: String = "Refresh", button: Bool = true, _ reload: @escaping @MainActor () async -> String?) -> some View {
        modifier(ReloadControl(showsButton: button, label: label, reload: reload))
    }
}

extension LoadState {
    /// Like `refreshed`, and also says why a fetch failed — even when the last value stays on screen.
    @MainActor
    func refreshing(_ fetch: () async throws -> Value) async -> (state: LoadState, error: String?) {
        do {
            return (.loaded(try await fetch()), nil)
        } catch {
            if Task.isCancelled { return (self, nil) }
            return (value != nil ? self : .failed(error.localizedDescription), error.localizedDescription)
        }
    }
}

extension LoadState where Value: Decodable & Sendable {
    /// Before a screen's first answer, the copy saved on the phone from last time, so it shows at once; otherwise
    /// unchanged. Pair it with `AppModel.beginUpdating(showingSaved:)` around the fetch.
    @MainActor
    func orSaved(_ read: SavedRead, _ app: AppModel) async -> LoadState {
        guard case .loading = self, let saved: Value = await app.saved(read) else { return self }
        return .loaded(saved)
    }
}
