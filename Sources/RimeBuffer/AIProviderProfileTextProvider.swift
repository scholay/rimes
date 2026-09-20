import Foundation

/// Dispatches ordinary Buffer AI generation through a saved Provider route.
///
/// The legacy `OpenAICompatibleTextProvider` remains available for isolated
/// smoke seams and older integrations. The live connector registry uses this
/// type instead so multiple provider profiles can coexist without sharing a
/// mutable singleton endpoint or credential.
final class AIProviderProfileTextProvider: AITextProvider {
    let kind: AITextProviderKind = .openAICompatible

    private let selectionStore: AITextConnectorSelectionStore
    private let catalogStore: AIProviderProfileCatalogStore
    private let sessionConfigurationFactory: () -> URLSessionConfiguration

    init(
        selectionStore: AITextConnectorSelectionStore = .shared,
        catalogStore: AIProviderProfileCatalogStore = .shared,
        sessionConfigurationFactory: @escaping () -> URLSessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = AITextRuntimeLimits.defaultTimeout
            configuration.timeoutIntervalForResource = AITextRuntimeLimits.defaultTimeout
            configuration.waitsForConnectivity = false
            return configuration
        }
    ) {
        self.selectionStore = selectionStore
        self.catalogStore = catalogStore
        self.sessionConfigurationFactory = sessionConfigurationFactory
    }

    var availability: AITextProviderAvailability {
        do {
            guard let reference = try selectionStore.selectedProviderRouteReference(
                catalogStore: catalogStore
            ) else {
                return .unavailable("请先选择一个可用的 Provider 文本模型")
            }
            _ = try resolvedTextRoute(reference)
            return .ready
        } catch let error as AIProviderProfileStoreError {
            return .unavailable(error.localizedDescription)
        } catch {
            return .unavailable("Provider 配置不可用")
        }
    }

    @discardableResult
    func generate(
        _ request: AITextProviderRequest,
        onEvent: @escaping (AITextProviderEvent) -> Void,
        completion: @escaping (Result<[AITextProviderBlock], AITextProviderError>) -> Void
    ) -> any AITextCancellable {
        let reference: AIProviderRouteReference
        do {
            if let frozen = request.providerRoute {
                reference = frozen
            } else if let selected = try selectionStore.selectedProviderRouteReference(
                catalogStore: catalogStore
            ) {
                reference = selected
            } else {
                throw AIProviderProfileStoreError.missingRoute
            }
            let resolved = try resolvedTextRoute(reference)
            let configuration = OpenAICompatibleConfiguration(
                baseURL: resolved.route.endpointOverride ?? resolved.profile.baseURL,
                // A route's selected model is part of the frozen profile
                // revision. Do not accept a later free-form preference here.
                model: resolved.route.modelID ?? "",
                apiKey: resolved.apiKey ?? ""
            )
            let urlRequest = try AITextOpenAIRequestBuilder.makeRequest(
                configuration: configuration,
                sourceText: request.sourceText,
                preparedPrompt: request.preparedPrompt,
                outputContract: request.outputContract,
                maximumAlternativeGuessCount: request.maximumAlternativeGuessCount
            )
            let operation = AITextOpenAIStreamOperation(
                request: urlRequest,
                diagnosticRequestID: request.requestID,
                outputContract: request.outputContract,
                maximumAlternativeGuessCount: request.maximumAlternativeGuessCount,
                sessionConfiguration: sessionConfigurationFactory(),
                onEvent: onEvent,
                completion: completion
            )
            operation.start()
            return operation
        } catch let error as AIProviderProfileStoreError {
            completion(.failure(.invalidConfiguration(error.localizedDescription)))
            return AITextNoopCancellation()
        } catch let error as AITextProviderError {
            completion(.failure(error))
            return AITextNoopCancellation()
        } catch {
            completion(.failure(.invalidConfiguration("Provider 配置不可用")))
            return AITextNoopCancellation()
        }
    }

    private func resolvedTextRoute(
        _ reference: AIProviderRouteReference
    ) throws -> AIProviderResolvedRoute {
        let resolved = try catalogStore.resolve(reference)
        guard resolved.route.adapter == .openAIChatCompletions,
              resolved.route.capabilities.contains(.textGeneration),
              resolved.route.capabilities.contains(.streamingText) else {
            throw AIProviderProfileStoreError.invalidConfiguration(
                "该模型路由不能用于普通文本生成"
            )
        }
        return resolved
    }
}
