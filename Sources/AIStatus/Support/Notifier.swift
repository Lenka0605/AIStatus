import AppKit
@preconcurrency import UserNotifications

/// 系统通知：额度不足、额度恢复。点通知会打开面板。
/// 命令行调试时没有 bundle，UNUserNotificationCenter 会直接崩溃，所以那时一律跳过。
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// 剩余低于这些百分比时各提醒一次（每个重置周期）
    static let lowLevels: [Double] = [20, 5]
    /// 剩余低于这个百分比时，到重置时间提醒「已恢复」
    static let resetThreshold: Double = 50

    var onOpen: () -> Void = {}

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        center?.delegate = self
        if Preferences.notifyLow || Preferences.notifyReset || Preferences.notifyResetSignal { requestAuthorization() }
    }

    func requestAuthorization(then: (@Sendable () -> Void)? = nil) {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in then?() }
    }

    func isDenied() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    func sendTest() {
        requestAuthorization {
            Task { @MainActor in
                Notifier.shared.post(id: "test", title: "AI 余量", body: "通知已开启：额度不足或恢复时会这样提醒你")
            }
        }
    }

    /// 每次拿到新额度时调用
    func quotaUpdated(key: String, name: String, quota: ProviderQuota) {
        // 太旧的数据（比如几天前的本地日志）不提醒
        guard let center, Date().timeIntervalSince(quota.asOf) < 30 * 60 else { return }
        Task {
            // 没有通知权限时什么都不做，否则会被记成「已提醒」，之后打开权限也不会再提醒
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            for window in quota.windows where !window.hasReset {
                if Preferences.notifyLow { checkLow(key: key, name: name, window: window) }
                if Preferences.notifyReset { scheduleReset(key: key, name: name, window: window) }
            }
        }
    }

    /// 系统设置里本应用的通知页
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.aistatus.AIStatus")!

    /// 传 key 只取消这一家的
    func cancelResetReminders(key: String? = nil) {
        guard let center else { return }
        let prefix = "reset." + (key.map { "\($0)." } ?? "")
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Codex 全员重置的预告和完成，每条信号只发一次（由 Store 判断是不是新的）
    func resetSignal(_ signal: ResetSignal.Post, title: String, body: String) {
        guard Preferences.notifyResetSignal else { return }
        post(id: "signal.\(signal.id)", title: title, body: body)
    }

    private func checkLow(key: String, name: String, window: QuotaWindow) {
        let remaining = window.remainingPercent
        guard let level = Self.lowLevels.filter({ remaining < $0 }).min() else { return }
        // 同一个重置周期里每档只提醒一次。重置时间四舍五入到小时，避免服务器返回的秒数抖动被当成新周期
        let period = Int(((window.resetsAt ?? Calendar.current.startOfDay(for: Date())).timeIntervalSince1970 / 3600).rounded())
        let slot = "\(key).\(window.id)"
        var sent = UserDefaults.standard.dictionary(forKey: "notify.lowSent") as? [String: [Int]] ?? [:]
        if let last = sent[slot], last.count == 2, last[0] == period, Double(last[1]) <= level { return }
        sent[slot] = [period, Int(level)]
        UserDefaults.standard.set(sent, forKey: "notify.lowSent")
        post(id: "low.\(slot)", title: "\(name) \(window.label)额度只剩 \(Int(remaining.rounded()))%",
             body: Fmt.reset(window.resetsAt) ?? "")
    }

    private func scheduleReset(key: String, name: String, window: QuotaWindow) {
        guard let center, window.remainingPercent < Self.resetThreshold,
              let resetsAt = window.resetsAt, resetsAt > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(name) \(window.label)额度已恢复"
        content.body = "额度已经重置，可以继续用了"
        content.sound = .default
        // 晚 30 秒发，确保服务器那边确实已经重置；同一个 id 会覆盖之前排的
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: resetsAt.timeIntervalSinceNow + 30, repeats: false)
        center.add(UNNotificationRequest(identifier: "reset.\(key).\(window.id)", content: content, trigger: trigger))
    }

    private func post(id: String, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // 菜单栏应用永远不在前台，不实现这个的话通知只进通知中心、不弹横幅
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { MainActor.assumeIsolated { Notifier.shared.onOpen() } }
        }
        completionHandler()
    }
}
