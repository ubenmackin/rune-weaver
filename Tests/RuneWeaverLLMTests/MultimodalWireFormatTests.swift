// Rune Weaver LLM Tests — Multimodal wire formatting and provider supportsVision tests.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverLLM
import Testing

@Suite("Multimodal Wire Format and Provider Vision")
struct MultimodalWireFormatTests {
    @Test
    func `LLMProviderFactory propagates supportsVision to LlamaCppProvider and OpenAICompatibleProvider`() {
        // LlamaCpp: default false, explicit true
        let llamaDefault = LLMProviderFactory.makeProvider(
            entryName: "local",
            config: ProviderConfig(enabled: true, providerType: "llamacpp")
        )
        #expect(llamaDefault?.modelInfo.supportsVision == false)

        let llamaVision = LLMProviderFactory.makeProvider(
            entryName: "local",
            config: ProviderConfig(enabled: true, providerType: "llamacpp", supportsVision: true)
        )
        #expect(llamaVision?.modelInfo.supportsVision == true)

        // MLX: default false, explicit true propagates instead of dropping
        let mlxDefault = LLMProviderFactory.makeProvider(
            entryName: "mlx",
            config: ProviderConfig(enabled: true, providerType: "mlx")
        )
        #expect(mlxDefault?.modelInfo.supportsVision == false)

        let mlxVision = LLMProviderFactory.makeProvider(
            entryName: "mlx",
            config: ProviderConfig(enabled: true, providerType: "mlx", supportsVision: true)
        )
        #expect(mlxVision?.modelInfo.supportsVision == true)

        // OpenAI-compatible: default true, explicit false
        let openAIDefault = LLMProviderFactory.makeProvider(
            entryName: "openrouter",
            config: ProviderConfig(enabled: true, providerType: "openai")
        )
        #expect(openAIDefault?.modelInfo.supportsVision == true)

        let openAITextOnly = LLMProviderFactory.makeProvider(
            entryName: "openrouter",
            config: ProviderConfig(enabled: true, providerType: "openai", supportsVision: false)
        )
        #expect(openAITextOnly?.modelInfo.supportsVision == false)
    }

    @Test
    func `openAIChatRequestBody injects user image_url following tool screenshot result`() throws {
        let callID = "call_screenshot_1"
        let screenshotJSON = """
        {
          "displayIndex" : 0,
          "scaledHeight" : 832,
          "scaledWidth" : 1280,
          "screenshotDataURL" : "data:image\\/jpeg;base64,\\/9j\\/4AAQSkZJRg==",
          "screenshotHash" : "hash_xyz"
        }
        """

        let messages = [
            Message(role: .user, content: "Take a screenshot"),
            Message(role: .assistant, content: ToolInput.placeholderContent(for: [
                ToolInput(toolName: "desktop.screenshot", argumentsJSON: "{}", callID: callID)
            ])),
            Message(role: .tool, content: screenshotJSON, toolCallID: callID)
        ]

        let bodyData = try openAIChatRequestBody(
            model: "qwen-3.6",
            messages: messages,
            tools: [],
            stream: true
        )

        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let wireMessages = try #require(json?["messages"] as? [[String: Any]])

        // Expect: 0: user "Take a screenshot" 1: assistant with tool_calls 2: tool with cleaned
        // metadata string (no huge base64) 3: injected user message with image_url
        try #require(wireMessages.count == 4)

        let toolMsg = wireMessages[2]
        #expect((toolMsg["role"] as? String) == "tool")
        #expect((toolMsg["tool_call_id"] as? String) == callID)
        let toolContent = try #require(toolMsg["content"] as? String)
        #expect(toolContent.contains("\"screenshotDataURL\": \"[image attached]\""))
        #expect(!toolContent.contains("/9j/4AAQSkZJRg=="))

        let injectedUserMsg = wireMessages[3]
        #expect((injectedUserMsg["role"] as? String) == "user")
        let contentParts = try #require(injectedUserMsg["content"] as? [[String: Any]])
        try #require(contentParts.count == 2)
        #expect((contentParts[0]["type"] as? String) == "text")
        #expect((contentParts[1]["type"] as? String) == "image_url")
        let imgObj = try #require(contentParts[1]["image_url"] as? [String: Any])
        #expect((imgObj["url"] as? String) == "data:image/jpeg;base64,/9j/4AAQSkZJRg==")
    }

    @Test
    func `openAIChatRequestBody splits user message with inline data URL into text and image_url`() throws {
        let messages = [
            Message(role: .user, content: "Describe this image:\ndata:image/jpeg;base64,/9j/4AAQSkZJRg==")
        ]

        let bodyData = try openAIChatRequestBody(
            model: "qwen-3.6",
            messages: messages,
            tools: [],
            stream: true
        )

        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let wireMessages = try #require(json?["messages"] as? [[String: Any]])
        try #require(wireMessages.count == 1)

        let userMsg = wireMessages[0]
        #expect((userMsg["role"] as? String) == "user")
        let contentParts = try #require(userMsg["content"] as? [[String: Any]])
        try #require(contentParts.count == 2)
        #expect((contentParts[0]["type"] as? String) == "text")
        #expect((contentParts[0]["text"] as? String) == "Describe this image:")
        #expect((contentParts[1]["type"] as? String) == "image_url")
        let imgObj = try #require(contentParts[1]["image_url"] as? [String: Any])
        #expect((imgObj["url"] as? String) == "data:image/jpeg;base64,/9j/4AAQSkZJRg==")
    }

    @Test
    func `openAIChatRequestBody preserves plain string content when no images present`() throws {
        let messages = [
            Message(role: .user, content: "Hello world"),
            Message(role: .tool, content: #"{"result":"ok"}"#, toolCallID: "call_1")
        ]

        let bodyData = try openAIChatRequestBody(
            model: "gpt-4o",
            messages: messages,
            tools: [],
            stream: false
        )

        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let wireMessages = try #require(json?["messages"] as? [[String: Any]])
        try #require(wireMessages.count == 2)

        #expect(wireMessages[0]["content"] as? String == "Hello world")
        #expect(wireMessages[1]["content"] as? String == #"{"result":"ok"}"#)
    }

    @Test
    func `openAIResponsesRequestBody injects user input_image following tool screenshot result`() throws {
        let callID = "call_screenshot_1"
        let screenshotJSON = """
        {
          "displayIndex" : 0,
          "scaledHeight" : 832,
          "scaledWidth" : 1280,
          "screenshotDataURL" : "data:image\\/jpeg;base64,\\/9j\\/4AAQSkZJRg==",
          "screenshotHash" : "hash_xyz"
        }
        """

        let messages = [
            Message(role: .user, content: "Take a screenshot"),
            Message(role: .assistant, content: ToolInput.placeholderContent(for: [
                ToolInput(toolName: "desktop.screenshot", argumentsJSON: "{}", callID: callID)
            ])),
            Message(role: .tool, content: screenshotJSON, toolCallID: callID)
        ]

        let bodyData = try openAIResponsesRequestBody(
            model: "qwen-3.6",
            messages: messages,
            tools: [],
            stream: true
        )

        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let wireInput = try #require(json?["input"] as? [[String: Any]])

        // Expect user text plus function_call plus function_call_output plus
        // an injected user message carrying the image part.
        try #require(wireInput.count == 4)

        let outputMsg = wireInput[2]
        #expect((outputMsg["type"] as? String) == "function_call_output")
        #expect((outputMsg["call_id"] as? String) == callID)
        let outputText = try #require(outputMsg["output"] as? String)
        #expect(outputText.contains("\"screenshotDataURL\": \"[image attached]\""))
        #expect(!outputText.contains("/9j/4AAQSkZJRg=="))

        let injectedUserMsg = wireInput[3]
        #expect((injectedUserMsg["role"] as? String) == "user")
        let contentParts = try #require(injectedUserMsg["content"] as? [[String: Any]])
        try #require(contentParts.count == 2)
        #expect((contentParts[0]["type"] as? String) == "input_text")
        #expect((contentParts[1]["type"] as? String) == "input_image")
        #expect((contentParts[1]["image_url"] as? String) == "data:image/jpeg;base64,/9j/4AAQSkZJRg==")
    }

    @Test
    func `openAIResponsesRequestBody splits user message with inline data URL into text and input_image`() throws {
        let messages = [
            Message(role: .user, content: "Describe this image:\ndata:image/jpeg;base64,/9j/4AAQSkZJRg==")
        ]

        let bodyData = try openAIResponsesRequestBody(
            model: "qwen-3.6",
            messages: messages,
            tools: [],
            stream: true
        )

        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let wireInput = try #require(json?["input"] as? [[String: Any]])
        try #require(wireInput.count == 1)

        let userMsg = wireInput[0]
        #expect((userMsg["role"] as? String) == "user")
        let contentParts = try #require(userMsg["content"] as? [[String: Any]])
        try #require(contentParts.count == 2)
        #expect((contentParts[0]["type"] as? String) == "input_text")
        #expect((contentParts[0]["text"] as? String) == "Describe this image:")
        #expect((contentParts[1]["type"] as? String) == "input_image")
        #expect((contentParts[1]["image_url"] as? String) == "data:image/jpeg;base64,/9j/4AAQSkZJRg==")
    }

    @Test
    func `openAIResponsesRequestBody preserves plain content when no images present`() throws {
        let messages = [
            Message(role: .user, content: "Hello world"),
            Message(role: .tool, content: #"{"result":"ok"}"#, toolCallID: "call_1")
        ]

        let bodyData = try openAIResponsesRequestBody(
            model: "gpt-4o",
            messages: messages,
            tools: [],
            stream: false
        )

        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let wireInput = try #require(json?["input"] as? [[String: Any]])
        try #require(wireInput.count == 2)

        let userMsg = wireInput[0]
        #expect((userMsg["role"] as? String) == "user")
        let userParts = try #require(userMsg["content"] as? [[String: Any]])
        try #require(userParts.count == 1)
        #expect((userParts[0]["type"] as? String) == "input_text")
        #expect((userParts[0]["text"] as? String) == "Hello world")

        let outputMsg = wireInput[1]
        #expect((outputMsg["type"] as? String) == "function_call_output")
        #expect((outputMsg["output"] as? String) == #"{"result":"ok"}"#)
    }
}
