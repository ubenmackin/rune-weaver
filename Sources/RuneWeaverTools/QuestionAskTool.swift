// Rune Weaver Tools — Operator question tool (`question.ask`).
//
// Purpose: pauses the agent's turn and solicits operator input when encountering
// multiple candidate matches or ambiguous directions, preventing unauthorized default actions.

import Foundation
import RuneWeaverCore

/// Arguments for `question.ask`.
public struct QuestionAskArgs: Sendable, Codable, Equatable {
    public let question: String
    public let options: [String]

    public init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }
}

/// Tool for asking the operator a multiple-choice question to clarify ambiguous intent
/// or choose between candidate options before taking action.
public struct QuestionAskTool: Tool, Sendable {
    public let name = "question.ask"
    public let description =
        "Asks the operator a multiple-choice question to clarify ambiguous intent, choose between multiple candidates, "
            + "or confirm preferences. Execution pauses until the operator responds or cancels."

    public let inputSchema = JSONSchema(
        rawValue: """
        {
          "type": "object",
          "properties": {
            "question": {
              "type": "string",
              "description": "The question to ask the operator."
            },
            "options": {
              "type": "array",
              "items": { "type": "string" },
              "minItems": 2,
              "maxItems": 4,
              "description": "2 to 4 candidate options. Do not include 'Other'; write-in is provided automatically."
            }
          },
          "required": ["question", "options"],
          "additionalProperties": false
        }
        """
    )

    public let permissionLevel = PermissionLevel.requiresApproval

    public init() {}

    public func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        if case let .refuse(reason) = await admissionVerdict(for: input) {
            return .failure(reason, callID: input.callID)
        }
        let trimmedQuestion = try JSONDecoder().decode(QuestionAskArgs.self, from: Data(input.argumentsJSON.utf8))
            .question.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success("Question presented to operator: \"\(trimmedQuestion)\"", callID: input.callID)
    }
}

extension QuestionAskTool: ToolAdmissionValidating {
    /// Refuses malformed questions before the call can park for approval.
    ///
    /// The turn loop consults this before the permission gate and before any
    /// approval row is filed, so an empty question or an out-of-range option
    /// list fails fast instead of interrupting the operator.
    /// - Parameter input: Raw `question.ask` invocation.
    /// - Returns: `.refuse` with the caller-facing reason, or `.proceed`.
    public func admissionVerdict(for input: ToolInput) async -> ToolAdmissionVerdict {
        guard let data = input.argumentsJSON.data(using: .utf8) else {
            return .refuse(reason: "Invalid arguments for question.ask: invalid UTF-8 string.")
        }
        let args: QuestionAskArgs
        do {
            args = try JSONDecoder().decode(QuestionAskArgs.self, from: data)
        } catch {
            return .refuse(
                reason: "Invalid arguments for question.ask: expected 'question' (string) "
                    + "and 'options' (array of 2-4 strings): \(error.localizedDescription)"
            )
        }
        let trimmedQuestion = args.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            return .refuse(reason: "question.ask requires a non-empty question string.")
        }
        guard args.options.count >= 2, args.options.count <= 4 else {
            return .refuse(reason: "question.ask requires between 2 and 4 options.")
        }
        return .proceed
    }
}
