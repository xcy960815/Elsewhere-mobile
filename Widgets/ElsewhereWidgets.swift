import SwiftUI
import WidgetKit

private struct SnapshotProvider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date = Date()
        let snapshot: WidgetSnapshot?
    }

    func placeholder(in context: Context) -> Entry { Entry(snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void) {
        completion(Entry(snapshot: AppStateStore.readWidgetSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void) {
        let entry = Entry(snapshot: AppStateStore.readWidgetSnapshot())
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(15 * 60))))
    }
}

private struct LocationWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(snapshot?.selectedDeviceName ?? String(localized: "暂无设备信息"), systemImage: "iphone")
                    .font(.caption).foregroundStyle(.secondary)
                if family == .systemSmall {
                    Spacer(minLength: 2)
                    Image(systemName: snapshot?.locationName == nil ? "location.circle" : "mappin.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(snapshot?.locationName == nil ? Text("无模拟记录") : Text("上次模拟位置"))
                }
            }
            if let snapshot {
                Text(snapshot.locationName ?? String(localized: "真实定位")).font(.headline)
                if let coordinate = snapshot.coordinate {
                    Text(coordinate.formatted).monospacedDigit().minimumScaleFactor(0.75)
                } else {
                    Text("更新于 \(snapshot.updatedAt, style: .time)").monospacedDigit()
                }
                if snapshot.exitFeaturesEnabled {
                    Label(snapshot.exitSummary ?? String(localized: "暂无出口信息"), systemImage: "network")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("暂无定位记录").font(.headline)
            }
            if family == .systemMedium {
                Spacer(minLength: 2)
                HStack {
                    if snapshot?.exitFeaturesEnabled == true {
                        Button(intent: FollowExitIntent()) { Label("跟随出口", systemImage: "network") }
                    }
                    Button(intent: RestoreRealLocationIntent()) { Label("恢复真实定位", systemImage: "location.slash") }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .font(.caption).lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
    }
}

private struct LocationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ElsewhereLocation", provider: SnapshotProvider()) { entry in
            LocationWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Elsewhere 定位")
        .description("显示上次设置的位置。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#if compiler(>=6.0)
@available(iOS 18.0, *)
private struct FollowExitControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ElsewhereFollowExit") {
            ControlWidgetButton(action: FollowExitIntent()) { Label("跟随代理出口", systemImage: "network") }
        }
        .displayName("跟随代理出口")
    }
}

@available(iOS 18.0, *)
private struct RestoreLocationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ElsewhereRestoreLocation") {
            ControlWidgetButton(action: RestoreRealLocationIntent()) { Label("恢复真实定位", systemImage: "location.slash") }
        }
        .displayName("恢复真实定位")
    }
}
#endif

@main
struct ElsewhereWidgets: WidgetBundle {
    var body: some Widget {
        LocationWidget()
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            FollowExitControl()
            RestoreLocationControl()
        }
        #endif
    }
}
