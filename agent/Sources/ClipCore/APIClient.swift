import Foundation

public enum APIError: Error, Equatable {
    case status(Int)
    case invalidResponse
}

/// Thin async client for the copy-memory backend running in Docker.
public final class APIClient: @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private struct ListResponse: Decodable { let items: [ClipItem] }
    private struct PayloadResponse: Decodable { let items: [[String: String]] }

    public func health() async -> Bool {
        (try? await send(request("api/health"))) != nil
    }

    @discardableResult
    public func add(_ snapshot: Snapshot) async throws -> ClipItem {
        var req = request("api/items", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: snapshot.jsonObject())
        return try decoder.decode(ClipItem.self, from: await send(req))
    }

    public func list(query: String = "", limit: Int = 100) async throws -> [ClipItem] {
        let req = request("api/items", query: [.init(name: "q", value: query), .init(name: "limit", value: String(limit))])
        return try decoder.decode(ListResponse.self, from: await send(req)).items
    }

    public func payload(id: Int) async throws -> [[String: Data]] {
        let response = try decoder.decode(PayloadResponse.self, from: await send(request("api/items/\(id)/payload")))
        return try response.items.map { item in
            try item.mapValues { value in
                guard let data = Data(base64Encoded: value) else { throw APIError.invalidResponse }
                return data
            }
        }
    }

    public func use(id: Int) async throws {
        _ = try await send(request("api/items/\(id)/use", method: "POST"))
    }

    public func setPinned(id: Int, pinned: Bool) async throws {
        var req = request("api/items/\(id)/pin", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["pinned": pinned])
        _ = try await send(req)
    }

    public func delete(id: Int) async throws {
        _ = try await send(request("api/items/\(id)", method: "DELETE"))
    }

    public func thumbnailURL(id: Int) -> URL {
        baseURL.appendingPathComponent("api/items/\(id)/thumbnail")
    }

    // MARK: - plumbing

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!, timeoutInterval: 10)
        req.httpMethod = method
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.status(http.statusCode) }
        return data
    }
}
