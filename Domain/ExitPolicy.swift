enum ExitChangeDecision: Equatable, Sendable {
    enum IgnoreReason: Equatable, Sendable {
        case disabled, watchOff, baselineInitialized, unchanged
    }

    case ignore(IgnoreReason)
    case notifyDiscrepancy(probeIP: String, detailIP: String)
    case evaluateTargets(exit: ExitInfo, actions: [DeviceID: TargetExitAction])
}

enum TargetExitAction: Equatable, Sendable {
    case autoApply, notify, alreadyMatched
}

enum ExitPolicy: Sendable {
    private static func ignoreReason(featuresEnabled: Bool, watchMode: ExitWatchMode, previousIP: String?,
                                     observedIP: String) -> ExitChangeDecision.IgnoreReason? {
        guard featuresEnabled else { return .disabled }
        guard watchMode != .off else { return .watchOff }
        guard let previousIP else { return .baselineInitialized }
        return observedIP == previousIP ? .unchanged : nil
    }

    static func shouldFetchDetail(featuresEnabled: Bool, watchMode: ExitWatchMode, previousIP: String?, observedIP: String) -> Bool {
        ignoreReason(featuresEnabled: featuresEnabled, watchMode: watchMode, previousIP: previousIP, observedIP: observedIP) == nil
    }

    static func decide(featuresEnabled: Bool, watchMode: ExitWatchMode, previousIP: String?, probeIP: String,
                       fetchedExit: ExitInfo, targetDeviceIDs: [DeviceID], records: [DeviceID: AppliedLocationRecord]) -> ExitChangeDecision {
        if let reason = ignoreReason(featuresEnabled: featuresEnabled, watchMode: watchMode, previousIP: previousIP, observedIP: probeIP) {
            return .ignore(reason)
        }
        guard fetchedExit.ip == probeIP else { return .notifyDiscrepancy(probeIP: probeIP, detailIP: fetchedExit.ip) }
        var actions: [DeviceID: TargetExitAction] = [:]
        for id in targetDeviceIDs {
            guard let record = records[id], record.source == .exitIP else {
                actions[id] = .notify
                continue
            }
            if record.exitIP == fetchedExit.ip { actions[id] = .alreadyMatched }
            else { actions[id] = watchMode == .auto ? .autoApply : .notify }
        }
        return .evaluateTargets(exit: fetchedExit, actions: actions)
    }
}
