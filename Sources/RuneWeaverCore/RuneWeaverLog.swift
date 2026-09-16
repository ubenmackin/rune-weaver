// Rune Weaver Core — Centralized structured logging for subsystems.

import Foundation
import Logging

/// Centralized structured logger registry for Rune Weaver subsystems.
public enum RuneWeaverLog {
    /// Logger for durable SQLite and JSON storage subsystems.
    public static let stores = Logger(label: "com.runeweaver.stores")

    /// Logger for loopback HTTP/WebSocket API server and routes.
    public static let server = Logger(label: "com.runeweaver.server")

    /// Logger for tool bus execution, subprocess bridge, and tool-level audits.
    public static let tools = Logger(label: "com.runeweaver.tools")

    /// Logger for memory engine tiers, compaction, and embedding fallbacks.
    public static let memory = Logger(label: "com.runeweaver.memory")

    /// Logger for sandbox staging, reclamation, and confinement.
    public static let sandbox = Logger(label: "com.runeweaver.sandbox")

    /// Logger for scheduler job definitions, triggers, and execution ticks.
    public static let scheduler = Logger(label: "com.runeweaver.scheduler")
}
