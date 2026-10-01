import BudgetServerCore
import Foundation

do {
    try await BudgetServerApp.run(config: try ServerConfig.fromEnvironment())
} catch {
    FileHandle.standardError.write(Data("budget-api failed to start: \(error)\n".utf8))
    exit(1)
}
