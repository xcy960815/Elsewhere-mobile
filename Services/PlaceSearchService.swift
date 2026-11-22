import Combine
import MapKit
import os

enum AppLanguage: Sendable {
    static var locale: Locale {
        Locale(identifier: Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: Locale.preferredLanguages).first ?? "en")
    }
    static var isChinese: Bool { locale.language.languageCode == .chinese }
}

struct OSMPlace: Identifiable, Equatable, Sendable {
    let id = UUID()
    let name: String
    let detail: String
    let coordinate: WGS84Coordinate
}

actor OpenStreetMapClient {
    static let shared = OpenStreetMapClient()
    private static let nextSearch = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: ContinuousClock.now)
    private let transport: HTTPDataTransport
    private let photonEndpoint: URL
    private let nominatimEndpoint: URL
    private var cache: [URL: [OSMPlace]] = [:]
    private var pending: [URL: Task<[OSMPlace], Error>] = [:]

    init(transport: HTTPDataTransport = URLSessionHTTPTransport(),
         photonEndpoint: URL = URL(string: "https://photon.komoot.io/api/")!,
         nominatimEndpoint: URL = URL(string: "https://nominatim.openstreetmap.org/search")!) {
        self.transport = transport
        self.photonEndpoint = photonEndpoint
        self.nominatimEndpoint = nominatimEndpoint
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Elsewhere-iOS/1.0 (iOS location tool)", forHTTPHeaderField: "User-Agent")
        request.setValue(AppLanguage.isChinese ? "zh-CN,zh;q=0.9,en;q=0.8" : "en,zh-CN;q=0.5", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await transport.data(for: request, proxy: nil)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func suggest(_ text: String, limit: Int = 5) async throws -> [OSMPlace] {
        struct Response: Decodable {
            struct Feature: Decodable {
                struct Geometry: Decodable { let coordinates: [Double] }
                struct Properties: Decodable { let name, city, county, state, country: String? }
                let geometry: Geometry
                let properties: Properties
            }
            let features: [Feature]
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let url = photonEndpoint.appending(queryItems: [.init(name: "q", value: query), .init(name: "limit", value: String(limit))])
        let response: Response = try await get(url)
        return response.features.compactMap { feature in
            let point = feature.geometry.coordinates, place = feature.properties
            guard point.count == 2, let coordinate = WGS84Coordinate(latitude: point[1], longitude: point[0]),
                  let name = place.name, !name.isEmpty else { return nil }
            let detail = [place.city ?? place.county, place.state, place.country].compactMap { $0 }
                .filter { $0 != name }.joined(separator: " · ")
            return OSMPlace(name: name, detail: detail, coordinate: coordinate)
        }
    }

    func search(_ text: String, limit: Int = 3) async throws -> [OSMPlace] {
        struct Item: Decodable {
            let name: String?
            let display_name, lat, lon: String
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let url = nominatimEndpoint.appending(queryItems: [
            .init(name: "q", value: query), .init(name: "format", value: "jsonv2"), .init(name: "limit", value: String(limit)),
            .init(name: "accept-language", value: AppLanguage.isChinese ? "zh-CN" : "en"),
        ])
        while let previous = pending[url] {
            _ = await previous.result
            try Task.checkCancellation()
        }
        if let places = cache[url] { return places }
        let task = Task {
            defer { pending[url] = nil }
            try Task.checkCancellation()
            // 从上一请求完成起计时，慢响应或进程挂起都不会让积压的查询同时发出。
            while let deadline = Self.nextSearch.withLock({ next -> ContinuousClock.Instant? in
                let now = ContinuousClock.now
                guard let available = next else { return now + .seconds(1) }
                guard now >= available else { return available }
                next = nil
                return nil
            }) {
                try await Task.sleep(until: deadline, clock: .continuous)
            }
            defer { Self.nextSearch.withLock { $0 = .now + .seconds(1) } }
            let items: [Item] = try await get(url)
            let places = items.compactMap { item -> OSMPlace? in
                guard let lat = Double(item.lat), let lon = Double(item.lon),
                      let coordinate = WGS84Coordinate(latitude: lat, longitude: lon) else { return nil }
                let name = item.name.flatMap { $0.isEmpty ? nil : $0 } ?? item.display_name
                let first = name.split(maxSplits: 1) { $0 == ";" || $0 == "；" }.first
                return OSMPlace(name: first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name,
                                detail: item.display_name, coordinate: coordinate)
            }
            cache[url] = places
            return places
        }
        pending[url] = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

enum Geo: Sendable {
    static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return item.location.coordinate
        } else {
            return legacyCoordinate(of: item)
        }
        #else
        return legacyCoordinate(of: item)
        #endif
    }

    @available(iOS, deprecated: 26.0)
    private static func legacyCoordinate(of item: MKMapItem) -> CLLocationCoordinate2D { item.placemark.coordinate }

    static func timeZone(for coordinate: WGS84Coordinate) async -> TimeZone? {
        await place(at: coordinate)?.zone ?? TimeZoneService.nearestZone(to: coordinate)
    }
    static func placeName(for coordinate: WGS84Coordinate) async -> String? { await place(at: coordinate)?.name }

    // 时区提示需要区分地理编码结果与离线估算，可将这里的原始 zone 交给 evaluate。
    static func place(at coordinate: WGS84Coordinate) async -> (zone: TimeZone?, name: String?)? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            request.preferredLocale = AppLanguage.locale
            guard let item = try? await request.mapItems.first else { return nil }
            return (item.timeZone, item.addressRepresentations?.cityName ?? item.name)
        } else {
            return await legacyPlace(at: location)
        }
        #else
        return await legacyPlace(at: location)
        #endif
    }

    @available(iOS, deprecated: 26.0)
    private static func legacyPlace(at location: CLLocation) async -> (TimeZone?, String?)? {
        guard let place = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: AppLanguage.locale).first else { return nil }
        return (place.timeZone, place.locality ?? place.administrativeArea ?? place.name ?? place.country)
    }
}

@MainActor
final class PlaceSearchStore: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            clear()
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let completer = MKLocalSearchCompleter()
            self.completer = completer
            completer.delegate = self
            completer.resultTypes = [.address, .pointOfInterest]
            completer.queryFragment = text
            suggestion = Task { [weak self, client] in
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    let places = try await client.suggest(text)
                    if !Task.isCancelled { self?.osmResults = places }
                } catch {
                    if !Task.isCancelled { self?.photonError = error.localizedDescription }
                }
            }
        }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    @Published private(set) var osmResults: [OSMPlace] = []
    @Published private(set) var appleError: String?
    @Published private(set) var photonError: String?
    @Published private(set) var nominatimError: String?
    @Published private var localSearch: (search: MKLocalSearch, finish: () -> Void)?
    @Published private var osmLookup: Task<OSMPlace?, Error>?
    var searching: Bool { localSearch != nil || osmLookup != nil }
    var hasSuggestions: Bool { !results.isEmpty || !osmResults.isEmpty }

    private let client: OpenStreetMapClient
    private var completer: MKLocalSearchCompleter?
    private var suggestion: Task<Void, Never>?

    init(client: OpenStreetMapClient = .shared) { self.client = client }

    func clear() {
        cancelLookup()
        suggestion?.cancel()
        completer?.cancel()
        completer = nil
        results = []
        osmResults = []
        appleError = nil
        photonError = nil
        nominatimError = nil
    }

    private func cancelLookup() {
        localSearch?.finish()
        localSearch?.search.cancel()
        localSearch = nil
        osmLookup?.cancel()
        osmLookup = nil
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let id = ObjectIdentifier(completer)
        Task { @MainActor in
            guard let current = self.completer, ObjectIdentifier(current) == id else { return }
            self.results = Array(current.results.prefix(6))
            self.appleError = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let id = ObjectIdentifier(completer)
        Task { @MainActor in
            guard let current = self.completer, ObjectIdentifier(current) == id else { return }
            self.results = []
            self.appleError = error.localizedDescription
        }
    }

    func lookUpOSM(_ text: String) async -> OSMPlace? {
        guard !Task.isCancelled else { return nil }
        cancelLookup()
        nominatimError = nil
        let task = Task { [client] in try await client.search(text).first }
        osmLookup = task
        defer { if osmLookup == task { osmLookup = nil } }
        do {
            let place = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            return task.isCancelled ? nil : place
        } catch {
            if !task.isCancelled { nominatimError = error.localizedDescription }
            return nil
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> (String, CLLocationCoordinate2D)? {
        await run(MKLocalSearch.Request(completion: completion), name: completion.title)
    }

    func resolve(text: String) async -> (String, CLLocationCoordinate2D)? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        return await run(request, name: text)
    }

    private func run(_ request: MKLocalSearch.Request, name: String) async -> (String, CLLocationCoordinate2D)? {
        guard !Task.isCancelled else { return nil }
        cancelLookup()
        appleError = nil
        let search = MKLocalSearch(request: request)
        let matches = AsyncThrowingStream<(String, CLLocationCoordinate2D), Error> { result in
            localSearch = (search, { result.finish() })
            search.start { response, error in
                if let error {
                    result.finish(throwing: error)
                    return
                }
                if let item = response?.mapItems.first { result.yield((item.name ?? name, Geo.coordinate(of: item))) }
                result.finish()
            }
        }
        defer {
            if localSearch?.search === search {
                localSearch = nil
                if Task.isCancelled { search.cancel() }
            }
        }
        do {
            var iterator = matches.makeAsyncIterator()
            guard let match = try await iterator.next(), localSearch?.search === search, !Task.isCancelled else { return nil }
            guard CLLocationCoordinate2DIsValid(match.1) else { throw URLError(.cannotParseResponse) }
            clear()
            return match
        } catch {
            if localSearch?.search === search, !Task.isCancelled { appleError = error.localizedDescription }
            return nil
        }
    }
}
