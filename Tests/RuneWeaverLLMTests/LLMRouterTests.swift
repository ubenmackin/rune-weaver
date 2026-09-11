@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

@Suite("LLM Router")
struct LLMRouterTests {
    @Test
    func `Empty router streams nothing`() async {
        let router = LLMRouter()
        var count = 0
        for await _ in await router.chat(messages: [], tools: []) {
            count += 1
        }
        #expect(count == 0)
    }
}
