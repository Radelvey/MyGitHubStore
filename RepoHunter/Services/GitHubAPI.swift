import Foundation

enum GitHubError: LocalizedError {
    case rateLimited(resetAt: Date?, authenticated: Bool)
    case unauthorized
    case notFound
    case validation(String)
    case http(Int)
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case let .rateLimited(resetAt, authenticated):
            var s = "GitHub API 请求次数已达上限"
            if let resetAt {
                let f = DateFormatter()
                f.timeStyle = .short
                f.dateStyle = .none
                s += "，将在 \(f.string(from: resetAt)) 重置"
            }
            s += authenticated
                ? "。"
                : "。在「设置」中填写 Personal Access Token 可将额度从每小时 60 次提升到 5000 次。"
            return s
        case .unauthorized:
            return "GitHub Token 无效或已过期，请在「设置」中检查。"
        case .notFound:
            return "未找到请求的资源。"
        case let .validation(m):
            return "搜索条件无效：\(m)"
        case let .http(code):
            return "GitHub 返回错误（HTTP \(code)）。"
        case let .network(m):
            return "网络连接失败：\(m)"
        case let .decoding(m):
            return "数据解析失败：\(m)"
        }
    }

    var isRateLimit: Bool {
        if case .rateLimited = self { return true }
        return false
    }
}

struct RateLimitInfo: Equatable {
    var remaining: Int
    var limit: Int
    var resetAt: Date?
}

/// Thin async wrapper over the GitHub REST API.
final class GitHubAPI {
    static let shared = GitHubAPI()

    private let session: URLSession
    private let decoder = GitHubCoding.makeDecoder()
    private let base = URL(string: "https://api.github.com")!

    /// Last seen rate-limit headers (informational only).
    private let rateLock = NSLock()
    private var _rate: RateLimitInfo?
    var lastRate: RateLimitInfo? {
        rateLock.lock(); defer { rateLock.unlock() }
        return _rate
    }

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    // MARK: Requests

    private func makeRequest(path: String, query: [URLQueryItem] = [], accept: String = "application/vnd.github+json") -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("RepoHunter-macOS", forHTTPHeaderField: "User-Agent")
        if let token = TokenBox.shared.value, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GitHubError.http(-1) }
        recordRate(http)

        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            if remaining == 0 || http.statusCode == 429 || retryAfter != nil {
                var reset: Date? = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                    .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
                if reset == nil, let retryAfter { reset = Date().addingTimeInterval(retryAfter) }
                throw GitHubError.rateLimited(resetAt: reset, authenticated: TokenBox.shared.value?.isEmpty == false)
            }
            // Secondary rate limits / abuse detection come back as 403 with a message.
            if let msg = String(data: data, encoding: .utf8), msg.lowercased().contains("rate limit") {
                throw GitHubError.rateLimited(resetAt: nil, authenticated: TokenBox.shared.value?.isEmpty == false)
            }
            throw GitHubError.http(http.statusCode)
        case 404:
            throw GitHubError.notFound
        case 422:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GitHubError.validation(message ?? "Unprocessable")
        default:
            throw GitHubError.http(http.statusCode)
        }
    }

    private func recordRate(_ http: HTTPURLResponse) {
        guard let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
              let limit = http.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init) else { return }
        let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        rateLock.lock()
        _rate = RateLimitInfo(remaining: remaining, limit: limit, resetAt: reset)
        rateLock.unlock()
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw GitHubError.decoding(error.localizedDescription) }
    }

    // MARK: Endpoints

    func searchRepos(query: String, sort: SearchSort, page: Int, perPage: Int = 30) async throws -> GHSearchResponse {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page))
        ]
        if let s = sort.apiValue {
            items.append(URLQueryItem(name: "sort", value: s))
            items.append(URLQueryItem(name: "order", value: "desc"))
        }
        let (data, _) = try await perform(makeRequest(path: "search/repositories", query: items))
        return try decode(GHSearchResponse.self, from: data)
    }

    /// Latest non-draft, non-prerelease release. Returns nil when the repo has none.
    func latestRelease(fullName: String) async throws -> GHRelease? {
        do {
            let (data, _) = try await perform(makeRequest(path: "repos/\(fullName)/releases/latest"))
            return try decode(GHRelease.self, from: data)
        } catch GitHubError.notFound {
            return nil
        }
    }

    func releases(fullName: String, perPage: Int = 30) async throws -> [GHRelease] {
        let q = [URLQueryItem(name: "per_page", value: String(perPage))]
        let (data, _) = try await perform(makeRequest(path: "repos/\(fullName)/releases", query: q))
        return try decode([GHRelease].self, from: data).filter { !$0.draft }
    }

    /// README as raw Markdown, nil when the repo has none.
    func readme(fullName: String) async throws -> String? {
        do {
            let (data, _) = try await perform(
                makeRequest(path: "repos/\(fullName)/readme", accept: "application/vnd.github.raw+json"))
            return String(data: data, encoding: .utf8)
        } catch GitHubError.notFound {
            return nil
        }
    }

    /// Validates the token; returns the user's login.
    func verifyToken() async throws -> String {
        let (data, _) = try await perform(makeRequest(path: "user"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["login"] as? String) ?? "unknown"
    }

    func fetchData(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("RepoHunter-macOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GitHubError.http(-1) }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as GitHubError {
            throw e
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
    }
}
