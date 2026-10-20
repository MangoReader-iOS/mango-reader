import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderSources
import Observation
import SwiftUI

struct AddSourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let initialKind: SourceKind
    private let initialConnectorID: String?
    @State private var connectorID: String
    @State private var name = ""
    @State private var address = ""
    @State private var kind: SourceKind
    @State private var authentication: SourceAuthenticationMode = .none
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var apiKeyHeader = "X-Api-Key"
    @State private var apiKeyValue = ""
    @State private var filterSelections: [String: String]
    @State private var languageCodes = ""
    @State private var confirmsLANHTTP = false
    @State private var fieldErrors: [AddSourceField: String] = [:]
    @State private var unexpectedErrorMessage: String?
    @State private var isAdding = false
    @State private var isCancelling = false
    @State private var isConfirmingDiscard = false
    @State private var selectedDetent: PresentationDetent = .large
    @State private var addTask: Task<Void, Never>?
    @State private var activeOperationID: UUID?
    @FocusState private var focusedField: AddSourceField?

    init(initialKind: SourceKind = .opds, initialConnectorID: String? = nil) {
        self.initialKind = initialKind
        self.initialConnectorID = initialConnectorID
        _connectorID = State(initialValue: initialConnectorID ?? "")
        _kind = State(initialValue: initialKind)
        _filterSelections = State(
            initialValue: CompiledSourceFilterCatalog.shared.defaultSelections(
                for: initialKind,
                scope: .configuration
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Type", value: kind.displayName)
                        .accessibilityIdentifier("add-source-type")
                    if let connector = model.sourcesModel.availableConnectors(for: kind).first(where: { $0.id == connectorID }) {
                        LabeledContent("Connector", value: connector.descriptor.name)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        RequiredFieldLabel("Name")
                        TextField("Name", text: $name, prompt: Text("Required"))
                            .textContentType(.organizationName)
                            .focused($focusedField, equals: .name)
                            .accessibilityIdentifier("add-source-name")
                        FieldErrorText(fieldErrors[.name])
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        RequiredFieldLabel("Server address")
                        TextField("Server address", text: $address, prompt: Text("https://example.com"))
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.done)
                            .focused($focusedField, equals: .address)
                            .accessibilityIdentifier("add-source-address")
                        FieldErrorText(fieldErrors[.address])
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Languages")
                            .font(.subheadline.weight(.semibold))
                        TextField("Languages (optional)", text: $languageCodes, prompt: Text("Optional, comma-separated codes"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .browseListRow()

                if !configurationFilterDefinitions.isEmpty {
                    Section("Catalog Settings") {
                        ForEach(configurationFilterDefinitions) { definition in
                            SourceFilterField(
                                definition: definition,
                                value: sourceFilterBinding(for: definition),
                                errorMessage: fieldErrors[.filter(definition.key)],
                                focus: $focusedField
                            )
                        }
                    }
                    .browseListRow()
                }

                Section {
                    Picker("Method", selection: $authentication) {
                        ForEach(SourceAuthenticationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    switch authentication {
                    case .none:
                        EmptyView()
                    case .basic:
                        VStack(alignment: .leading, spacing: 6) {
                            RequiredFieldLabel("Username")
                            TextField("Username", text: $username, prompt: Text("Required"))
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .username)
                            FieldErrorText(fieldErrors[.username])
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            RequiredFieldLabel("Password")
                            SecureField("Password", text: $password, prompt: Text("Required"))
                                .textContentType(.password)
                                .focused($focusedField, equals: .password)
                            FieldErrorText(fieldErrors[.password])
                        }
                    case .bearer:
                        VStack(alignment: .leading, spacing: 6) {
                            RequiredFieldLabel("Bearer token")
                            SecureField("Bearer token", text: $token, prompt: Text("Required"))
                                .textContentType(.password)
                                .focused($focusedField, equals: .token)
                            FieldErrorText(fieldErrors[.token])
                        }
                    case .apiKey:
                        VStack(alignment: .leading, spacing: 6) {
                            RequiredFieldLabel("Header name")
                            TextField("Header name", text: $apiKeyHeader, prompt: Text("Required"))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .apiKeyHeader)
                            FieldErrorText(fieldErrors[.apiKeyHeader])
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            RequiredFieldLabel("API key")
                            SecureField("API key", text: $apiKeyValue, prompt: Text("Required"))
                                .textContentType(.password)
                                .focused($focusedField, equals: .apiKeyValue)
                            FieldErrorText(fieldErrors[.apiKeyValue])
                        }
                    }
                } header: {
                    Text("Authentication")
                }
                .browseListRow()

                if URL(string: address)?.scheme?.lowercased() == "http" {
                    Section {
                        Toggle("This is my local network server", isOn: $confirmsLANHTTP)
                    }
                    .browseListRow()
                }

                if isAdding {
                    Section {
                        HStack {
                            ProgressView()
                            Text(isCancelling ? "Cancelling connection test…" : "Testing connection and capabilities…")
                        }
                    }
                    .browseListRow()
                }
            }
            .browseGroupedForm()
            .disabled(isAdding)
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button(isCancelling ? "Cancelling…" : "Cancel") {
                            requestCancellationOrDismissal()
                        }
                        .disabled(isCancelling)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button("Add") { add() }
                            .accessibilityIdentifier("add-source-confirm")
                            .disabled(isAdding)
                    }
                }
            }
        }
        .appFeedbackOverlay()
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isDirty || isAdding)
        .onChange(of: kind, initial: true) { _, newKind in
            if newKind != initialKind { connectorID = "" }
            filterSelections = CompiledSourceFilterCatalog.shared.defaultSelections(
                for: newKind,
                scope: .configuration
            )
            fieldErrors = [:]
        }
        .onChange(of: name) { _, _ in fieldErrors[.name] = nil }
        .onChange(of: address) { _, _ in fieldErrors[.address] = nil }
        .onChange(of: authentication) { _, _ in
            fieldErrors[.username] = nil
            fieldErrors[.password] = nil
            fieldErrors[.token] = nil
            fieldErrors[.apiKeyHeader] = nil
            fieldErrors[.apiKeyValue] = nil
        }
        .onChange(of: username) { _, _ in fieldErrors[.username] = nil }
        .onChange(of: password) { _, _ in fieldErrors[.password] = nil }
        .onChange(of: token) { _, _ in fieldErrors[.token] = nil }
        .onChange(of: apiKeyHeader) { _, _ in fieldErrors[.apiKeyHeader] = nil }
        .onChange(of: apiKeyValue) { _, _ in fieldErrors[.apiKeyValue] = nil }
        .onDisappear { addTask?.cancel() }
        .confirmationDialog(
            "Discard Server Details?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The server details and credentials you entered have not been saved.")
        }
        .alert(
            "Cannot Add Server",
            isPresented: Binding(
                get: { unexpectedErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { unexpectedErrorMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(unexpectedErrorMessage ?? "Check the server details and try again.")
        }
    }

    private func add() {
        guard !isAdding else { return }
        unexpectedErrorMessage = nil
        fieldErrors = validationErrors()
        guard fieldErrors.isEmpty else {
            focusedField = firstInvalidField
            return
        }

        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showInlineError("Enter a valid server address.", for: .address)
            return
        }

        let credential: SourceCredential?
        switch authentication {
        case .none:
            credential = nil
        case .basic:
            credential = .basic(username: username, password: password)
        case .bearer:
            credential = .bearer(token: token)
        case .apiKey:
            credential = .apiKey(name: apiKeyHeader, value: apiKeyValue)
        }

        let catalogOptions: [String: String]
        do {
            catalogOptions = try CompiledSourceFilterCatalog.shared.normalize(
                filterSelections,
                for: kind,
                scope: .configuration
            )
        } catch {
            showFilterError(error)
            return
        }

        guard model.sourcesModel.availableConnectors(for: kind).contains(where: { $0.id == connectorID }) else {
            unexpectedErrorMessage = "Install and enable a matching server extension before adding this connection."
            return
        }
        var options = catalogOptions
        if !connectorID.isEmpty { options["connectorExtensionID"] = connectorID }
        if confirmsLANHTTP {
            options["allowsLANHTTP"] = "true"
        }

        do {
            try EndpointPolicy().validate(url, access: EndpointAccess(allowsUserConfirmedLANHTTP: confirmsLANHTTP))
        } catch {
            showInlineError(error.localizedDescription, for: .address)
            return
        }

        let operationID = UUID()
        let existingSourceIDs = Set(model.sourcesModel.sources.map(\.id))
        activeOperationID = operationID
        isAdding = true
        isCancelling = false

        addTask = Task { @MainActor in
            do {
                try await model.sourcesModel.addSource(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: kind,
                    baseURL: url,
                    languageCodes: languageCodes
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .filter { !$0.isEmpty },
                    credential: credential,
                    options: options
                )
                if Task.isCancelled || isCancelling || activeOperationID != operationID {
                    removeSourceAddedByCancelledOperation(
                        existingSourceIDs: existingSourceIDs,
                        kind: kind,
                        baseURL: url
                    )
                } else {
                    finishAddOperation(operationID)
                    dismiss()
                    return
                }
            } catch {
                if !(error is CancellationError), !Task.isCancelled,
                   activeOperationID == operationID, !isCancelling {
                    unexpectedErrorMessage = error.localizedDescription
                }
            }

            guard activeOperationID == operationID else { return }
            let shouldDismiss = isCancelling
            finishAddOperation(operationID)
            if shouldDismiss {
                dismiss()
            }
        }
    }

    private func requestCancellationOrDismissal() {
        if isAdding {
            isCancelling = true
            addTask?.cancel()
        } else if isDirty {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func finishAddOperation(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        addTask = nil
        isAdding = false
        isCancelling = false
    }

    private func removeSourceAddedByCancelledOperation(
        existingSourceIDs: Set<SourceID>,
        kind: SourceKind,
        baseURL: URL
    ) {
        let offsets = IndexSet(model.sourcesModel.sources.indices.filter { index in
            let source = model.sourcesModel.sources[index]
            return !existingSourceIDs.contains(source.id)
                && source.kind == kind
                && source.baseURL == baseURL
        })
        if !offsets.isEmpty {
            model.removeSources(at: offsets)
        }
    }

    private func validationErrors() -> [AddSourceField: String] {
        var errors: [AddSourceField: String] = [:]
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors[.name] = "Enter a name for this server."
        }
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors[.address] = "Enter the server address."
        }
        for definition in configurationFilterDefinitions where definition.isRequired {
            let value = filterSelections[definition.key] ?? definition.defaultValue ?? ""
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors[.filter(definition.key)] = "Enter \(definition.title.lowercased())."
            }
        }
        switch authentication {
        case .none:
            break
        case .basic:
            if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors[.username] = "Enter a username."
            }
            if password.isEmpty {
                errors[.password] = "Enter a password."
            }
        case .bearer:
            if token.isEmpty {
                errors[.token] = "Enter a bearer token."
            }
        case .apiKey:
            if apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors[.apiKeyHeader] = "Enter the API-key header name."
            }
            if apiKeyValue.isEmpty {
                errors[.apiKeyValue] = "Enter the API key."
            }
        }
        return errors
    }

    private var firstInvalidField: AddSourceField? {
        let orderedFields: [AddSourceField] = [
            .name,
            .address,
        ] + configurationFilterDefinitions.map { .filter($0.key) } + [
            .username,
            .password,
            .token,
            .apiKeyHeader,
            .apiKeyValue,
        ]
        return orderedFields.first(where: { fieldErrors[$0] != nil })
    }

    private func showInlineError(_ message: String, for field: AddSourceField) {
        fieldErrors[field] = message
        focusedField = field
    }

    private func showFilterError(_ error: Error) {
        if let filterError = error as? SourceFilterValidationError {
            switch filterError {
            case let .missingRequiredValue(_, key, _), let .invalidValue(_, key, _):
                showInlineError(filterError.localizedDescription, for: .filter(key))
            default:
                unexpectedErrorMessage = filterError.localizedDescription
            }
        } else {
            unexpectedErrorMessage = error.localizedDescription
        }
    }

    private var isDirty: Bool {
        !name.isEmpty
            || !address.isEmpty
            || kind != initialKind
            || connectorID != (initialConnectorID ?? "")
            || authentication != .none
            || !username.isEmpty
            || !password.isEmpty
            || !token.isEmpty
            || apiKeyHeader != "X-Api-Key"
            || !apiKeyValue.isEmpty
            || filterSelections != CompiledSourceFilterCatalog.shared.defaultSelections(
                for: kind,
                scope: .configuration
            )
            || !languageCodes.isEmpty
            || confirmsLANHTTP
    }

    private var configurationFilterDefinitions: [SourceFilterDefinition] {
        CompiledSourceFilterCatalog.shared.definitions(for: kind, scope: .configuration)
    }

    private func sourceFilterBinding(for definition: SourceFilterDefinition) -> Binding<String> {
        Binding(
            get: {
                filterSelections[definition.key]
                    ?? definition.defaultValue
                    ?? ""
            },
            set: { newValue in
                filterSelections[definition.key] = newValue
                fieldErrors[.filter(definition.key)] = nil
            }
        )
    }
}

enum AddSourceField: Hashable {
    case name
    case address
    case filter(String)
    case username
    case password
    case token
    case apiKeyHeader
    case apiKeyValue
}

private struct RequiredFieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text("Required")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FieldErrorText: View {
    let message: String?

    init(_ message: String?) {
        self.message = message
    }

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(AppColors.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SourceFilterField: View {
    let definition: SourceFilterDefinition
    @Binding var value: String
    let errorMessage: String?
    let focus: FocusState<AddSourceField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch definition.valueKind {
            case .choice:
                Picker(definition.title, selection: $value) {
                    ForEach(definition.options) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            case .opaqueIdentifier:
                if definition.isRequired {
                    RequiredFieldLabel(definition.title)
                } else {
                    Text(definition.title)
                        .font(.subheadline.weight(.semibold))
                }
                TextField(definition.title, text: $value, prompt: Text(definition.isRequired ? "Required" : "Optional"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(focus, equals: .filter(definition.key))
            case .positiveInteger, .nonnegativeInteger:
                if definition.isRequired {
                    RequiredFieldLabel(definition.title)
                } else {
                    Text(definition.title)
                        .font(.subheadline.weight(.semibold))
                }
                TextField(definition.title, text: $value, prompt: Text(definition.isRequired ? "Required" : "Optional"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numberPad)
                    .focused(focus, equals: .filter(definition.key))
            }

            FieldErrorText(errorMessage)

        }
    }
}

private enum SourceAuthenticationMode: String, CaseIterable, Identifiable {
    case none
    case basic
    case bearer
    case apiKey

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .basic: "Username and password"
        case .bearer: "Bearer token"
        case .apiKey: "API key"
        }
    }
}
