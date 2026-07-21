import Foundation

public enum ConfigurationSeverity: String, Codable, CaseIterable, Sendable {
    case healthy
    case informational
    case warning
    case critical
    case unavailable

    public var rank: Int {
        switch self {
        case .healthy: return 0
        case .informational: return 1
        case .unavailable: return 2
        case .warning: return 3
        case .critical: return 4
        }
    }
}

public struct ConfigurationFinding: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let severity: ConfigurationSeverity
    public let summary: String
    public let evidence: String
    public let recommendation: String?

    public init(id: String, severity: ConfigurationSeverity, summary: String, evidence: String, recommendation: String? = nil) {
        self.id = id
        self.severity = severity
        self.summary = summary
        self.evidence = evidence
        self.recommendation = recommendation
    }
}

public struct ConfigurationTargetResult: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let location: String
    public let findings: [ConfigurationFinding]

    public var severity: ConfigurationSeverity {
        findings.max(by: { $0.severity.rank < $1.severity.rank })?.severity ?? .healthy
    }
}

public struct ProviderModelCatalog: Identifiable, Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case live, fallback, unavailable }

    public let id: String
    public let provider: String
    public let source: Source
    public let models: [String]
    public let detail: String
}

public struct ConfigurationSnapshot: Codable, Hashable, Sendable {
    public let scannedAt: Date
    public let targets: [ConfigurationTargetResult]
    public let catalogs: [ProviderModelCatalog]

    public var redactedReport: String {
        var lines = ["AppleiMonitor Configuration Health", "Scanned: \(scannedAt.formatted())", ""]
        for target in targets {
            lines.append("[\(target.severity.rawValue.uppercased())] \(target.name) — \(target.location)")
            for finding in target.findings {
                lines.append("  - \(finding.summary): \(finding.evidence)")
                if let recommendation = finding.recommendation { lines.append("    Recommendation: \(recommendation)") }
            }
        }
        lines.append("")
        lines.append("Provider model catalogs")
        for catalog in catalogs {
            lines.append("- \(catalog.provider): \(catalog.source.rawValue), \(catalog.models.count) model(s), \(catalog.detail)")
            for model in catalog.models { lines.append("  - \(model)") }
        }
        return lines.joined(separator: "\n")
    }
}

public struct ConfigurationAuditService: Sendable {
    private let homeDirectory: URL
    private let session: URLSession

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, session: URLSession = .shared) {
        self.homeDirectory = homeDirectory
        self.session = session
    }

    public func scan(includeLiveCatalogs: Bool = true) async -> ConfigurationSnapshot {
        var targets = staticTargets()
        targets.append(await browserOSTarget())
        let catalogs = includeLiveCatalogs ? await providerCatalogs() : []
        targets.append(contentsOf: catalogs.map(catalogTarget))
        return ConfigurationSnapshot(scannedAt: Date(), targets: targets, catalogs: catalogs)
    }

    private func staticTargets() -> [ConfigurationTargetResult] {
        [
            inspect("provider-picker", "Claude provider picker", ".claude/scripts/provider-picker.sh", rules: [
                ("clean-env", "unset OPENAI_BASE_URL OPENAI_API_BASE", "Provider variables are cleared in a deterministic child environment.", false),
                ("oci-port", "OCI_RESPONSES_PORT=\"${OCI_RESPONSES_PORT:-8788}\"", "OCI uses its dedicated Responses port.", false),
                ("no-pkill", "pkill -f", "Broad process matching can terminate unrelated Claude sessions.", true),
            ]),
            inspect("providers", "Provider definitions", ".claude/providers.conf", rules: [
                ("stepfun-model", "step-3.7-flash", "StepFun includes its Messages-compatible model.", false),
                ("bad-stepfun-model", "step-3.5-flash", "A StepFun model disabled for the Messages API is still offered.", true),
                ("nvidia", "https://integrate.api.nvidia.com/v1", "NVIDIA live model discovery endpoint is configured.", false),
            ]),
            inspect("codex-browseros", "Codex BrowserOS MCP", ".codex/config.toml", rules: [
                ("browser-url", "url = \"http://127.0.0.1:9000/mcp\"", "Codex uses BrowserOS HTTP MCP on port 9000.", false),
                ("old-port", "9200/mcp", "A stale BrowserOS port remains configured.", true),
            ]),
            inspect("zed-browseros", "Zed BrowserOS MCP", ".config/zed/settings.json", rules: [
                ("browser-url", "http://127.0.0.1:9000/mcp", "Zed uses BrowserOS HTTP MCP on port 9000.", false),
                ("old-port", "9200/mcp", "A stale BrowserOS port remains configured.", true),
            ]),
            inspect("generic-bridge", "OpenAI-compatible Claude bridge", ".claude/scripts/anthropic-to-openai-proxy.js", rules: [
                ("stream-tools", "input_json_delta", "Streamed tool arguments are translated.", false),
                ("done", "raw === '[DONE]'", "Streams finalize on the provider DONE event.", false),
            ]),
            inspect("oci-bridge", "OCI Claude bridge", ".claude/scripts/oci-anthropic-proxy.js", rules: [
                ("service", "oci-anthropic-bridge", "The bridge exposes an application-specific health identity.", false),
                ("stream", "response.function_call_arguments.delta", "OCI function-call deltas are translated.", false),
            ]),
            inspect("reset-script", "Claude reset script", ".claude/scripts/reset-claude.sh", rules: [
                ("embedded-key", "sk-ant-", "A plaintext Anthropic key is embedded in the script.", true),
            ]),
            inspect("browser-launch", "BrowserOS startup agent", "Library/LaunchAgents/com.claude.mcp-manager.plist", rules: [
                ("launcher", "Application Support/BrowserOS/start-browseros.sh", "The login agent uses the health-checked BrowserOS launcher.", false),
                ("missing-script", ".claude/start-mcp-servers.sh", "The agent still references the missing legacy script.", true),
            ]),
        ]
    }

    private typealias Rule = (id: String, needle: String, message: String, inverted: Bool)

    private func inspect(_ id: String, _ name: String, _ relativePath: String, rules: [Rule]) -> ConfigurationTargetResult {
        let url = homeDirectory.appendingPathComponent(relativePath)
        guard let data = FileManager.default.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else {
            return ConfigurationTargetResult(id: id, name: name, location: displayPath(relativePath), findings: [
                ConfigurationFinding(id: "\(id)-unreadable", severity: .unavailable, summary: "Unavailable", evidence: "The expected file is missing or unreadable.")
            ])
        }
        let findings = rules.map { rule -> ConfigurationFinding in
            let contains = text.contains(rule.needle)
            let passes = rule.inverted ? !contains : contains
            return ConfigurationFinding(
                id: "\(id)-\(rule.id)",
                severity: passes ? .healthy : (rule.inverted ? .critical : .warning),
                summary: passes ? "Check passed" : "Check failed",
                evidence: rule.message,
                recommendation: passes ? nil : "Review \(displayPath(relativePath)); secret values are intentionally hidden."
            )
        }
        return ConfigurationTargetResult(id: id, name: name, location: displayPath(relativePath), findings: findings)
    }

    private func displayPath(_ relativePath: String) -> String { "~/\(relativePath)" }

    private func browserOSTarget() async -> ConfigurationTargetResult {
        guard let url = URL(string: "http://127.0.0.1:9000/health") else { fatalError("Static BrowserOS URL is invalid") }
        do {
            let (_, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let healthy = (200..<300).contains(code)
            return ConfigurationTargetResult(id: "browseros-runtime", name: "BrowserOS runtime", location: "127.0.0.1:9000", findings: [
                ConfigurationFinding(id: "browseros-health", severity: healthy ? .healthy : .warning, summary: healthy ? "Healthy" : "Unexpected response", evidence: "HTTP \(code); response body is not retained.")
            ])
        } catch {
            return ConfigurationTargetResult(id: "browseros-runtime", name: "BrowserOS runtime", location: "127.0.0.1:9000", findings: [
                ConfigurationFinding(id: "browseros-health", severity: .unavailable, summary: "Not reachable", evidence: "BrowserOS did not answer its local health endpoint.", recommendation: "Launch BrowserOS and verify MCP is enabled on port 9000.")
            ])
        }
    }

    private func providerCatalogs() async -> [ProviderModelCatalog] {
        async let stepFun = fetchBearerCatalog(provider: "StepFun", endpoint: "https://api.stepfun.ai/step_plan/v1/models", keyName: "STEPFUN_API_KEY", compatible: { $0 == "step-3.7-flash" }, fallback: ["step-3.7-flash"])
        async let nvidia = fetchBearerCatalog(provider: "NVIDIA", endpoint: "https://integrate.api.nvidia.com/v1/models", keyName: "NVIDIA_API_KEY", compatible: { _ in true }, fallback: [])
        async let oci = fetchOCICatalog()
        return await [stepFun, oci, nvidia]
    }

    private func fetchBearerCatalog(provider: String, endpoint: String, keyName: String, compatible: @escaping @Sendable (String) -> Bool, fallback: [String]) async -> ProviderModelCatalog {
        guard let key = credential(named: keyName) else {
            return ProviderModelCatalog(id: provider.lowercased(), provider: provider, source: fallback.isEmpty ? .unavailable : .fallback, models: fallback, detail: "Credential unavailable; no secret value was retained.")
        }
        do {
            var request = URLRequest(url: URL(string: endpoint)!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 12
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw URLError(.userAuthenticationRequired) }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = object?["data"] as? [[String: Any]] ?? []
            let models = rows.compactMap { $0["id"] as? String }.filter(compatible).sorted()
            guard !models.isEmpty else { throw URLError(.cannotParseResponse) }
            return ProviderModelCatalog(id: provider.lowercased(), provider: provider, source: .live, models: models, detail: "Fetched live; credential and response bodies were not persisted.")
        } catch {
            return ProviderModelCatalog(id: provider.lowercased(), provider: provider, source: fallback.isEmpty ? .unavailable : .fallback, models: fallback, detail: "Live discovery failed; secret and upstream error body are redacted.")
        }
    }

    private func fetchOCICatalog() async -> ProviderModelCatalog {
        let configURL = homeDirectory.appendingPathComponent(".oci/config")
        guard let config = try? String(contentsOf: configURL) else {
            return ProviderModelCatalog(id: "oci", provider: "OCI", source: .unavailable, models: [], detail: "~/.oci/config is unavailable.")
        }
        func value(_ key: String) -> String? {
            config.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key)=") }).map { String($0.split(separator: "=", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
        }
        guard let tenancy = value("tenancy"), let region = value("region") else {
            return ProviderModelCatalog(id: "oci", provider: "OCI", source: .unavailable, models: [], detail: "OCI tenancy or region is missing.")
        }
        do {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["oci", "raw-request", "--http-method", "GET", "--target-uri", "https://generativeai.\(region).oci.oraclecloud.com/20231130/models?compartmentId=\(tenancy)&lifecycleState=ACTIVE&modelCollectionType=BASE"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw URLError(.cannotConnectToHost) }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let dataObject = object?["data"] as? [String: Any]
            let rows = dataObject?["items"] as? [[String: Any]] ?? []
            let models = rows.filter { (($0["capabilities"] as? [String]) ?? []).contains("CHAT") }.compactMap { ($0["displayName"] as? String) ?? ($0["id"] as? String) }.sorted()
            return ProviderModelCatalog(id: "oci", provider: "OCI", source: models.isEmpty ? .unavailable : .live, models: models, detail: models.isEmpty ? "No active chat models returned." : "Fetched from the active regional OCI catalog.")
        } catch {
            return ProviderModelCatalog(id: "oci", provider: "OCI", source: .fallback, models: ["xai.grok-4.20-reasoning", "xai.grok-4.20-non-reasoning", "openai.gpt-oss-120b", "google.gemini-2.5-pro"], detail: "Live OCI discovery failed; showing verified fallback models.")
        }
    }

    private func credential(named name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        let envURL = homeDirectory.appendingPathComponent(".hermes/.env")
        guard let text = try? String(contentsOf: envURL) else { return nil }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let normalized = line.hasPrefix("export ") ? String(line.dropFirst(7)) : line
            guard normalized.hasPrefix("\(name)=") else { continue }
            return String(normalized.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private func catalogTarget(_ catalog: ProviderModelCatalog) -> ConfigurationTargetResult {
        let severity: ConfigurationSeverity = catalog.source == .live ? .healthy : (catalog.source == .fallback ? .warning : .unavailable)
        return ConfigurationTargetResult(id: "catalog-\(catalog.id)", name: "\(catalog.provider) model catalog", location: "Provider API", findings: [
            ConfigurationFinding(id: "catalog-\(catalog.id)-source", severity: severity, summary: catalog.source.rawValue.capitalized, evidence: "\(catalog.models.count) compatible model(s). \(catalog.detail)")
        ])
    }
}
