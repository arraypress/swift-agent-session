//
//  Agents.swift
//  SwiftAgentSession
//
//  The adapter registry and project auto-detection entry point. Add support for
//  an agent by appending its adapter to `all`.
//
//  Created by David Sherlock on 7/9/26.
//

import Foundation

/// Registry of known agent adapters plus project auto-detection.
///
/// Adding support for a new agent is a one-line change: append its
/// ``AgentAdapter`` to ``all``.
public enum Agents {

    /// Every adapter known to the library, in detection order.
    ///
    /// **Claude Code only, deliberately (11 Sep 2026).** Adapters for Codex CLI, Gemini CLI and
    /// OpenCode were written from each tool's published schema and tested against fixtures typed
    /// out by hand from that schema — never against a real session of the tool they claimed to
    /// read, because none of them was installed. Three separate integrations drifted silently in
    /// one afternoon (a renamed Claude tool, a moved binary path in every installed hook entry,
    /// and the Skills catalog before them), so an adapter nobody can run is a guess that reports
    /// "no session" forever and tells no one. Recover them with
    /// `git log --all -- Sources/AgentSession/Adapters`. Adding an agent back is still a one-line
    /// change here — but only bring one back with fixtures captured from a REAL run of it.
    public static let all: [AgentAdapter] = [
        ClaudeCodeAdapter(),
    ]

    /// The first adapter that has a session for `root` (first match wins), or
    /// `nil` when no known agent has one.
    public static func active(for root: URL) -> AgentAdapter? {
        active(for: root, in: all)
    }

    /// Test seam: the same first-match detection over an explicit adapter list,
    /// so tests can inject adapters rooted at a temp directory.
    static func active(for root: URL, in adapters: [AgentAdapter]) -> AgentAdapter? {
        adapters.first { $0.hasSession(for: root) }
    }

    /// The first of `candidates`, in order, that some adapter has a session for —
    /// with that adapter. Order candidates most specific first: the cwd of a
    /// terminal running an agent (Claude Code files a transcript under its OWN cwd
    /// at launch — whatever folder the shell happened to be in), then the opened
    /// folder, its repo root, its parent. Looking up the opened folder alone found
    /// nothing while an agent launched from a subfolder was working in plain sight.
    public static func resolve(candidates: [URL]) -> (adapter: AgentAdapter, root: URL)? {
        resolve(candidates: candidates, in: all)
    }

    /// Test seam for ``resolve(candidates:)`` over an explicit adapter list.
    static func resolve(candidates: [URL], in adapters: [AgentAdapter]) -> (adapter: AgentAdapter, root: URL)? {
        for root in candidates {
            if let adapter = active(for: root, in: adapters) { return (adapter, root) }
        }
        return nil
    }
}
