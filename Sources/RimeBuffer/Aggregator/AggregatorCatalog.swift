import Foundation

/// One model as the aggregator publishes it. `endpoints` is the useful part
/// and the unreliable part at once: the catalog encodes it four different
/// ways, and a record that looks unusable is usually recoverable.
struct AggregatorModel: Equatable {
    let id: String
    let name: String
    let provider: String
    /// Empty for roughly a third of the catalog, so nothing may branch on it.
    let modelType: String
    let features: [String]
    let endpoints: [AggregatorEndpoint]

    var isUsable: Bool { !endpoints.isEmpty }

    var primaryAdapter: AggregatorAdapter {
        // A model that both submits and polls (video) is named by its submit
        // endpoint; collection is a follow-up request, not a second model.
        endpoints.first { $0.adapter != .videoResult
            && $0.adapter != .videoContent }?.adapter
            ?? endpoints.first?.adapter
            ?? .rawPassthrough
    }
}

enum AggregatorCatalogParser {
    /// The catalog spells `endpoints` four ways, and each needs a different
    /// recovery:
    ///   1. an object of descriptors — the documented form;
    ///   2. an array of bare family names, no paths (123 models);
    ///   3. a descriptor whose value is itself a JSON *string* (`replicate`);
    ///   4. an empty string, empty array, or null — genuinely unusable.
    /// Anything the first three can rescue is worth rescuing: dropping them
    /// would discard more than a third of the models for a formatting
    /// inconsistency upstream.
    static func endpoints(from raw: Any?) -> [AggregatorEndpoint] {
        guard let raw else { return [] }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) else {
                // A bare family name with no JSON around it still resolves.
                return endpointForFamilyName(trimmed).map { [$0] } ?? []
            }
            return endpoints(from: decoded)
        }
        if let names = raw as? [Any] {
            return names.compactMap { $0 as? String }
                .compactMap(endpointForFamilyName)
        }
        guard let object = raw as? [String: Any] else { return [] }
        return object.keys.sorted().compactMap { family -> AggregatorEndpoint? in
            let value = object[family]
            if let descriptor = value as? [String: Any] {
                return endpoint(family: family, descriptor: descriptor)
            }
            // Doubly encoded: the value is a JSON string holding the object.
            if let text = value as? String {
                if let data = text.data(using: .utf8),
                   let inner = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] {
                    return endpoint(family: family, descriptor: inner)
                }
                return endpointForFamilyName(family)
            }
            return endpointForFamilyName(family)
        }
    }

    private static func endpoint(family: String,
                                 descriptor: [String: Any]) -> AggregatorEndpoint? {
        guard let path = (descriptor["path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return endpointForFamilyName(family)
        }
        let method = (descriptor["method"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AggregatorEndpoint(
            family: family,
            method: (method?.isEmpty == false ? method! : "POST").uppercased(),
            path: path
        )
    }

    private static func endpointForFamilyName(_ family: String) -> AggregatorEndpoint? {
        let key = family.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let known = AggregatorEndpointRules.pathForFamily[key] else {
            return nil
        }
        return AggregatorEndpoint(family: key,
                                  method: known.method,
                                  path: known.path)
    }

    static func models(from payload: Data) throws -> [AggregatorModel] {
        guard let root = try JSONSerialization.jsonObject(with: payload)
                as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else {
            throw AggregatorCatalogError.malformedPayload
        }
        return rows.compactMap { row in
            guard let id = (row["id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { return nil }
            return AggregatorModel(
                id: id,
                name: row["name"] as? String ?? id,
                provider: row["provider"] as? String ?? "",
                modelType: row["model_type"] as? String ?? "",
                features: row["features"] as? [String] ?? [],
                endpoints: endpoints(from: row["endpoints"])
            )
        }
    }
}

enum AggregatorCatalogError: Error, Equatable {
    case malformedPayload
    case transport(String)
}

/// The catalog is public — no key — so it is fetched without touching the
/// stored credential, and cached on disk so a request pane opens instantly
/// and keeps working offline.
final class AggregatorCatalogStore {
    static let shared = AggregatorCatalogStore()

    private let fileManager: FileManager
    let cacheURL: URL

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = rootDirectory
            ?? (ProcessInfo.processInfo.environment["RIMEBUFFER_LOCAL_DATA_ROOT"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/RimeBuffer", isDirectory: true)
        cacheURL = root.standardizedFileURL
            .appendingPathComponent("ai", isDirectory: true)
            .appendingPathComponent("aggregator-models.json", isDirectory: false)
    }

    func cachedModels() -> [AggregatorModel] {
        guard let data = try? Data(contentsOf: cacheURL),
              let models = try? AggregatorCatalogParser.models(from: data) else {
            return []
        }
        return models
    }

    /// The catalog carries no secrets and needs no key, so this deliberately
    /// does not read the stored credential: refreshing the model list must
    /// never be a reason to touch it.
    func refresh(baseURL: URL,
                 session: URLSession = .shared,
                 completion: @escaping (Result<[AggregatorModel],
                                        AggregatorCatalogError>) -> Void) {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/models"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: "500"),
        ]
        guard let url = components?.url else {
            completion(.failure(.transport("无法构造模型目录地址")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.transport(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status), let data else {
                completion(.failure(.transport("模型目录返回 HTTP \(status)")))
                return
            }
            do {
                completion(.success(try self.storeCatalog(data)))
            } catch let error as AggregatorCatalogError {
                completion(.failure(error))
            } catch {
                completion(.failure(.transport(error.localizedDescription)))
            }
        }.resume()
    }

    @discardableResult
    func storeCatalog(_ payload: Data) throws -> [AggregatorModel] {
        let models = try AggregatorCatalogParser.models(from: payload)
        let directory = cacheURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try payload.write(to: cacheURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: cacheURL.path)
        return models
    }
}
