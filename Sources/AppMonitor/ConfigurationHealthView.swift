import AppKit
import AppMonitorCore
import SwiftUI

struct ConfigurationHealthView: View {
    @State private var snapshot: ConfigurationSnapshot?
    @State private var selectedTargetID: String?
    @State private var isScanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configuration Health").font(.largeTitle.bold())
                    Text("Read-only checks for BrowserOS, Claude routing, provider models, streaming, and startup ownership.").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyReport()
                } label: { Label("Copy Redacted Report", systemImage: "doc.on.doc") }
                .disabled(snapshot == nil)
                Button {
                    Task { await refresh() }
                } label: { Label(isScanning ? "Scanning…" : "Refresh", systemImage: "arrow.clockwise") }
                .disabled(isScanning)
            }

            if let snapshot {
                summary(snapshot)
                HSplitView {
                    targetList(snapshot)
                        .frame(minWidth: 300, idealWidth: 360)
                    targetDetail(snapshot)
                        .frame(minWidth: 420)
                }
                .frame(minHeight: 340)
                catalogs(snapshot)
            } else if isScanning {
                ProgressView("Inspecting local configuration and active model catalogs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Configuration Scan", systemImage: "checklist", description: Text("Refresh to inspect exact known configuration targets. Secret values are never displayed."))
            }
        }
        .padding(24)
        .task { if snapshot == nil { await refresh() } }
    }

    private func summary(_ snapshot: ConfigurationSnapshot) -> some View {
        HStack(spacing: 12) {
            ForEach(ConfigurationSeverity.allCases, id: \.self) { severity in
                let count = snapshot.targets.filter { $0.severity == severity }.count
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(count)").font(.title2.bold())
                    Text(severity.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func targetList(_ snapshot: ConfigurationSnapshot) -> some View {
        List(selection: $selectedTargetID) {
            ForEach(snapshot.targets) { target in
                HStack(spacing: 10) {
                    Image(systemName: icon(target.severity)).foregroundStyle(color(target.severity)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).lineLimit(1)
                        Text(target.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .tag(target.id)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private func targetDetail(_ snapshot: ConfigurationSnapshot) -> some View {
        if let target = snapshot.targets.first(where: { $0.id == selectedTargetID }) ?? snapshot.targets.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(target.name).font(.title2.bold())
                    Text(target.location).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    ForEach(target.findings) { finding in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(finding.summary, systemImage: icon(finding.severity)).foregroundStyle(color(finding.severity)).font(.headline)
                            Text(finding.evidence)
                            if let recommendation = finding.recommendation {
                                Text(recommendation).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding()
            }
        }
    }

    private func catalogs(_ snapshot: ConfigurationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active Models").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                ForEach(snapshot.catalogs) { catalog in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(catalog.provider).bold(); Spacer(); Text(catalog.source.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
                        Text(catalog.models.prefix(6).joined(separator: "\n")).font(.caption.monospaced()).lineLimit(6).textSelection(.enabled)
                        if catalog.models.count > 6 { Text("+ \(catalog.models.count - 6) more").font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    @MainActor private func refresh() async {
        isScanning = true
        let result = await ConfigurationAuditService().scan()
        snapshot = result
        if selectedTargetID == nil { selectedTargetID = result.targets.first?.id }
        isScanning = false
    }

    private func copyReport() {
        guard let report = snapshot?.redactedReport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private func icon(_ severity: ConfigurationSeverity) -> String {
        switch severity {
        case .healthy: return "checkmark.circle.fill"
        case .informational: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .unavailable: return "questionmark.circle.fill"
        }
    }

    private func color(_ severity: ConfigurationSeverity) -> Color {
        switch severity {
        case .healthy: return .green
        case .informational: return .blue
        case .warning: return .orange
        case .critical: return .red
        case .unavailable: return .secondary
        }
    }
}
