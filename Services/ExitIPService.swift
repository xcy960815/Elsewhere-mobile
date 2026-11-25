import CoreLocation
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

    private struct CityExit: Decodable {
        let ip: String
        let location: [String]
    }

    private enum ProviderResponse {
        case ipInfo(Data)
        case city(CityExit)
    }

    private func ipInfo(_ path: String, proxy: ExitProxyAddress?) async throws -> ProviderResponse {
        do {
            do {
                return .ipInfo(try await fetch("https://ipinfo.io/" + path, proxy: proxy))
            } catch let error as URLError where error.code == .secureConnectionFailed {
                // Some networks close TLS connections to IPinfo. Keep the same egress for the retry.
                let data = try await fetch("https://myip.ipip.net/json", proxy: proxy)
                struct Response: Decodable { let ret: String; let data: CityExit }
                guard let reply = try? JSONDecoder().decode(Response.self, from: data), reply.ret == "ok",
                      canonicalIP(reply.data.ip) != nil else {
                    throw ExitIPError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
                }
                return .city(reply.data)
            }
        } catch let error as URLError {
            guard let proxy, error.code != .cancelled else { throw error }
            throw ExitIPError.proxy(proxy.display, error.localizedDescription)
        }
    }

    func lookup(proxy: ExitProxyAddress? = nil) async throws -> ExitInfo {
        struct Response: Decodable {
            let ip, loc: String
            let city, region, country, org: String?
        }
        switch try await ipInfo("json", proxy: proxy) {
        case .ipInfo(let data):
            guard let raw = try? JSONDecoder().decode(Response.self, from: data),
                  let ip = canonicalIP(raw.ip),
                  case .success(let coordinate) = CoordinateParser.parse(raw.loc) else {
                throw ExitIPError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
            }
            return ExitInfo(ip: ip, city: raw.city ?? "", region: raw.region ?? "", country: raw.country ?? "",
                            coordinate: coordinate, org: raw.org, sampledAt: now())
        case .city(let raw):
            let parts = raw.location.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count >= 3, !parts[0].isEmpty, !parts[2].isEmpty, let ip = canonicalIP(raw.ip) else {
                throw ExitIPError.badResponse(String(localized: "备用出口服务未提供城市，无法确定坐标。"))
            }
            let address = parts.prefix(3).filter { !$0.isEmpty }.joined(separator: " ")
            let matches = try await CLGeocoder().geocodeAddressString(address, in: nil, preferredLocale: Locale(identifier: "zh_CN"))
            try Task.checkCancellation()
            guard let match = matches.first, match.locality != nil, let point = match.location?.coordinate,
                  let coordinate = WGS84Coordinate(latitude: point.latitude, longitude: point.longitude) else {
                throw ExitIPError.badResponse(String(localized: "无法解析出口城市坐标。"))
            }
            return ExitInfo(ip: ip, city: parts[2], region: parts[1], country: match.isoCountryCode ?? parts[0],
                            coordinate: coordinate, org: parts.count > 4 ? parts[4] : nil, sampledAt: now())
        }
    }

    func currentIP(proxy: ExitProxyAddress? = nil) async throws -> String {
        do {
            let first = try await fetch("https://api.ipify.org", proxy: proxy)
            return try parsePlainIP(first)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            switch try await ipInfo("ip", proxy: proxy) {
            case .ipInfo(let body): return try parsePlainIP(body)
            case .city(let raw):
                guard let ip = canonicalIP(raw.ip) else { throw ExitIPError.badResponse(raw.ip) }
                return ip
            }
        }
    }

    private func parsePlainIP(_ data: Data) throws -> String {
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
        let (data, response) = try await transport.data(for: URLRequest(url: URL(string: url)!), proxy: proxy)
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            throw ExitIPError.http(response.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
}
