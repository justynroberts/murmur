import Foundation

/// `Murmur mcp`: a Model Context Protocol server over stdio, so a coding agent
/// (Claude Code, Cursor, anything that speaks MCP) can read your meeting
/// transcripts and start or stop a meeting. Everything stays on the machine —
/// the agent process is local and reads local files; nothing here talks to a
/// network.
///
///   claude mcp add murmur -- /Applications/Murmur.app/Contents/MacOS/Murmur mcp
///
/// Newline-delimited JSON-RPC 2.0 on stdin/stdout; logging goes to stderr.
enum MCPServer {

    static let protocolVersion = "2024-11-05"

    static func run() -> Never {
        let out = FileHandle.standardOutput
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                write(out, error(id: nil, code: -32700, message: "parse error")); continue
            }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            if id == nil { continue }   // notifications need no reply
            let reply: [String: Any]
            switch method {
            case "initialize":
                reply = result(id: id, [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "murmur", "version": Bundle.main.appVersion],
                ])
            case "ping":
                reply = result(id: id, [:])
            case "tools/list":
                reply = result(id: id, ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                do {
                    let text = try call(name, args)
                    reply = result(id: id, ["content": [["type": "text", "text": text]]])
                } catch {
                    reply = result(id: id, ["content": [["type": "text", "text": "\(error.localizedDescription)"]], "isError": true])
                }
            default:
                reply = error(id: id, code: -32601, message: "unknown method \(method)")
            }
            write(out, reply)
        }
        exit(0)
    }

    // MARK: - Tools

    static let tools: [[String: Any]] = [
        ["name": "list_transcripts",
         "description": "List meeting transcripts Murmur has saved, newest first: file name, title, start, end, length, segments.",
         "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer", "description": "Max entries (default 20)"]]]],
        ["name": "read_transcript",
         "description": "Read one meeting transcript as Markdown. Pass the file name from list_transcripts, or 'latest'.",
         "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]],
        ["name": "search_transcripts",
         "description": "Search all meeting transcripts for a phrase; returns matching files with the surrounding lines.",
         "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer"]], "required": ["query"]]],
        ["name": "start_meeting",
         "description": "Start recording a meeting in the running Murmur app (it transcribes to a Markdown file as it goes).",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "stop_meeting",
         "description": "Stop the meeting Murmur is recording.",
         "inputSchema": ["type": "object", "properties": [:]]],
    ]

    enum ToolError: LocalizedError {
        case unknownTool(String), missing(String), notFound(String)
        var errorDescription: String? {
            switch self {
            case .unknownTool(let n): return "No tool named \(n)."
            case .missing(let a): return "Missing argument: \(a)."
            case .notFound(let n): return "No transcript named \(n)."
            }
        }
    }

    static func call(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "list_transcripts":
            return Transcripts.list(limit: args["limit"] as? Int ?? 20)
        case "read_transcript":
            guard let n = args["name"] as? String, !n.isEmpty else { throw ToolError.missing("name") }
            return try Transcripts.read(n)
        case "search_transcripts":
            guard let q = args["query"] as? String, !q.isEmpty else { throw ToolError.missing("query") }
            return Transcripts.search(q, limit: args["limit"] as? Int ?? 10)
        case "start_meeting":
            DistributedNotificationCenter.default().postNotificationName(MeetingRecorder.notificationName, object: "start", userInfo: nil, deliverImmediately: true)
            return "Asked Murmur to start a meeting. It records until stopped; the transcript grows in \(Transcripts.folder.path)."
        case "stop_meeting":
            DistributedNotificationCenter.default().postNotificationName(MeetingRecorder.notificationName, object: "stop", userInfo: nil, deliverImmediately: true)
            return "Asked Murmur to stop the meeting."
        default:
            throw ToolError.unknownTool(name)
        }
    }

    // MARK: - Plumbing

    private static func result(id: Any?, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }
    private static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
    private static func write(_ out: FileHandle, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        out.write(data); out.write("\n".data(using: .utf8)!)
    }
}

/// The transcript folder as text, for the MCP server and the command line.
/// Reads the app's setting so it follows the folder chosen in Settings;
/// MURMUR_TRANSCRIPTS overrides it, which the tests use.
enum Transcripts {
    static var folder: URL {
        if let env = ProcessInfo.processInfo.environment["MURMUR_TRANSCRIPTS"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let path = UserDefaults(suiteName: "com.fintonlabs.murmur")?.string(forKey: "transcriptFolder") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
    }

    static func items() -> [TranscriptItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("Meeting ") }
            .compactMap { TranscriptStore.item(at: $0) }
            .sorted { $0.started > $1.started }
    }

    static func list(limit: Int) -> String {
        let all = items()
        guard !all.isEmpty else { return "No transcripts in \(folder.path)." }
        return all.prefix(max(1, limit)).map { i in
            var parts = ["\(i.fileName)", i.title]
            if let s = i.startedClock { parts.append("started \(s)") }
            if let e = i.endedClock { parts.append("ended \(e)") } else { parts.append("in progress") }
            if let l = i.length { parts.append(l) }
            if let n = i.segments { parts.append("\(n) segments") }
            return parts.joined(separator: " · ")
        }.joined(separator: "\n")
    }

    static func read(_ name: String) throws -> String {
        let all = items()
        let item: TranscriptItem?
        if name.lowercased() == "latest" { item = all.first }
        else { item = all.first { $0.fileName == name || $0.fileName == name + ".md" || $0.url.deletingPathExtension().lastPathComponent == name } }
        guard let item else { throw MCPServer.ToolError.notFound(name) }
        return (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
    }

    static func search(_ query: String, limit: Int) -> String {
        let q = query.lowercased()
        var hits: [String] = []
        for item in items() {
            let text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (n, line) in lines.enumerated() where line.lowercased().contains(q) {
                let ctx = lines[max(0, n - 1)...min(lines.count - 1, n + 1)].joined(separator: " ")
                hits.append("\(item.fileName): \(ctx.trimmingCharacters(in: .whitespaces))")
                if hits.count >= max(1, limit) { break }
            }
            if hits.count >= max(1, limit) { break }
        }
        return hits.isEmpty ? "No transcript mentions \"\(query)\"." : hits.joined(separator: "\n")
    }
}
