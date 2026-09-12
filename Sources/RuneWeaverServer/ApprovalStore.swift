// Rune Weaver Server — Approval store typealiases and REST/WebSocket bridge.
//
// Exposes the core `ApprovalQueue` and `ApprovalQueueDecision` types under the
// server namespace, maintaining source-level compatibility while ensuring REST
// and WebSocket handlers share the identical approval state in memory.

import Foundation
import RuneWeaverCore

/// Pending approval prompts shared by REST and WebSocket.
///
/// The server reuses the core ``ApprovalQueue`` directly so REST
/// (`GET /approvals`, `POST /approvals/:id/decide`) and the WebSocket live
/// prompt surface read and resolve the same queue with one implementation.
/// `ApprovalStore` and `ApprovalDecision` remain as source-compatible
/// aliases for the core queue and its decision; new code should name
/// `ApprovalQueue` and `ApprovalQueueDecision` directly.
public typealias ApprovalStore = ApprovalQueue

/// Decision resolving one pending approval.
///
/// Source-compatible alias for ``ApprovalQueueDecision``. New code should
/// name `ApprovalQueueDecision` directly.
public typealias ApprovalDecision = ApprovalQueueDecision
