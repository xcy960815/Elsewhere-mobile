import Darwin
import Foundation
import Network
import os

protocol HTTPDataTransport: Sendable {
    func data(for request: URLRequest, proxy: ExitProxyAddress?) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPTransport: HTTPDataTransport {
    private static let sessions = OSAllocatedUnfairLock(initialState: [ExitProxyAddress?: URLSession]())

    func data(for request: URLRequest, proxy: ExitProxyAddress?) async throws -> (Data, HTTPURLResponse) {
        let session = Self.sessions.withLock { sessions in
            if let session = sessions[proxy] { return session }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.httpAdditionalHeaders = ["User-Agent": "Elsewhere-iOS", "Accept": "application/json"]
            if let proxy {
                let endpoint = NWEndpoint.hostPort(host: .init(proxy.host), port: .init(rawValue: UInt16(proxy.port))!)
                var proxyConfig = ProxyConfiguration(httpCONNECTProxy: endpoint)
                proxyConfig.allowFailover = false
                config.proxyConfigurations = [proxyConfig]
            }
            let session = URLSession(configuration: config)
            sessions[proxy] = session
            return session
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum ExitIPError: LocalizedError, Equatable, Sendable {
    case http(Int, String), badResponse(String), proxy(String, String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body): "HTTP \(status)：\(body)"
        case .badResponse(let body): String(localized: "出口服务返回了无效内容：\(body)")
        case .proxy(let address, let reason): String(localized: "无法通过代理 \(address) 查询：\(reason)")
        }
    }
}

struct ExitIPService: Sendable {
    private let transport: HTTPDataTransport
    private let now: @Sendable () -> Date

    init(transport: HTTPDataTransport = URLSessionHTTPTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    func lookup(proxy: ExitProxyAddress? = nil) async throws -> ExitInfo {
        struct Response: Decodable {
            let ip, loc: String
            let city, region, country, org: String?
        }
        let data = try await fetch("https://ipinfo.io/json", proxy: proxy)
        guard let raw = try? JSONDecoder().decode(Response.self, from: data),
              let ip = canonicalIP(raw.ip),
              case .success(let coordinate) = CoordinateParser.parse(raw.loc) else {
            throw ExitIPError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return ExitInfo(ip: ip, city: raw.city ?? "", region: raw.region ?? "", country: raw.country ?? "",
                        coordinate: coordinate, org: raw.org, sampledAt: now())
    }

    func currentIP(proxy: ExitProxyAddress? = nil) async throws -> String {
        do {
            return try await ip(from: "https://api.ipify.org", proxy: proxy)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            return try await ip(from: "https://ipinfo.io/ip", proxy: proxy)
        }
    }

    private func ip(from url: String, proxy: ExitProxyAddress?) async throws -> String {
        let data = try await fetch(url, proxy: proxy)
        guard let ip = canonicalIP(String(decoding: data, as: UTF8.self)) else {
            throw ExitIPError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return ip
    }

    private func canonicalIP(_ raw: String) -> String? {
        let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty, ip.utf8.count < Int(INET6_ADDRSTRLEN),
              ip.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else { return nil }
        let bytes: Data
        let family: Int32
        if let address = IPv4Address(ip) {
            (bytes, family) = (address.rawValue, AF_INET)
        } else if let address = IPv6Address(ip) {
            (bytes, family) = (address.rawValue, AF_INET6)
        } else { return nil }
        return bytes.withUnsafeBytes { source in
            withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(INET6_ADDRSTRLEN)) { buffer in
                Darwin.inet_ntop(family, source.baseAddress, buffer.baseAddress, socklen_t(buffer.count)).map { String(cString: $0) }
            }
        }
    }

    private func fetch(_ url: String, proxy: ExitProxyAddress?) async throws -> Data {
        try Task.checkCancellation()
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.data(for: URLRequest(url: URL(string: url)!), proxy: proxy)
        } catch {
            guard let proxy, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { throw error }
            throw ExitIPError.proxy(proxy.display, error.localizedDescription)
        }
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            throw ExitIPError.http(response.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
}
