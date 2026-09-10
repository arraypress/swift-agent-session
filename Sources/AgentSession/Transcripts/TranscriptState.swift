//
//  TranscriptState.swift
//  SwiftAgentSession
//
//  The accumulated parse state for one Claude Code JSONL transcript: per-line
//  ingestion plus materialization of the usage / events / summary results.
//
//  Created by David Sherlock on 7/16/26.
//

import Foundation

/// The accumulated parse state for one Claude Code JSONL transcript: running cost and token
/// totals, the current and peak context size, the model in use, and the message ids already
/// counted, so a re-read after an append never double counts.
struct TranscriptState {

    /// Explicit rather than memberwise, because the private accumulators below would make a
    /// synthesised init private and unreachable from the cache.
    init() {}


    // MARK: - Usage accumulators

    /// Estimated spend so far, in US dollars.
    private var cost = 0.0

    /// Total output tokens across deduplicated API responses.
    private var totalOut = 0

    /// The most recent non-zero context window (input + cache + output tokens).
    private var curCtx = 0

    /// The largest context window seen (drives the 200k-vs-1M limit guess).
    private var maxCtx = 0

    /// The most recent real model name seen (drives pricing).
    private var model = "claude"

    /// `message.id` / `requestId` values already priced. Claude Code writes one
    /// JSONL line per assistant content block, each repeating the same message
    /// id and an identical usage object — each API response must count once.
    private var seenMessageIDs = Set<String>()

    // MARK: - Events buffer

    /// The public events cap: only the most recent 300 events are reported.
    private static let eventCap = 300

    /// The activity timeline, oldest first, trimmed live to ``eventCap`` so the
    /// buffer stays bounded no matter how long the session runs. Trimming as we
    /// go is equivalent to parsing everything and taking `suffix(300)`.
    private var events: [TimelineEvent] = []

    // MARK: - Summary accumulators

    /// Absolute paths of every file an edit tool wrote to.
    private var edited = Set<String>()

    /// The most recent `TodoWrite` list, as `(text, status)` pairs (last wins).
    private var todos: [(String, String)] = []

    // MARK: - Ingestion

    /// Folds one complete transcript line into the state.
    ///
    /// The line is parsed as raw JSON bytes (JSONL is UTF-8 by spec); malformed
    /// or non-object lines are skipped, never fatal. All three result streams
    /// (usage / events / summary) are updated from the single parse.
    mutating func ingest(lineData: Data) {
        guard let obj = JSONFile.object(from: lineData) else { return }
        ingestUsage(obj)
        ingestEvent(obj)
        ingestSummary(obj)
    }

    /// Updates the token/cost accumulators from one parsed line.
    private mutating func ingestUsage(_ obj: [String: Any]) {
        guard let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return }
        if let m = msg["model"] as? String, !m.isEmpty, m != "<synthetic>" { model = m }
        let inp = usage["input_tokens"] as? Int ?? 0
        let cw = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cr = usage["cache_read_input_tokens"] as? Int ?? 0
        let out = usage["output_tokens"] as? Int ?? 0
        let id = (msg["id"] as? String) ?? (obj["requestId"] as? String)
        let isDuplicate = id.map { !seenMessageIDs.insert($0).inserted } ?? false
        if !isDuplicate {
            cost += ModelPricing.cost(model: model, input: inp, cacheWrite: cw, cacheRead: cr, output: out)
            totalOut += out
        }
        // Duplicates carry identical values, so the context window is safe to update.
        let ctx = inp + cw + cr + out
        if ctx > 0 { curCtx = ctx }
        maxCtx = max(maxCtx, ctx)
    }

    /// Appends this line's timeline events (if any), keeping the buffer capped.
    private mutating func ingestEvent(_ obj: [String: Any]) {
        guard let msg = obj["message"] as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""
        let ts = Self.shortTime(obj["timestamp"] as? String)

        if type == "user" {
            if let s = msg["content"] as? String, !s.hasPrefix("<") {
                append(TimelineEvent(kind: .userPrompt, title: "You", detail: Self.firstLine(s), filePath: nil, timestamp: ts))
            } else if let arr = msg["content"] as? [[String: Any]] {
                let texts = arr.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
                if !texts.isEmpty {
                    append(TimelineEvent(kind: .userPrompt, title: "You", detail: Self.firstLine(texts.joined(separator: " ")), filePath: nil, timestamp: ts))
                }
            }
        } else if type == "assistant", let arr = msg["content"] as? [[String: Any]] {
            for block in arr {
                switch block["type"] as? String {
                case "text":
                    if let t = (block["text"] as? String)?.trimmed, !t.isEmpty {
                        append(TimelineEvent(kind: .assistantText, title: "Claude", detail: Self.firstLine(t), filePath: nil, timestamp: ts))
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    let (detail, path) = Self.toolDetail(input)
                    let isEdit = Self.editTools.contains(name)
                    append(TimelineEvent(kind: isEdit ? .fileEdit : .toolUse, title: name, detail: detail, filePath: path, timestamp: ts,
                                         anchor: isEdit ? Self.editAnchor(input) : nil))
                default: break
                }
            }
        }
    }

    /// Appends one event and trims the buffer to the cap.
    private mutating func append(_ event: TimelineEvent) {
        events.append(event)
        if events.count > Self.eventCap { events.removeFirst(events.count - Self.eventCap) }
    }

    /// Updates the edited-files set and the current to-do list from one line.
    private mutating func ingestSummary(_ obj: [String: Any]) {
        guard obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let arr = msg["content"] as? [[String: Any]] else { return }
        for block in arr where block["type"] as? String == "tool_use" {
            let name = block["name"] as? String ?? ""
            let input = block["input"] as? [String: Any] ?? [:]
            // NotebookEdit's parameter is notebook_path, not file_path.
            if Self.editTools.contains(name),
               let fp = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) { edited.insert(fp) }
            // Tolerate a heterogeneous todos array: one malformed element must
            // not drop the valid ones (cast per element, not the whole array).
            if name == "TodoWrite", let ts = input["todos"] as? [Any] {
                todos = ts.compactMap { item in
                    guard let t = item as? [String: Any],
                          let c = t["content"] as? String else { return nil }
                    return (c, (t["status"] as? String) ?? "pending")
                }
            }
        }
    }

    // MARK: - Materialization

    /// The usage telemetry as the public API reports it, or `nil` when the
    /// transcript carries no usage records at all.
    var usageResult: AgentUsage? {
        guard maxCtx > 0 else { return nil }
        // Claude does not publish the window, so it is inferred from the largest context observed.
        let limit = maxCtx > 200_000 ? 1_000_000 : 200_000
        return AgentUsage(contextTokens: curCtx, contextLimit: limit, outputTokens: totalOut, costUSD: cost)
    }

    /// The activity timeline as the public API reports it (last 300, oldest first).
    var eventsResult: [TimelineEvent] { Array(events.suffix(Self.eventCap)) }

    /// The edited-files / to-dos roll-up as the public API reports it.
    var summaryResult: AgentSummary { AgentSummary(editedFiles: edited, todos: todos) }

    // MARK: - Static helpers (shared parsing vocabulary)

    /// The tools that write to a file on disk. Read-only tools (Read, Grep, Glob, LS)
    /// also carry a path but must NOT be classified as ``TimelineEvent/Kind/fileEdit``.
    private static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]


    /// Derives a one-line detail string (and a navigable path, when the input
    /// carries one) from a tool call's input dictionary.
    private static func toolDetail(_ input: [String: Any]) -> (String, String?) {
        if let fp = input["file_path"] as? String { return (shortPath(fp), fp) }
        if let np = input["notebook_path"] as? String { return (shortPath(np), np) }
        if let p = input["path"] as? String { return (shortPath(p), p) }
        if let cmd = input["command"] as? String { return (firstLine(cmd, 120), nil) }
        if let pat = input["pattern"] as? String { return (pat, nil) }
        if let q = input["query"] as? String { return (firstLine(q, 120), nil) }
        return ("", nil)
    }

    /// A distinctive line of the text an edit inserts, to locate where the edit landed.
    /// `Edit` → its `new_string`; `MultiEdit` → the *last* sub-edit's `new_string` (where
    /// the agent finished); `Write`/`NotebookEdit` → nil (whole-file, no single anchor).
    /// Returns the first inserted line long enough to be findable (skips braces/blanks).
    private static func editAnchor(_ input: [String: Any]) -> String? {
        let source: String?
        if let ns = input["new_string"] as? String {
            source = ns
        } else if let edits = input["edits"] as? [[String: Any]],
                  let last = edits.last, let ns = last["new_string"] as? String {
            source = ns
        } else {
            source = nil
        }
        guard let text = source else { return nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.count >= 4 { return String(t.prefix(200)) }
        }
        return nil
    }

    /// The trimmed first line of `s`, truncated to `max` characters with an ellipsis.
    /// Internal (not private) so every adapter shares one truncation rule.
    static func firstLine(_ s: String, _ max: Int = 160) -> String {
        let line = s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }

    /// Compresses an absolute path to its last two components (`.../Dir/File.swift`).
    private static func shortPath(_ p: String) -> String {
        let parts = p.split(separator: "/")
        return parts.count <= 2 ? p : ".../" + parts.suffix(2).joined(separator: "/")
    }

    /// ISO-8601 with fractional seconds ("2026-07-09T10:07:12.000Z") — the form
    /// Claude Code writes. Falls back to `isoPlain` for whole-second timestamps.
    // Apple documents ISO8601DateFormatter as safe for concurrent USE once configured; it
    // is simply not annotated Sendable. Both of these are configured here and only ever
    // read, so the assertion is about this usage, not the class in general.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Whole-second ISO-8601 fallback ("2026-07-09T10:07:12Z").
    private nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    /// Renders a `Date` as `HH:mm` on the viewer's local clock.
    /// Transcript timestamps are UTC Zulu — convert to the viewer's local clock,
    /// falling back to the raw UTC HH:MM slice only if the string is unparseable.
    /// Internal (not private) so every adapter shares one time-rendering rule.
    static func shortTime(_ iso: String?) -> String {
        guard let iso else { return "" }
        if let date = isoFractional.date(from: iso) ?? isoPlain.date(from: iso) {
            return ClockFormat.hhmm(date)
        }
        guard let tPart = iso.split(separator: "T").dropFirst().first else { return "" }
        return String(tPart.prefix(5))
    }
}
