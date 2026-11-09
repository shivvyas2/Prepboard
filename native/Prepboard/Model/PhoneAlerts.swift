#if os(iOS)
import BackgroundTasks
import Foundation
import SwiftData
import UserNotifications

/// The iPhone's alerts for what the Mac does: after every sync (in the app, or in a background refresh) it compares each role's
/// status with the last one it saw and posts "Applied", "needs you" and "apply by hand" alerts, with the badge counting what
/// waits on me. These are local notifications fed by sync; there is no push server.
@MainActor
enum PhoneAlerts {
    static let refreshID = "com.shivvyas.prepboard.refresh"
    private static let seenKey = "alerts.leadStatus"

    /// Asks once for alerts, sounds and the badge (iOS shows its prompt only the first time).
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// What changed since the last check, as (identifier, title, body). Pure, for tests.
    static func changes(leads: [(id: String, status: String, company: String, title: String, reason: String)],
                        seen: [String: String]) -> [(String, String, String)] {
        guard !seen.isEmpty else { return [] }   // first run: remember, don't flood
        var out: [(String, String, String)] = []
        for l in leads where seen[l.id] != l.status {
            switch l.status {
            case LeadStatus.submitted.rawValue:
                out.append(("applied-\(l.id)", "Applied: \(l.company)", l.title))
            case LeadStatus.needsYou.rawValue:
                out.append(("needs-you-\(l.id)", "\(l.company) needs you", l.reason.isEmpty ? "An application stopped for your input." : l.reason))
            case LeadStatus.skipped.rawValue where l.reason.hasPrefix(Lead.byHandPrefix):
                out.append(("by-hand-\(l.id)", "Apply by hand: \(l.company)", String(l.reason.dropFirst(Lead.byHandPrefix.count))))
            default: break
            }
        }
        return out
    }

    static func check(_ context: ModelContext) {
        let leads = (try? context.fetch(FetchDescriptor<Lead>())) ?? []
        let seen = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String] ?? [:]
        let rows = leads.map { (id: $0.id, status: $0.statusRaw, company: $0.company, title: $0.title, reason: $0.reason) }
        let center = UNUserNotificationCenter.current()
        for (id, title, body) in changes(leads: rows, seen: seen) {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.status) }), forKey: seenKey)
        center.setBadgeCount(leads.filter { $0.status == .needsYou }.count)
    }

    /// Asks iOS to wake the app for a sync in about 20 minutes (iOS decides when, based on use).
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = .now.addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
