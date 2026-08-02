import AppKit
import UserNotifications
import VantageCore

/// The morning notification: one line, once, when a new daily report lands.
///
/// > **This does not work in a build from source.** macOS refuses notification registration for
/// > ad-hoc signed bundles — `requestAuthorization` returns `UNErrorDomain` code 1, "Notifications
/// > are not allowed for this application", and the app never appears in System Settings ›
/// > Notifications. `./build.sh` produces exactly such a bundle. Signed, notarized releases are
/// > unaffected. The menu says so rather than silently never notifying.
enum Notifier {
    /// True when notifications are switched on but macOS won't deliver them. Worth surfacing:
    /// without it the app looks like it's watching for the report and simply never says anything.
    private(set) static var blocked = false

    static func requestAuthorizationIfNeeded() {
        guard Prefs.morningNotification else {
            blocked = false
            return
        }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async { blocked = !granted }
            }
    }

    /// Posts the day's summary, if this is a day worth announcing.
    static func announce(_ day: DaySales, rates: FXRates?) {
        guard Prefs.morningNotification,
              Schedule.shouldNotify(about: day, alreadyNotified: Prefs.hasNotified(about: day.date))
        else { return }
        Prefs.markNotified(about: day.date)

        let currency = Prefs.displayCurrency
        let money = rates?.convert(day.proceeds, to: currency).converted
        let units = Metric.units(in: day, metrics: Prefs.metrics)

        let content = UNMutableNotificationContent()
        content.title = "Yesterday: "
            + (money.map { "≈ " + Fmt.money($0, currency: currency) } ?? "—")
            + " · \(Fmt.downloads(units)) downloads"
        content.body = "Report for \(Fmt.reportDate(day.date))."
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: day.date.apiString, content: content, trigger: nil))
    }
}
