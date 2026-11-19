//
//  ClickyConnectorsSettingsView.swift
//  leanring-buddy
//
//  Settings > Connectors: list, add, edit and delete custom MCP connectors.
//  Secrets are read from / written to the Keychain by ClickyCustomConnectorStore only.
//

import SwiftUI

struct ClickyConnectorsSettingsView: View {
    private enum Authentication: Hashable {
        case none
        case apiKey
    }

    @ObservedObject private var connectorStore = ClickyCustomConnectorStore.shared

    @State private var isEditorVisible = false
    @State private var editingConnectorID: String?
    @State private var connectorName = ""
    @State private var connectorTransport: ClickyConnectorTransport = .remote
    @State private var serverURL = ""
    @State private var authentication: Authentication = .none
    @State private var apiToken = ""
    @State private var extraHeadersText = ""
    @State private var commandText = ""
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var showsAdvanced = false
    @State private var validationIssue: ClickyConnectorIssue?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card(title: String(localized: "CONNECTORS")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom connectors are any MCP server: a hosted URL or a command on this Mac. Tokens stay in your Keychain and are handed only to Clicky's agents.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)

                    ForEach(connectorStore.connectors) { connector in
                        connectorRow(connector)
                        ClickySettingsRowDivider()
                    }

                    if !isEditorVisible {
                        Button {
                            beginEditing(nil)
                        } label: {
                            Label("Add custom connector", systemImage: "plus")
                        }
                        .buttonStyle(ClickyGlossyPillButtonStyle.light)
                    }
                }
            }

            if isEditorVisible {
                card(title: editingConnectorID == nil ? String(localized: "NEW CONNECTOR") : String(localized: "EDIT CONNECTOR")) {
                    editorForm
                }
            }
        }
    }

    // MARK: - Rows

    private func connectorRow(_ connector: ClickyCustomConnector) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(connector.transport == .remote ? connector.url : connector.command)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()

            Toggle("", isOn: Binding(
                get: { connector.isEnabled },
                set: { connectorStore.setEnabled($0, for: connector.id) }
            ))
            .labelsHidden()
            .toggleStyle(ClickyGlossyToggleStyle())
            Button {
                beginEditing(connector)
            } label: {
                Image(systemName: "pencil")
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Edit \(connector.name)"))
            .pointerCursor()

            Button {
                connectorStore.delete(id: connector.id)
                if editingConnectorID == connector.id { isEditorVisible = false }
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(DS.Colors.destructiveText)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Delete"))
            .pointerCursor()
        }
    }

    // MARK: - Editor

    private var editorForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(String(localized: "e.g. Meta Ads"), text: $connectorName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await save() } }

            Picker("", selection: $connectorTransport) {
                Text("Remote URL").tag(ClickyConnectorTransport.remote)
                Text("Command on this Mac").tag(ClickyConnectorTransport.command)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if connectorTransport == .remote {
                remoteFields
            } else {
                commandFields
            }

            if let validationIssue {
                Text(validationIssue.message)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.destructiveText)
            }
            if connectorTransport == .remote,
               ClickyConnectorParsing.validateRemoteURL(serverURL).warning == .plainHTTP {
                Text(ClickyConnectorWarning.plainHTTP.message)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
            }
            if editingConnectorID != nil && connectorTransport == .remote {
                Text("Changing the server or client ID clears its saved credentials. Save, then sign in again or add the new key.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await save() }
                } label: {
                    Text(editingConnectorID == nil ? "Add connector" : "Save")
                }
                .buttonStyle(ClickyGlossyPillButtonStyle.accent)
                .disabled(isSaving)
                .pointerCursor()

                Button("Cancel") { isEditorVisible = false }
                    .buttonStyle(ClickyGlossyPillButtonStyle.light)

                Text("Press Enter to save")
                    .font(.system(size: 10.5))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledField(String(localized: "Server URL")) {
                TextField(String(localized: "e.g. https://mcp.example.com/mcp"), text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
            }
            labeledField(String(localized: "Authentication")) {
                Picker("", selection: $authentication) {
                    Text("None").tag(Authentication.none)
                    Text("API key").tag(Authentication.apiKey)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if authentication == .apiKey {
                SecureField(String(localized: "Paste your key"), text: $apiToken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
            }
            DisclosureGroup(isExpanded: $showsAdvanced) {
                labeledField(String(localized: "Extra headers")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $extraHeadersText)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 54)
                        Text("One per line, like X-Api-Key: value.")
                            .font(.system(size: 10.5))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            } label: {
                Text("Advanced")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    private var commandFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledField(String(localized: "Command on this Mac")) {
                TextField(String(localized: "e.g. npx"), text: $commandText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
            }
            labeledField(String(localized: "Arguments")) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(String(localized: "e.g. -y some-mcp-server --flag value"), text: $argumentsText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await save() } }
                    Text("Everything after the command, quoted like a shell.")
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            labeledField(String(localized: "Environment variables")) {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $environmentText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 54)
                    Text("One per line, like API_TOKEN=value. Kept in your Keychain.")
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    // MARK: - Actions

    private func beginEditing(_ connector: ClickyCustomConnector?) {
        validationIssue = nil
        editingConnectorID = connector?.id
        connectorName = connector?.name ?? ""
        connectorTransport = connector?.transport ?? .remote
        serverURL = connector?.url ?? ""
        commandText = connector?.command ?? ""
        argumentsText = (connector?.arguments ?? []).map(Self.quoteIfNeeded).joined(separator: " ")
        if let connector {
            apiToken = connectorStore.token(for: connector.id)
            authentication = apiToken.isEmpty ? .none : .apiKey
            extraHeadersText = connectorStore.headersText(for: connector.id)
            environmentText = connectorStore.environmentText(for: connector.id)
        } else {
            apiToken = ""
            authentication = .none
            extraHeadersText = ""
            environmentText = ""
        }
        showsAdvanced = !extraHeadersText.isEmpty
        isEditorVisible = true
    }

    private func save() async {
        guard !isSaving else { return }
        guard let arguments = ClickyConnectorParsing.tokenizeArguments(argumentsText) else {
            validationIssue = .unbalancedQuotes
            return
        }
        isSaving = true
        defer { isSaving = false }

        let connector = ClickyCustomConnector(
            id: editingConnectorID ?? UUID().uuidString,
            name: connectorName,
            transport: connectorTransport,
            command: commandText,
            arguments: arguments,
            url: serverURL,
            isEnabled: connectorStore.connectors.first(where: { $0.id == editingConnectorID })?.isEnabled ?? true
        )
        let issue = await connectorStore.save(
            connector,
            token: authentication == .apiKey ? apiToken : "",
            environmentText: environmentText,
            headersText: extraHeadersText,
            requiresToken: authentication == .apiKey
        )
        validationIssue = issue
        if issue == nil { isEditorVisible = false }
    }

    private static func quoteIfNeeded(_ argument: String) -> String {
        let needsQuoting = argument.isEmpty || argument.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" })
        guard needsQuoting else { return argument }
        let escaped = argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Layout helpers

    private func labeledField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            field()
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        ClickySettingsSectionCard(title: title, content: content)
    }
}
