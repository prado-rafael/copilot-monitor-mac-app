import Foundation
import CopilotMonitorCore
import Security

enum MonitorError: Error, LocalizedError {
    case noToken
    case command(String)
    case unauthorized
    case http(Int, String)
    case noCachedResponse

    var errorDescription: String? {
        switch self {
        case .noToken: return "Não encontrei um token. Configure um token nas Preferências ou entre no GitHub com `gh auth login`."
        case let .command(message): return "Não foi possível obter o token de `gh auth token`: \(message)"
        case .unauthorized: return "O GitHub recusou o token. Atualize-o nas Preferências ou execute `gh auth login`."
        case let .http(code, message): return "A API do GitHub retornou HTTP \(code): \(message)"
        case .noCachedResponse: return "O GitHub respondeu 304, mas ainda não há dados em cache. Tente Atualizar novamente."
        }
    }
}

/// Localização do banco, compartilhada pelo app (`AppDelegate`) e pelo modo CLI.
enum MonitorDatabase {
    /// `COPILOT_MONITOR_DEMO=1`: dados sintéticos num banco separado, sem acesso à rede.
    static var isDemo: Bool { ProcessInfo.processInfo.environment["COPILOT_MONITOR_DEMO"] == "1" }

    /// `~/Library/Application Support/CopilotMonitor/usage.sqlite` (`usage-demo.sqlite` no demo).
    static func url(demo: Bool) throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appendingPathComponent("CopilotMonitor", isDirectory: true)
        .appendingPathComponent(demo ? "usage-demo.sqlite" : "usage.sqlite")
    }
}

enum KeychainTokenStore {
    private static let service = "local.copilotmonitor"
    private static let account = "github-token"

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return token
    }

    static func save(_ token: String?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return
        }
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            let status = SecItemAdd(insertion as CFDictionary, nil)
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        } else if updateStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
    }
}

@MainActor
final class TokenResolver {
    private var cliCache: String?

    func token(forceRefresh: Bool = false) async throws -> String {
        if let override = try KeychainTokenStore.load(), !override.isEmpty { return override }
        if !forceRefresh, let cliCache { return cliCache }
        let value = try await Self.readGitHubCLI()
        guard !value.isEmpty else { throw MonitorError.noToken }
        cliCache = value
        return value
    }

    func invalidateCLICache() { cliCache = nil }

    private static func readGitHubCLI() async throws -> String {
        try await Task.detached(priority: .utility) {
            let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
                throw MonitorError.noToken
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["auth", "token"]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw MonitorError.command(String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "comando terminou com erro")
                }
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch let error as MonitorError {
                throw error
            } catch {
                throw MonitorError.command(error.localizedDescription)
            }
        }.value
    }
}

enum GitHubFetchResult {
    case modified(UsageSnapshot, etag: String?)
    case unchanged(etag: String?)
}

struct GitHubCopilotClient {
    func fetch(token: String, etag: String?) async throws -> GitHubFetchResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MonitorError.http(-1, "resposta HTTP inválida")
        }
        let responseETag = response.value(forHTTPHeaderField: "ETag")
        if response.statusCode == 304 { return .unchanged(etag: responseETag ?? etag) }
        if response.statusCode == 401 { throw MonitorError.unauthorized }
        guard response.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw MonitorError.http(response.statusCode, String(body))
        }
        return .modified(try GitHubResponseParser.parse(data), etag: responseETag)
    }
}
