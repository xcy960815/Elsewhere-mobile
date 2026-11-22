import MapKit
import SwiftUI

private enum MapLook: String, CaseIterable {
    case standard = "标准", hybrid = "混合", imagery = "卫星"

    var style: MapStyle {
        switch self {
        case .standard: .standard(pointsOfInterest: .all)
        case .hybrid: .hybrid
        case .imagery: .imagery
        }
    }
}

private struct MapPin: Identifiable {
    let id = UUID()
    let map: CLLocationCoordinate2D
    let gps: WGS84Coordinate
    var name: String?
    var osm = false
    var needsReverseLookup = false
}

struct MapView: View {
    @Environment(AppStore.self) private var store
    @StateObject private var search = PlaceSearchStore()
    @State private var position = MapCameraPosition.automatic
    @State private var look = MapLook.standard
    @State private var pin: MapPin?
    @State private var lastSeenRecord: AppliedLocationRecord?
    @State private var expanded = true
    @State private var enteringCoordinates = false
    @State private var coordinateText = ""
    @State private var notFound = false
    @State private var lookup: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    let openOnboarding: () -> Void

    private var displayName: String {
        let name = pin?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? String(localized: "地图选点") : name
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let record = store.selectedRecord {
                    let point = ChinaCoordinate.gpsToMap(record.coordinate)
                    switch record.confidence {
                    case .confirmed, .lastSet:
                        Marker("模拟位置 · \(record.name)", systemImage: "iphone", coordinate: point).tint(.blue)
                    case .unknownOutcome:
                        Marker("模拟待确认 · \(record.name)", systemImage: "questionmark.circle", coordinate: point).tint(.orange)
                    case .clearUnknown:
                        Marker("清除待确认 · \(record.name)", systemImage: "questionmark.circle", coordinate: point).tint(.orange)
                    }
                }
                if store.settings.exitFeaturesEnabled, let exit = store.exit {
                    Marker("代理出口 · \(exit.displayCity)", systemImage: "globe", coordinate: ChinaCoordinate.gpsToMap(exit.coordinate)).tint(.orange)
                }
                if let pin { Marker(displayName, coordinate: pin.map).tint(.red) }
            }
            .mapStyle(look.style)
            .mapControls { MapCompass(); MapScaleView() }
            .simultaneousGesture(SpatialTapGesture().onEnded { dropPin(at: $0.location, in: proxy) })
            .simultaneousGesture(LongPressGesture().simultaneously(with: DragGesture(minimumDistance: 0))
                .onEnded { press in
                    if press.first == true, let touch = press.second { dropPin(at: touch.startLocation, in: proxy) }
                })
        }
    }

    var body: some View {
        GeometryReader { area in
            map.overlay(alignment: .top) { searchPanel }
                .safeAreaInset(edge: .bottom) {
                    if !searchFocused || search.query.isEmpty {
                        ViewThatFits(in: .vertical) { controls; ScrollView { controls } }
                            .frame(maxWidth: 600, maxHeight: area.size.height * 0.48, alignment: .bottom)
                            .fixedSize(horizontal: false, vertical: true).padding(8)
                    }
                }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $enteringCoordinates) { coordinateEntry }
        .onChange(of: store.selectedRecord, initial: true) { _, record in
            updateCamera(for: record)
        }
        .onChange(of: store.settings.exitFeaturesEnabled ? store.exit?.coordinate : nil, initial: true) { _, gps in
            if store.selectedRecord == nil, position == .automatic, pin == nil, let gps {
                jump(to: ChinaCoordinate.gpsToMap(gps))
            }
        }
        .onChange(of: store.isDemo, initial: true) { _, isDemo in
            if search.isDemo != isDemo {
                lookup?.cancel()
                pin = nil
                notFound = false
            }
            search.isDemo = isDemo
        }
        .task(id: pin?.id) {
            guard let current = pin, current.needsReverseLookup, current.name == nil,
                  let name = await Geo.placeName(for: current.gps, isDemo: store.isDemo), !Task.isCancelled,
                  pin?.id == current.id, pin?.name == nil else { return }
            pin?.name = name
        }
        .onDisappear { updateQuery("") }
        .sensoryFeedback(.selection, trigger: pin?.id)
        .sensoryFeedback(trigger: store.feedback) { _, message in message?.sensation }
    }

    private var searchPanel: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索地名、地址或坐标", text: Binding(get: { search.query }, set: { updateQuery($0) }))
                    .focused($searchFocused).submitLabel(.search)
                    .onSubmit { startSearch { await submitSearch() } }
                if search.searching { ProgressView().controlSize(.small) }
                if !search.query.isEmpty {
                    Button { updateQuery("") } label: {
                        Label("清空搜索", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                }
                Button {
                    lookup?.cancel()
                    coordinateText = ""
                    enteringCoordinates = true
                } label: { Label("输入坐标", systemImage: "number").labelStyle(.iconOnly) }
                .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.leading, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            Picker("底图样式", selection: $look) {
                ForEach(MapLook.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            if search.hasSuggestions || search.appleError != nil || search.photonError != nil || search.nominatimError != nil || notFound {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(search.osmResults) { place in
                            suggestion(place.name, place.detail, symbol: "globe", source: search.isDemo ? String(localized: "常用城市") : "OpenStreetMap · Photon") {
                                selectGPS(place.coordinate, name: place.name, osm: !search.isDemo)
                            }
                        }
                        ForEach(search.results, id: \.self) { item in
                            suggestion(item.title, item.subtitle, symbol: "map", source: String(localized: "Apple 地图")) {
                                startSearch { selectMatch(await search.resolve(item)) }
                            }
                        }
                        if let error = search.appleError { Text("Apple 地图 · \(error)") }
                        if let error = search.photonError { Text("Photon · \(error)") }
                        if let error = search.nominatimError { Text("Nominatim · \(error)") }
                        if notFound { Text("没有找到地点，请换个关键词。") }
                        if !search.isDemo, !search.osmResults.isEmpty { Text("© OpenStreetMap contributors") }
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 230)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: 540).padding(8)
    }

    private func suggestion(_ title: String, _ detail: String, symbol: String, source: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading) {
                    Text(title).font(.callout).foregroundStyle(.primary)
                    Text(detail.isEmpty ? source : "\(source) · \(detail)").lineLimit(1)
                }
            } icon: { Image(systemName: symbol) }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var coordinateEntry: some View {
        let parsed = CoordinateParser.parse(coordinateText)
        return NavigationStack {
            Form {
                Section {
                    TextField("纬度, 经度", text: $coordinateText).keyboardType(.numbersAndPunctuation)
                } footer: {
                    if case .failure(let error) = parsed, !coordinateText.isEmpty { Text(error.localizedDescription) }
                    else { Text("支持中英文逗号或空格，例如 37.5665, 126.9780。") }
                }
            }
            .navigationTitle("输入 WGS-84 坐标").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { enteringCoordinates = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选取") {
                        if case .success(let gps) = parsed {
                            enteringCoordinates = false
                            selectGPS(gps)
                        }
                    }
                    .disabled((try? parsed.get()) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var controls: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    HStack {
                        Text(pin != nil ? displayName : store.selectedRecord?.name ?? String(localized: "在地图上选点"))
                            .font(.headline).lineLimit(1)
                        Spacer()
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(expanded ? "收起操作卡片" : "展开操作卡片")
                .simultaneousGesture(DragGesture().onEnded { drag in
                    withAnimation { expanded = drag.translation.height < 0 }
                })
                if store.needsPairingSetup {
                    Text("尚未配置设备，暂时无法应用所选位置。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    PairingSetupActions(setupTitle: "配置设备", openOnboarding: openOnboarding)
                }
                if expanded {
                    if let pin {
                        TextField("地点名称", text: Binding(get: { self.pin?.name ?? "" }, set: { self.pin?.name = $0 }),
                                  prompt: Text("地图选点")).textFieldStyle(.roundedBorder)
                        Text("WGS-84 · \(pin.gps.preciseLatitude), \(pin.gps.preciseLongitude)")
                            .font(.caption.monospacedDigit()).textSelection(.enabled)
                        if pin.osm { Text("© OpenStreetMap contributors · ODbL 1.0").font(.caption2) }
                        HStack {
                            let saved = store.cities.contains { $0.displayName == displayName && $0.coordinate == pin.gps }
                            Button(saved ? "已收藏" : "收藏为常用城市") {
                                let place = Place(name: displayName, coordinate: pin.gps)
                                Task {
                                    await store.addCity(place)
                                    if store.cities.contains(place) { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                                }
                            }
                            .disabled(saved)
                            Button("应用到设备") {
                                let name = displayName, previous = store.feedback?.id
                                Task {
                                    await store.apply(name: name, coordinate: pin.gps, source: .custom)
                                    if self.pin?.id == pin.id, let result = store.feedback, result.id != previous, result.kind == .success {
                                        self.pin = nil
                                        jump(to: pin.map)
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent).disabled(!store.canOperate)
                        }
                    } else if let record = store.selectedRecord {
                        Text("WGS-84 · \(record.coordinate.formatted)").font(.caption.monospacedDigit())
                    }
                    HStack {
                        if store.settings.exitFeaturesEnabled {
                            Button("跟随出口") {
                                let previous = store.feedback?.id, selection = pin?.id
                                Task {
                                    await store.followExit()
                                    guard pin?.id == selection, let result = store.feedback, result.id != previous,
                                          result.kind == .success, let exit = store.exit else { return }
                                    pin = nil
                                    jump(to: ChinaCoordinate.gpsToMap(exit.coordinate))
                                }
                            }
                            .disabled(!store.canOperate || store.customProxyInvalid)
                        }
                        Button("恢复真实定位") { Task { await store.clearLocation() } }.disabled(!store.canOperate)
                    }
                    if let busy = store.busyMessage { ProgressView { Text(busy) }.progressViewStyle(.linear) }
                    else if let device = store.selectedDevice { Label(device.name, systemImage: "iphone").font(.caption) }
                    if let message = store.feedback { FeedbackBanner(message: message, onDismiss: store.dismissFeedback) }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func updateQuery(_ text: String) {
        lookup?.cancel()
        notFound = false
        search.query = text
    }

    private func startSearch(_ action: @escaping @MainActor () async -> Void) {
        lookup?.cancel()
        notFound = false
        lookup = Task { if !Task.isCancelled { await action() } }
    }

    private func submitSearch() async {
        guard !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectMatch(await search.submit(search.query))
    }

    private func selectMatch(_ match: SearchMatch?) {
        guard !Task.isCancelled else { return }
        switch match {
        case .coordinate(let gps): selectGPS(gps)
        case .osm(let place): selectGPS(place.coordinate, name: place.name, osm: !search.isDemo)
        case .apple(let name, let gps): selectGPS(gps, name: name)
        case nil: notFound = true
        }
    }

    private func dropPin(at point: CGPoint, in proxy: MapProxy) {
        guard let map = proxy.convert(point, from: .local), let gps = ChinaCoordinate.mapToGPS(map) else { return }
        select(MapPin(map: map, gps: gps, needsReverseLookup: true))
    }

    private func selectGPS(_ gps: WGS84Coordinate, name: String? = nil, osm: Bool = false) {
        let map = ChinaCoordinate.gpsToMap(gps)
        select(MapPin(map: map, gps: gps, name: name, osm: osm))
        jump(to: map)
    }

    private func select(_ point: MapPin) {
        updateQuery("")
        searchFocused = false
        pin = point
        expanded = true
    }

    private func updateCamera(for record: AppliedLocationRecord?) {
        let previous = lastSeenRecord
        lastSeenRecord = record
        guard let record else { return }
        let changed = previous?.deviceID != record.deviceID || previous?.coordinate != record.coordinate ||
            previous?.appliedAt != record.appliedAt || previous?.confidence != record.confidence
        if changed && record.confidence.isConfirmedSimulated {
            lookup?.cancel()
            pin = nil
        } else if position != .automatic || pin != nil {
            return
        }
        jump(to: ChinaCoordinate.gpsToMap(record.coordinate))
    }

    private func jump(to map: CLLocationCoordinate2D) {
        withAnimation { position = .region(MKCoordinateRegion(center: map, latitudinalMeters: 30_000, longitudinalMeters: 30_000)) }
    }
}
