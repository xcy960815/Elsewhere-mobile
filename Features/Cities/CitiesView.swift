import SwiftUI

struct CitiesView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var searching = false
    @State private var adding = false
    @State private var confirmingReset = false

    var body: some View {
        List {
            if let message = store.feedback {
                FeedbackBanner(message: message, onDismiss: store.dismissFeedback)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            if searching || !query.isEmpty {
                let matches = store.cities.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
                if matches.isEmpty { ContentUnavailableView.search(text: query) }
                ForEach(matches) { cityRow($0) }
            } else {
                ForEach(store.cities) { cityRow($0) }
                    .onMove { source, destination in Task { await store.moveCities(from: source, to: destination) } }
                    .onDelete { offsets in Task { await store.removeCities(at: offsets) } }
            }
        }
        .navigationTitle("城市")
        .searchable(text: $query, isPresented: $searching, prompt: "搜索城市名称")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !searching && query.isEmpty { EditButton() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("恢复默认城市", role: .destructive) { confirmingReset = true }
                } label: { Label("城市选项", systemImage: "ellipsis.circle") }
                .confirmationDialog("恢复默认城市？", isPresented: $confirmingReset, titleVisibility: .visible) {
                    Button("恢复默认城市", role: .destructive) { Task { await store.resetCities() } }
                    Button("取消", role: .cancel) {}
                } message: { Text("将恢复 \(Place.defaults.count) 个默认城市及原始顺序，并删除所有自建城市。") }
                Button { adding = true } label: { Label("添加城市", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding) { AddCitySheet() }
        .sensoryFeedback(trigger: store.feedback) { _, message in message?.sensation }
    }

    private func cityRow(_ place: Place) -> some View {
        Button {
            Task { await store.apply(place: place, source: .city) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name).foregroundStyle(.primary)
                Text(place.coordinate.formatted).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(!store.canOperate)
        .accessibilityHint("将目标设备的定位设到此处")
    }
}

private struct AddCitySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var saving = false

    var body: some View {
        let parsed = CoordinateParser.parse(latitudeText: latitude, longitudeText: longitude)
        let cityName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        NavigationStack {
            Form {
                TextField("城市名称", text: $name)
                Section {
                    TextField("纬度", text: $latitude)
                    TextField("经度", text: $longitude)
                } header: {
                    Text("WGS-84 坐标")
                } footer: {
                    if case .failure(let error) = parsed, !latitude.isEmpty || !longitude.isEmpty {
                        Text(error.localizedDescription).foregroundStyle(.red)
                    } else {
                        Text("也可以将一对坐标粘贴到纬度框，例如 37.5665, 126.9780。")
                    }
                }
                .keyboardType(.numbersAndPunctuation)
                if let message = store.feedback, message.kind == .failure {
                    FeedbackBanner(message: message, onDismiss: store.dismissFeedback)
                }
            }
            .navigationTitle("添加城市")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard case .success(let coordinate) = parsed else { return }
                        saving = true
                        let place = Place(name: cityName, coordinate: coordinate)
                        Task {
                            await store.addCity(place)
                            saving = false
                            if store.cities.contains(place) { dismiss() }
                        }
                    }
                    .disabled(saving || cityName.isEmpty || (try? parsed.get()) == nil)
                }
            }
        }
    }
}
