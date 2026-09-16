import Foundation
import VantageCore

/// `vantage` — read-only access to what the app has already fetched.
///
/// Two audiences, one implementation: a person at a terminal, and an AI agent over MCP
/// (`vantage mcp`). Both go through `CacheQuery`, which reads the on-disk cache and nothing else.
///
/// **It holds no credentials and opens no sockets.** That is the entire security story: this binary
/// cannot refresh anything, cannot publish anything, and cannot reach App Store Connect. Point an
/// agent at it and the worst it can do is read numbers you already have.
enum CLI {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(usage)
            exit(0)
        }
        arguments.removeFirst()

        let json = arguments.contains("--json")
        let range = parseRange(arguments)
        let query = CacheQuery()

        switch command {
        case "sales":
            guard let snapshot = query.sales(range: range) else {
                fail("No reports cached yet. Open Vantage and let it fetch.")
            }
            json ? emit(snapshot) : printSales(snapshot)

        case "apps":
            let apps = query.apps(range: range)
            json ? emit(apps) : printApps(apps, range: range)

        case "reviews":
            let reviews = query.reviews(appleID: value(of: "--app", in: arguments),
                                        limit: Int(value(of: "--limit", in: arguments) ?? "") ?? 20)
            json ? emit(reviews) : printReviews(reviews)

        case "analytics":
            let days = query.engagement(appleID: value(of: "--app", in: arguments))
            json ? emit(days) : printEngagement(days)

        case "status":
            let status = query.status()
            json ? emit(status) : printStatus(status)

        case "mcp":
            MCPServer(query: query).run()

        case "-h", "--help", "help":
            print(usage)

        default:
            fail("Unknown command '\(command)'.\n\n\(usage)")
        }
    }

    // MARK: - Arguments

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    private static func parseRange(_ arguments: [String]) -> OverviewRange {
        switch value(of: "--range", in: arguments)?.lowercased() {
        case "1d", "yesterday", "day": return .yesterday
        case "7d", "week": return .week
        case "30d", "month": return .month
        // Defaults to the widest, because a question asked without a range is almost always
        // "how am I doing" rather than "what happened yesterday".
        default: return .month
        }
    }

    // MARK: - Output

    private static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { fail("Couldn't encode that.") }
        print(text)
    }

    private static func money(_ amount: Decimal?, _ currency: String) -> String {
        amount.map { Fmt.money($0, currency: currency) } ?? "—"
    }

    private static func printSales(_ s: CacheQuery.SalesSnapshot) {
        print("\(s.from) → \(s.to)  (\(s.daysCached) of \(s.daysInRange) days cached)")
        print("  proceeds   \(money(s.proceeds, s.displayCurrency))")
        print("  sales      \(money(s.sales, s.displayCurrency))")
        print("  downloads  \(Fmt.downloads(s.downloads))")
        if let comparison = s.comparison { print("  \(comparison)") }
        for (code, amount) in s.unconverted.sorted(by: { $0.key < $1.key }) {
            print("  not converted: \(Fmt.money(amount, currency: code))")
        }
    }

    private static func printApps(_ apps: [CacheQuery.AppSnapshot], range: OverviewRange) {
        guard !apps.isEmpty else { return print("No apps cached yet.") }
        let currency = Prefs.displayCurrency
        for app in apps {
            var line = "  \(app.title)  \(money(app.proceeds, currency))"
                + "  \(Fmt.downloads(app.downloads))↓"
            if let rating = app.averageRating {
                line += "  ★\(Fmt.rating(rating))"
                if let count = app.ratingCount { line += " (\(count))" }
            }
            print(line)
        }
    }

    private static func printReviews(_ reviews: [CacheQuery.ReviewSnapshot]) {
        guard !reviews.isEmpty else {
            return print("No reviews cached. Open the Reviews section in Vantage first.")
        }
        for review in reviews {
            print("  \(String(repeating: "★", count: review.rating))"
                  + "\(String(repeating: "☆", count: 5 - review.rating))"
                  + "  \(review.appTitle)  \(review.date.prefix(10))  \(review.territory)")
            if !review.title.isEmpty { print("    \(review.title)") }
            if !review.body.isEmpty { print("    \(review.body)") }
            if let response = review.response {
                print("    ↳ replied: \(response)")
            }
            print("")
        }
    }

    private static func printEngagement(_ days: [CacheQuery.EngagementSnapshot]) {
        guard !days.isEmpty else {
            return print("No analytics cached. Apple takes 24–48h to produce the first report.")
        }
        for day in days {
            print("  \(day.date)  \(Fmt.downloads(day.impressions)) impressions"
                  + "  \(Fmt.downloads(day.pageViews)) page views")
        }
    }

    private static func printStatus(_ status: CacheQuery.StatusSnapshot) {
        print("  \(status.headline)")
        print("  newest report   \(status.newestReport ?? "none")")
        print("  days cached     \(status.daysCached)")
        print("  currency        \(status.displayCurrency)")
        print("  ECB rates       \(status.ratesPublished ?? "none cached")")
        print("  reviews cached  \(status.appsWithReviewsCached) app(s)")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static let usage = """
    vantage-cli — read what the Vantage app has already fetched. Read-only: no credentials, no network.

    USAGE
      vantage-cli <command> [--range 1d|7d|30d] [--json]

    COMMANDS
      sales       Proceeds, gross sales and downloads for a range
      apps        Per-app breakdown, with App Store ratings
      reviews     Recent customer reviews  [--app <appleID>] [--limit N]
      analytics   App Store impressions and page views  [--app <appleID>]
      status      How current the cache is
      mcp         Speak MCP over stdio, for Claude, ChatGPT and other agents

    EXAMPLES
      vantage-cli sales --range 7d
      vantage-cli apps --json | jq '.[0]'
      vantage-cli reviews --limit 5

    MCP
      Claude Code:
        claude mcp add vantage --scope user -- ~/.local/bin/vantage-cli mcp

      Claude Desktop — ~/Library/Application Support/Claude/claude_desktop_config.json,
      then quit and reopen it:
        { "mcpServers": { "vantage": {
            "command": "/Users/YOU/.local/bin/vantage-cli", "args": ["mcp"] } } }

      Use the full path. Apps launched from the Dock don't inherit your shell PATH, so a
      bare command works in a terminal and silently fails in Claude Desktop.
    """
}

CLI.main()
