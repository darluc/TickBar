import AppKit
import SwiftUI

struct MCPSettingsSection: View {
    let container: DependencyContainer
    @State private var enabled = false
    @State private var token = ""
    @State private var serverError = ""

    var body: some View {
        Section(header: Text(L("settings.mcp.section", comment: "Local MCP")).font(.headline)) {
            Toggle(isOn: $enabled) {
                Text(L("settings.mcp.enabled", comment: "Enable local MCP server"))
            }
            .onChange(of: enabled) { value in
                try? container.settingsRepo.setMCPEnabled(value)
                if value {
                    token = MCPTokenStore.ensureToken()
                }
                container.mcpService.reconcile(enabled: value)
                refreshError()
            }

            if enabled {
                LabeledContent(L("settings.mcp.endpoint", comment: "Endpoint")) {
                    Text(TickBarMCPConfig.endpointURL)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button(L("settings.mcp.copyURL", comment: "Copy URL")) {
                        copy(TickBarMCPConfig.endpointURL)
                    }
                    Button(L("settings.mcp.copyToken", comment: "Copy token")) {
                        copy(token)
                    }
                    Button(L("settings.mcp.rotateToken", comment: "Rotate token")) {
                        token = MCPTokenStore.rotate()
                    }
                }
                .controlSize(.small)

                Text(L("settings.mcp.hint", comment: "Loopback only. Keep TickBar running. Bearer token is stored in Keychain, not app backups."))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !serverError.isEmpty {
                    Text(serverError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .onAppear {
            enabled = container.settingsRepo.mcpEnabled
            token = MCPTokenStore.load() ?? MCPTokenStore.ensureToken()
            refreshError()
        }
    }

    private func refreshError() {
        serverError = container.mcpService.lastError ?? ""
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
