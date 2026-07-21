import XCTest
@testable import AppMonitorCore

final class ConfigurationAuditTests: XCTestCase {
    func testStaticAuditDetectsHealthyCanonicalConfigurationWithoutPersistingSecrets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [String: String] = [
            ".claude/scripts/provider-picker.sh": "unset OPENAI_BASE_URL OPENAI_API_BASE\nOCI_RESPONSES_PORT=\"${OCI_RESPONSES_PORT:-8788}\"",
            ".claude/providers.conf": "stepfun|StepFun|url|step-3.7-flash|STEPFUN_API_KEY\nnvidia|NVIDIA|https://integrate.api.nvidia.com/v1|DYNAMIC|NVIDIA_API_KEY",
            ".codex/config.toml": "url = \"http://127.0.0.1:9000/mcp\"",
            ".config/zed/settings.json": "http://127.0.0.1:9000/mcp",
            ".claude/scripts/anthropic-to-openai-proxy.js": "input_json_delta raw === '[DONE]'",
            ".claude/scripts/oci-anthropic-proxy.js": "oci-anthropic-bridge response.function_call_arguments.delta",
            ".claude/scripts/reset-claude.sh": "unset ANTHROPIC_API_KEY",
            "Library/LaunchAgents/com.claude.mcp-manager.plist": "Application Support/BrowserOS/start-browseros.sh",
        ]
        for (path, text) in fixtures {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let snapshot = await ConfigurationAuditService(homeDirectory: root).scan(includeLiveCatalogs: false)
        XCTAssertFalse(snapshot.redactedReport.contains("STEPFUN_API_KEY="))
        XCTAssertFalse(snapshot.targets.flatMap(\.findings).contains(where: { $0.severity == .critical }))
    }

    func testEmbeddedAnthropicKeyIsCriticalButValueIsNeverReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".claude/scripts/reset-claude.sh")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export ANTHROPIC_API_KEY=sk-ant-secret-value".write(to: url, atomically: true, encoding: .utf8)
        let snapshot = await ConfigurationAuditService(homeDirectory: root).scan(includeLiveCatalogs: false)
        let reset = try XCTUnwrap(snapshot.targets.first(where: { $0.id == "reset-script" }))
        XCTAssertEqual(reset.severity, .critical)
        XCTAssertFalse(snapshot.redactedReport.contains("sk-ant-secret-value"))
    }
}
