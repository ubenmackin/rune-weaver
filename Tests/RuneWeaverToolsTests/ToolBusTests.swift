import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

@Suite("Tool Bus")
struct ToolBusTests {
    @Test
    func `Unknown tool returns error result`() async {
        let bus = ToolBus()
        let input = ToolInput(toolName: "missing", argumentsJSON: "{}")
        let context = ToolContext(conversationID: UUID())
        let result = await bus.execute(toolCall: input, context: context)
        #expect(result.isError == true)
    }
}
