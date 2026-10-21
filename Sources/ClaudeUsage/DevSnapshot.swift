import AppKit
import SwiftUI
import WebKit

/// Developer self-check, never used in normal runs.
///
/// `CLAUDE_USAGE_SNAPSHOT=<dir>` renders every tab to a PNG using SAMPLE limit numbers (plus the real
/// Claude Code logs), makes one signed-out request to claude.ai to prove the web plumbing works, and exits.
@MainActor
enum DevSnapshot {
    static var directory: String? { ProcessInfo.processInfo.environment["CLAUDE_USAGE_SNAPSHOT"] }

    static func run(into dir: String) async {
        let model = AppModel(persist: false)
        let a = Account(name: "", email: "sample@example.com", orgId: "sample")
        let b = Account(name: "Work", email: "work@example.com", orgId: "sample")
        model.accounts = [a, b]
        model.selectedID = a.id
        let now = Date()
        model.usage[a.id] = AccountUsage(windows: [
            LimitWindow(key: "five_hour", utilization: 62, resetsAt: now.addingTimeInterval(2.2 * 3600)),
            LimitWindow(key: "seven_day", utilization: 41, resetsAt: now.addingTimeInterval(4.5 * 86400)),
            LimitWindow(key: "seven_day_opus", utilization: 93, resetsAt: now.addingTimeInterval(4.5 * 86400)),
        ], fetchedAt: now, raw: "{}")
        model.errors[b.id] = .notSignedIn
        // Three days of sample 5-hour windows.
        for hoursAgo in stride(from: 70.0, through: 0, by: -0.5) {
            let t = now.addingTimeInterval(-hoursAgo * 3600)
            let windowIndex = floor((hoursAgo + 2.8) / 5)
            let reset = now.addingTimeInterval((2.2 - windowIndex * 5) * 3600)
            let progress = min(1, max(0, 1 - reset.timeIntervalSince(t) / (5 * 3600)))
            let peak = [62.0, 100, 35, 80, 12, 100, 55][Int(windowIndex) % 7]
            model.snapshots.append(Snapshot(t: t, acct: a.id, w: ["five_hour": peak * progress], r: ["five_hour": reset]))
        }
        await model.scanCode()

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for tab in Tab.allCases {
            await render(PopoverView(initialTab: tab).environmentObject(model), to: "\(dir)/\(tab.rawValue.lowercased()).png")
        }
        // Full-height Activity tab for each metric, with its settings kept out of the real defaults.
        let suite = "ClaudeUsage.DevSnapshot"
        let store = UserDefaults(suiteName: suite)!
        for (metric, range) in [(GridMetric.cost, ActivityRange.half), (.peak, .half), (.tokens, .year), (.messages, .quarter)] {
            store.set(metric.rawValue, forKey: "activityMetric")
            store.set(range.rawValue, forKey: "activityRange")
            let name = "activity-\(metric.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))-\(range.label)"
            await render(PopoverView(initialTab: .activity, height: 1250).environmentObject(model).defaultAppStorage(store),
                         to: "\(dir)/\(name).png", height: 1250)
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        await render(PopoverView(showSettings: true).environmentObject(model), to: "\(dir)/settings.png")
        await render(PopoverView().environmentObject(AppModel(persist: false)), to: "\(dir)/welcome.png")

        let id = UUID()
        do {
            _ = try await WebSession(accountID: id).get("/api/organizations")
            print("web check: unexpected success while signed out")
        } catch {
            print("web check (signed out, expect \"Signed out\"): \(error)")
        }
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    private static func render<V: View>(_ view: V, to path: String, height: CGFloat = 600) async {
        let host = NSHostingView(rootView: view
            .background(Color(red: 0.13, green: 0.13, blue: 0.14))
            .environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(1))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
