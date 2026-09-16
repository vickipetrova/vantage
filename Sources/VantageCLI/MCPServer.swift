import Foundation
import VantageCore

/// A Model Context Protocol server over stdio, so Claude, ChatGPT and anything else that speaks MCP
/// can ask about your App Store numbers directly.
///
/// **Every tool here is a read.** There is no refresh, no reply, no write of any kind, and the
/// process holds no credentials — so the worst an agent can do with this is describe data you
/// already have. That isn't a policy applied at the dispatch table; it's a consequence of what
/// `CacheQuery` can do, which is read files.
///
/// The transport is newline-delimited JSON-RPC 2.0 on stdin/stdout, per MCP's stdio transport.
/// **Nothing may be printed to stdout that isn't a JSON-RPC message** — a stray `print` corrupts the
/// stream and the client drops the connection, which is why diagnostics go to stderr.
struct MCPServer {
    let query: CacheQuery

    private static let protocolVersion = "2024-11-05"

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // A notification has no id and takes no reply — `notifications/initialized` is the
            // common one. Replying to it is a protocol error.
            guard let id = message["id"] else { continue }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                respond(id: id, result: [
                    "protocolVersion": Self.protocolVersion,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "vantage", "version": "0.2.0"],
                ])
            case "tools/list":
                respond(id: id, result: ["tools": Self.tools])
            case "tools/call":
                call(id: id, params: params)
            case "ping":
                respond(id: id, result: [:])
            default:
                respond(id: id, error: -32601, message: "Unknown method '\(method)'")
            }
        }
    }

    // MARK: - Tools

    private static func tool(_ name: String, _ description: String,
                             _ properties: [String: Any] = [:]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                // Nothing is required anywhere: every tool answers something useful with no
                // arguments, which is what an agent tries first.
                "required": [String](),
            ],
        ]
    }

    /// Use one style per call: `range`, `days`, or `from`/`to`. The server refuses a mix rather
    /// than choosing, and says why.
    private static let rangeProperty: [String: Any] = [
        "range": [
            "type": "string",
            "description": "Window ending at the newest cached day: 1d (Apple's most recent "
                + "published day), 7d, 30d, any Nd such as 90d or 365d, or all for everything "
                + "cached. Default 30d. Use get_status to see how far back the cache goes.",
        ],
        "days": [
            "type": "integer",
            "description": "Same as range, as a number: the N days ending at the newest cached day.",
        ],
        "from": [
            "type": "string",
            "description": "First day, YYYY-MM-DD, Pacific report day. Combine with to, or omit to "
                + "for everything after it.",
        ],
        "to": [
            "type": "string",
            "description": "Last day, YYYY-MM-DD, inclusive. Omit from for everything up to it.",
        ],
    ]

    private static let appProperty: [String: Any] = [
        "appleID": ["type": "string", "description": "Restrict to one app's Apple ID."],
    ]

    static let tools: [[String: Any]] = [
        tool("get_sales",
             "Proceeds (what reaches the developer), gross customer sales (what customers paid) "
             + "and download counts for a range. Money is converted to the user's display currency; "
             + "amounts in currencies with no available rate are listed separately rather than "
             + "silently omitted. Report days are Pacific.",
             rangeProperty),
        tool("get_apps",
             "Per-app breakdown for a range: proceeds, downloads, and the app's App Store rating "
             + "and rating count where known.",
             rangeProperty),
        tool("get_reviews",
             "Recent customer reviews across the portfolio, newest first, with any developer reply "
             + "already published. Only reviews the app has fetched are available.",
             appProperty.merging([
                "limit": ["type": "integer", "description": "Maximum reviews to return. Default 20."],
             ]) { a, _ in a }),
        tool("get_analytics",
             "App Store impressions and page views per day, from Apple's Analytics Reports. Empty "
             + "until Apple has generated a report, which takes 24–48 hours after first request.",
             appProperty),
        tool("get_status",
             "How current the cached data is: the newest and oldest report dates, how many days "
             + "are cached, "
             + "the display currency, and how many apps have reviews cached. Call this first if a "
             + "figure looks stale or missing."),
    ]

    // MARK: - Dispatch

    private func call(id: Any, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        /// Clients send `days` as a number or, sometimes, a string. Either reaches the same parser,
        /// so 90.5 is refused there rather than rounded here.
        func text(_ key: String) -> String? {
            switch arguments[key] {
            case let string as String: return string
            case let number as NSNumber: return number.stringValue
            default: return nil
            }
        }
        func range() throws -> QueryRange {
            try QueryRange.parse(range: text("range"), days: text("days"),
                                 from: text("from"), to: text("to"))
        }
        let appleID = arguments["appleID"] as? String

        switch name {
        case "get_sales":
            do {
                guard let snapshot = query.sales(range: try range()) else {
                    return respondText(id: id, "No reports are cached yet.")
                }
                respondJSON(id: id, snapshot)
            } catch {
                respondToolError(id: id, "\(error)")
            }
        case "get_apps":
            do {
                respondJSON(id: id, query.apps(range: try range()))
            } catch {
                respondToolError(id: id, "\(error)")
            }
        case "get_reviews":
            let limit = (arguments["limit"] as? Int) ?? 20
            respondJSON(id: id, query.reviews(appleID: appleID, limit: limit))
        case "get_analytics":
            respondJSON(id: id, query.engagement(appleID: appleID))
        case "get_status":
            respondJSON(id: id, query.status())
        default:
            respond(id: id, error: -32602, message: "Unknown tool '\(name)'")
        }
    }

    // MARK: - Transport

    private func respondJSON<T: Encodable>(id: Any, _ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return respond(id: id, error: -32603, message: "Couldn't encode the result") }
        respondText(id: id, text)
    }

    private func respondText(id: Any, _ text: String) {
        respond(id: id, result: ["content": [["type": "text", "text": text]]])
    }

    /// A tool-level failure, per MCP: a result with `isError`, not a JSON-RPC error. The model
    /// reads it and can correct its arguments; a protocol error is for the client, not the model.
    private func respondToolError(id: Any, _ text: String) {
        respond(id: id, result: ["content": [["type": "text", "text": text]], "isError": true])
    }

    private func respond(id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respond(id: Any, error code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              var text = String(data: data, encoding: .utf8)
        else { return }
        text += "\n"
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
