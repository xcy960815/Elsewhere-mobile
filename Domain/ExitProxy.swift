import Foundation
import Network

struct ExitInfo: Codable, Equatable, Sendable {
    let ip: String
    let city: String
    let region: String
    let country: String
    let coordinate: WGS84Coordinate
    let org: String?
    let sampledAt: Date

    private var locality: String { city.isEmpty ? region : city }
    var displayCity: String { locality.isEmpty ? (Locale.current.localizedString(forRegionCode: country) ?? country) : locality }

    func summary(locale: Locale) -> String {
        guard !country.isEmpty else { return locality }
        let countryName = locale.localizedString(forRegionCode: country) ?? country
        guard !locality.isEmpty, locality != countryName else { return countryName }
        return locale.language.languageCode == .chinese ? "\(locality)，\(countryName)" : "\(locality), \(countryName)"
    }
}

enum ExitProxyParseError: LocalizedError, Equatable, Sendable {
    case empty, missingPort, emptyHost, invalidHost, invalidPort

    var errorDescription: String? {
        switch self {
        case .empty: String(localized: "请输入代理地址")
        case .missingPort: String(localized: "请输入代理端口")
        case .emptyHost: String(localized: "请输入代理主机")
        case .invalidHost: String(localized: "请输入有效的主机名或 IP 地址，IPv6 地址须加方括号")
        case .invalidPort: String(localized: "代理端口须为 1 到 65535 的十进制整数")
        }
    }
}

struct ExitProxyAddress: Equatable, Hashable, Codable, Sendable {
    let host: String
    let port: Int
    var isIPv6: Bool { host.contains(":") }
    var display: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }

    static func parse(_ text: String) -> Result<Self, ExitProxyParseError> {
        Result { () throws(ExitProxyParseError) in try Self(parsing: text) }
    }

    init?(_ text: String) {
        try? self.init(parsing: text)
    }

    private init(parsing text: String) throws(ExitProxyParseError) {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw .empty }
        guard !address.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }),
              address.rangeOfCharacter(from: .controlCharacters) == nil else { throw .invalidHost }
        let portField: Substring
        if address.first == "[" {
            guard let end = address.firstIndex(of: "]") else { throw .invalidHost }
            host = String(address[address.index(after: address.startIndex)..<end])
            guard !host.isEmpty else { throw .emptyHost }
            guard IPv6Address(host) != nil else { throw .invalidHost }
            let suffix = address[address.index(after: end)...]
            guard !suffix.isEmpty else { throw .missingPort }
            guard suffix.first == ":" else { throw .invalidHost }
            portField = suffix.dropFirst()
        } else {
            let fields = address.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count <= 2 else { throw .invalidHost }
            host = String(fields[0])
            guard !host.isEmpty else { throw .emptyHost }
            let name = host.last == "." ? host.dropLast() : host[...]
            let labels = name.split(separator: ".", omittingEmptySubsequences: false)
            guard !name.isEmpty, name.utf8.count <= 253, labels.allSatisfy({ label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }) else { throw .invalidHost }
            if labels.count > 1, name.allSatisfy({ $0.isNumber || $0 == "." }), IPv4Address(String(name)) == nil {
                throw .invalidHost
            }
            guard fields.count == 2 else { throw .missingPort }
            portField = fields[1]
        }
        guard !portField.isEmpty else { throw .missingPort }
        guard portField.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(portField), (1...65535).contains(port) else { throw .invalidPort }
        self.port = port
    }

    init(from decoder: Decoder) throws {
        try self.init(parsing: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(display)
    }
}

enum ExitWatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, notify, auto
    var id: String { rawValue }
}
