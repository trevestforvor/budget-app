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

        let settings = ServerSettings(config: config, store: store, sealer: sealer)
        let (chat, routing) = await models(settings)

        let plaid = plaidTransport ?? AHCTransport.shared
        let teller = try config.teller.map { try AHCTransport.mutualTLS(certificatePath: $0.certificatePath, keyPath: $0.keyPath) as any HTTPTransport }
        let providers = Providers(config: config, store: store, sealer: sealer, transport: plaid, envTellerTransport: teller)
        let deployment = DeploymentInfo(endpoint: config.publicURL ?? "budget-api", version: BudgetServerVersion.current, sources: await providers.sources(), institutions: [],
                                        dashboardURL: config.dashboardURL)

        // The ledger loads once at start (after migrations, which need the Postgres client running).
        let api = LedgerBudgetAPI(state: .empty, calendar: config.calendar, chatModel: chat, decisions: routing,
                                  persistence: store, deployment: deployment)
        await api.useBalanceHistory(balanceHistory(for: store, logger: logger))
        let sync = SyncService(api: api, store: store, config: config, sealer: sealer, providers: providers, settings: settings, logger: logger)
        let morning = MorningSummary(api: api, store: store, sync: sync, settings: settings, transport: pushTransport ?? AHCTransport.shared,
                                     logger: logger, clock: clock)
        return (BudgetService(api: api, store: store, sync: sync, morning: morning, config: config, sealer: sealer, providers: providers,
                              settings: settings, logger: logger), postgres)
    }

    /// The chat model and decision providers the settings describe.
    static func models(_ settings: ServerSettings) async -> ((any ChatModel)?, DecisionRouting) {
        let name = await settings.modelName
        var routing = DecisionRouting()
        if let url = await settings.decisionBaseURL {
            routing.local = SystemOneDecisionModel(transport: .selfHosted(baseURL: url, model: "clef", apiKey: await settings.decisionAPIKey))
        }
        if let key = await settings.openRouterKey {
            routing.jev = SystemOneDecisionModel(transport: .openRouter(apiKey: key, zeroDataRetention: await settings.openRouterZeroRetention))
        }
        let key = await settings.modelAPIKey
        let chat = await settings.modelBaseURL.map { OpenAIChatModel(baseURL: $0, model: name, apiKey: key) as any ChatModel }
        return (chat, routing)
    }

    /// Puts the current settings into effect without a restart: models, month boundaries, endpoint, sources.
    public static func apply(_ service: BudgetService) async {
        let (chat, routing) = await models(service.settings)
        await service.api.reconfigure(chatModel: chat, decisions: routing)
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
        do { try await service.settings.load() } catch { service.logger.error("server settings didn't load: \(error)") }
        if let state = try await service.store.loadLedger() {
            await service.api.load(state)
            service.logger.info("loaded ledger: \(state.transactions.count) rows, \(state.accounts.count) accounts")
            // What loading filled in (transfer pairs for older matches, new default categories) is written once.
            do { try await service.api.persistUpgrades(from: state) } catch { service.logger.error("couldn't save the upgraded ledger: \(error)") }
        } else {
            let fresh = await service.freshState(seedDemo: service.config.seedDemo)
            try await service.store.replaceLedger(fresh)
            await service.api.load(fresh)
            if service.config.seedDemo { try await service.api.resetBalanceHistory(seedDemo: true) }
            service.logger.info(service.config.seedDemo ? "seeded the demo ledger (BUDGET_SEED_DEMO)" : "new empty ledger — link an account or import a file")
        }
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
        }
        try await app.runService()
    }
}

extension LedgerBudgetAPI {
    /// Swaps in loaded state without writing it back.
    func load(_ state: LedgerState) {
        replaceStateWithoutPersisting(state)
    }
}
