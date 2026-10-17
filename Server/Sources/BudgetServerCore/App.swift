import BudgetKit
import Foundation
import Hummingbird
import Logging
import PostgresNIO

/// Wires configuration to stores, models, sources and routes.
public enum BudgetServerApp {
    /// Builds the service graph. With a database, the Postgres client must be run alongside the app
    /// (it's returned as a service); without one, everything lives in memory.
    public static func makeService(config: ServerConfig, store overrideStore: (any ServerStore)? = nil, logger: Logger,
                                   plaidTransport: (any HTTPTransport)? = nil, pushTransport: (any HTTPTransport)? = nil,
                                   clock: @escaping @Sendable () -> Date = { Date() }) async throws -> (BudgetService, PostgresClient?) {
        var postgres: PostgresClient?
        let store: any ServerStore
        if let overrideStore {
            store = overrideStore
        } else if let database = config.database {
            let pg = PostgresStore(config: database, logger: logger)
            postgres = pg.client
            store = pg
        } else {
            logger.warning("No POSTGRES_HOST: using an in-memory store. Nothing will survive a restart.")
            store = MemoryStore()
        }

        let sealer = try config.tokenKey.map(TokenSealer.init(base64Key:))
        if sealer == nil { logger.warning("No BUDGET_TOKEN_KEY: account linking is disabled.") }

        let settings = ServerSettings(config: config, store: store, sealer: sealer, logger: logger)
        // Before load(): only what the Olares app sets. prepare() applies the saved models.
        let (chat, routing) = models(await settings.modelSnapshot())

        let plaid = plaidTransport ?? AHCTransport.shared
        let providers = Providers(config: config, store: store, sealer: sealer, transport: plaid)
        let deployment = DeploymentInfo(endpoint: config.publicURL ?? "budget-api", version: BudgetServerVersion.current, sources: await providers.sources(), institutions: [],
                                        dashboardURL: config.dashboardURL)

        // The ledger loads once at start (after migrations, which need the Postgres client running).
        let api = LedgerBudgetAPI(state: .empty, calendar: config.calendar, chatModel: chat, decisions: routing,
                                  persistence: store, deployment: deployment)
        // Ask's conversations go where the store keeps them (Postgres); otherwise they stay in memory with the ledger.
        if let chats = store as? any ChatSessionStore { await api.setChatSessionStore(chats) }
        await api.useBalanceHistory(balanceHistory(for: store, logger: logger))
        let sync = SyncService(api: api, store: store, config: config, sealer: sealer, providers: providers, settings: settings, logger: logger)
        // One sender for every notification, so they share one APNs provider token.
        let push = PushSender(settings: settings, transport: pushTransport ?? AHCTransport.shared)
        let morning = MorningSummary(api: api, store: store, sync: sync, settings: settings, push: push, logger: logger, clock: clock)
        let pace = PaceAlertSender(api: api, store: store, morning: morning, push: push, logger: logger, clock: clock)
        let alerts = ConnectionAlertSender(api: api, store: store, sync: sync, morning: morning, push: push, settings: settings, logger: logger, clock: clock)
        let reconnects = ReconnectSessions(store: store, sync: sync, providers: providers, sealer: sealer, settings: settings, logger: logger, clock: clock)
        let maintenance = PlaidMaintenance(api: api, store: store, sync: sync, providers: providers, sealer: sealer, settings: settings,
                                           logger: logger, clock: clock)
        return (BudgetService(api: api, store: store, sync: sync, morning: morning, pace: pace, config: config, sealer: sealer, providers: providers,
                              settings: settings, logger: logger, alerts: alerts, reconnects: reconnects, plaidMaintenance: maintenance,
                              statementIDs: StatementIDKeys.make(sealer: sealer, persistent: config.database != nil)), postgres)
    }

    /// The chat model and decision providers one snapshot of the settings describes.
    static func models(_ snapshot: ModelSnapshot) -> ((any ChatModel)?, DecisionRouting) {
        var routing = DecisionRouting()
        if let url = snapshot.decisionURL {
            routing.local = SystemOneDecisionModel(transport: .selfHosted(baseURL: url, model: "clef", apiKey: snapshot.decisionKey))
        }
        if let key = snapshot.openRouterKey {
            routing.jev = SystemOneDecisionModel(transport: .openRouter(apiKey: key, zeroDataRetention: snapshot.zeroRetention))
        }
        // The same "only providers that keep nothing" as Jev, when the chat model is on OpenRouter too.
        let chat = snapshot.chatURL.map {
            OpenAIChatModel(baseURL: $0, model: snapshot.chatName, apiKey: snapshot.chatKey, zeroRetention: snapshot.zeroRetention) as any ChatModel
        }
        return (chat, routing)
    }

    /// Puts the current settings into effect without a restart: models, month boundaries, endpoint, sources.
    public static func apply(_ service: BudgetService) async {
        await service.modelApplier.apply(await service.settings.modelSnapshot(), to: service.api)
        await service.api.setCalendar(await service.settings.calendar)
        await service.api.setEndpoint(await service.settings.publicURL ?? "budget-api")
        await service.api.setDashboardURL(await service.settings.dashboardURL)
        await service.api.setSources(await service.providers.sources())
    }

    /// Migrates, loads (or seeds) the ledger, and publishes link status.
    public static func prepare(_ service: BudgetService) async throws {
        try await service.store.migrate()
        do { try await service.providers.load() } catch {
            // A bad saved certificate mustn't keep the ledger offline; the dashboard shows and fixes it.
            service.logger.error("provider settings didn't load: \(error)")
        }
        // Until they load, saving settings or models is refused rather than written over rows that weren't read.
        do { try await service.settings.load() } catch { service.logger.error("server settings didn't load, so they can't be changed until a restart: \(error)") }
        // Whether memory and the store hold the same ledger after loading; a migration over one that doesn't is skipped.
        var ledgerInSync = true
        if let state = try await service.store.loadLedger() {
            await service.api.load(state)
            service.logger.info("loaded ledger: \(state.transactions.count) rows, \(state.accounts.count) accounts")
            // What loading filled in (transfer pairs for older matches, new default categories) is written once.
            do { try await service.api.persistUpgrades(from: state) } catch {
                ledgerInSync = false
                service.logger.error("couldn't save the upgraded ledger: \(error)")
            }
        } else {
            let fresh = await service.freshState(seedDemo: service.config.seedDemo)
            try await service.store.replaceLedger(fresh)
            await service.api.load(fresh)
            if service.config.seedDemo { try await service.api.resetBalanceHistory(seedDemo: true) }
            service.logger.info(service.config.seedDemo ? "seeded the demo ledger (BUDGET_SEED_DEMO)" : "new empty ledger — link an account or import a file")
        }
        // Before anything syncs, checks an Item or pushes; never throws, so it can't keep the server from starting.
        await LedgerMigrations.run(service, ledgerInSync: ledgerInSync)
        await apply(service)
        await service.sync.publishInstitutions()
    }

    public static func run(config: ServerConfig) async throws {
        var logger = Logger(label: "budget-api")
        logger.logLevel = .info
        let (service, postgres) = try await makeService(config: config, logger: logger)
        let router = buildRouter(service)
        var app = Application(router: router, configuration: .init(address: .hostname(config.host, port: config.port), serverName: "budget-api"),
                              logger: logger)
        if let postgres { app.addServices(postgres) }
        if let dashboardPort = config.dashboardPort {
            // Same service graph, second listener: the browser dashboard (Surface.dashboard).
            let dashboard = Application(router: buildRouter(service, surface: .dashboard),
                                        configuration: .init(address: .hostname(config.host, port: dashboardPort), serverName: "budget-dashboard"),
                                        logger: logger)
            app.addServices(dashboard)
        }
        app.beforeServerStarts {
            try await prepare(service)
            Task { await service.sync.runScheduler() }
            Task { await service.morning.runScheduler() }
            Task { await service.pace.runScheduler() }
            // After prepare, so the ledger migrations have run first.
            Task { await service.alerts.runScheduler() }
            Task { await service.plaidMaintenance.runScheduler() }
        }
        try await app.runService()
    }
}

/// Puts model snapshots into effect one at a time and only ever forward: an apply that read the settings before another
/// save and arrives after it is dropped, so two overlapping saves can't leave the older models live.
actor ModelApplier {
    private var applied = Int.min
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func apply(_ snapshot: ModelSnapshot, to api: LedgerBudgetAPI) async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }  // handed over, still busy
        }
        guard snapshot.generation >= applied else { return }
        applied = snapshot.generation
        let (chat, routing) = BudgetServerApp.models(snapshot)
        await api.reconfigure(chatModel: chat, decisions: routing)
    }
}

extension LedgerBudgetAPI {
    /// Swaps in loaded state without writing it back.
    func load(_ state: LedgerState) {
        replaceStateWithoutPersisting(state)
    }
}
