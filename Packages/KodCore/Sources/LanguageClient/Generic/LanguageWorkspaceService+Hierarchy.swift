import Foundation
import SourceModel

// Call and type hierarchy (SPEC 6.1). Both are two-step protocols whose
// follow-up requests carry the server's opaque `data` back verbatim, so
// every entry point here is routed through the provider binding that
// produced the item rather than the target file's URL.

extension LanguageWorkspaceService {
    // MARK: - Call hierarchy

    public func prepareCallHierarchy(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedHierarchyItem] {
        let advertised = await capabilities()?.callHierarchyProvider?.isEnabled == true
        guard await isAvailable(.prepareCallHierarchy, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/prepareCallHierarchy")
        }
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let request = try await captureProviderRequest(connection: connection)
        let encoding = request.binding.positionEncoding
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let items: CallHierarchyPrepareResult = try await connection.sendRequest(
            .prepareCallHierarchy,
            params: CallHierarchyPrepareParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            )
        )
        try await validateProviderResponse(request)
        return (items ?? []).compactMap {
            ProviderBoundResultBuilder.hierarchyItem($0, binding: request.binding)
        }
    }

    public func callHierarchyIncomingCalls(item: ValidatedHierarchyItem) async throws -> [ValidatedIncomingCall] {
        let connection = try connected()
        let request = try captureProviderRequest(
            connection: connection,
            binding: item.provider
        )
        let calls: CallHierarchyIncomingCallsResult = try await connection.sendRequest(
            .callHierarchyIncomingCalls,
            params: CallHierarchyIncomingCallsParams(
                item: ProviderBoundResultBuilder.wireCallHierarchyItem(item)
            )
        )
        try await validateProviderResponse(request)
        return (calls ?? []).compactMap { call in
            guard let from = ProviderBoundResultBuilder.hierarchyItem(
                call.from,
                binding: request.binding
            ) else {
                return nil
            }
            return ValidatedIncomingCall(from: from, fromRanges: call.fromRanges)
        }
    }

    public func callHierarchyOutgoingCalls(item: ValidatedHierarchyItem) async throws -> [ValidatedOutgoingCall] {
        let connection = try connected()
        let request = try captureProviderRequest(
            connection: connection,
            binding: item.provider
        )
        let calls: CallHierarchyOutgoingCallsResult = try await connection.sendRequest(
            .callHierarchyOutgoingCalls,
            params: CallHierarchyOutgoingCallsParams(
                item: ProviderBoundResultBuilder.wireCallHierarchyItem(item)
            )
        )
        try await validateProviderResponse(request)
        return (calls ?? []).compactMap { call in
            guard let to = ProviderBoundResultBuilder.hierarchyItem(
                call.to,
                binding: request.binding
            ) else {
                return nil
            }
            return ValidatedOutgoingCall(to: to, fromRanges: call.fromRanges)
        }
    }

    // MARK: - Type hierarchy

    public func prepareTypeHierarchy(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedHierarchyItem] {
        let advertised = await capabilities()?.typeHierarchyProvider?.isEnabled == true
        guard await isAvailable(.prepareTypeHierarchy, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/prepareTypeHierarchy")
        }
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let request = try await captureProviderRequest(connection: connection)
        let encoding = request.binding.positionEncoding
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let items: TypeHierarchyPrepareResult = try await connection.sendRequest(
            .prepareTypeHierarchy,
            params: TypeHierarchyPrepareParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            )
        )
        try await validateProviderResponse(request)
        return (items ?? []).compactMap {
            ProviderBoundResultBuilder.hierarchyItem($0, binding: request.binding)
        }
    }

    public func typeHierarchySupertypes(item: ValidatedHierarchyItem) async throws -> [ValidatedHierarchyItem] {
        let connection = try connected()
        let request = try captureProviderRequest(
            connection: connection,
            binding: item.provider
        )
        let results: TypeHierarchySupertypesResult = try await connection.sendRequest(
            .typeHierarchySupertypes,
            params: TypeHierarchySupertypesParams(
                item: ProviderBoundResultBuilder.wireTypeHierarchyItem(item)
            )
        )
        try await validateProviderResponse(request)
        return (results ?? []).compactMap {
            ProviderBoundResultBuilder.hierarchyItem($0, binding: request.binding)
        }
    }

    public func typeHierarchySubtypes(item: ValidatedHierarchyItem) async throws -> [ValidatedHierarchyItem] {
        let connection = try connected()
        let request = try captureProviderRequest(
            connection: connection,
            binding: item.provider
        )
        let results: TypeHierarchySubtypesResult = try await connection.sendRequest(
            .typeHierarchySubtypes,
            params: TypeHierarchySubtypesParams(
                item: ProviderBoundResultBuilder.wireTypeHierarchyItem(item)
            )
        )
        try await validateProviderResponse(request)
        return (results ?? []).compactMap {
            ProviderBoundResultBuilder.hierarchyItem($0, binding: request.binding)
        }
    }
}
