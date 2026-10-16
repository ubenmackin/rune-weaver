// Rune Weaver Server — Shared query limit parsing for list routes.

import Vapor

/// Bounds an integer limit to the closed range `minLimit...maxLimit`.
func clampLimit(_ raw: Int, min minLimit: Int, max maxLimit: Int) -> Int {
    min(max(raw, minLimit), maxLimit)
}

/// Parses the raw `limit` query string strictly.
func parsedRawQueryLimit(_ req: Request, min minLimit: Int, max maxLimit: Int) throws -> Int? {
    guard let rawString = req.query[String.self, at: "limit"] else {
        return nil
    }
    let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Int(trimmed) else {
        throw Abort(.badRequest, reason: "limit must be an integer between \(minLimit) and \(maxLimit)")
    }
    guard raw >= minLimit, raw <= maxLimit else {
        throw Abort(.badRequest, reason: "limit must be between \(minLimit) and \(maxLimit)")
    }
    return clampLimit(raw, min: minLimit, max: maxLimit)
}

/// Extracts, parses, and validates a query `limit` parameter with a fallback default.
func parseQueryLimit(
    _ req: Request,
    default defaultLimit: Int,
    min minLimit: Int = 1,
    max maxLimit: Int
) throws -> Int {
    if let value = try parsedRawQueryLimit(req, min: minLimit, max: maxLimit) {
        return value
    }
    return defaultLimit
}

/// Extracts, parses, and validates an optional query `limit` parameter.
func parseQueryLimit(
    _ req: Request,
    min minLimit: Int = 1,
    max maxLimit: Int
) throws -> Int? {
    try parsedRawQueryLimit(req, min: minLimit, max: maxLimit)
}
