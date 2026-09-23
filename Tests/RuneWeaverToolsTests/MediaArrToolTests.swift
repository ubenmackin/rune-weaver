// Rune Weaver Tools Tests — MediaArrTool behavior and client coverage.

import Foundation
@testable import RuneWeaverCore
@testable import RuneWeaverTools
import Testing

private struct MockMediaTransport: MediaArrTransport {
    let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}

private func makeHTTPResponse(url: URL?, statusCode: Int = 200) -> HTTPURLResponse {
    let targetURL = url ?? URL(fileURLWithPath: "/")
    return HTTPURLResponse(
        url: targetURL,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    ) ?? HTTPURLResponse()
}

/// Serialized plus credential gate: the media API key resolves via process-global
/// `setenv`, which races when tests run in parallel, so stub-credential tests
/// serialize and scope the key through the shared gate.
@Suite("MediaArrTool Tests", .serialized)
struct MediaArrToolTests {
    @Test
    func `Tool metadata and properties match expectations`() {
        let tool = MediaArrTool(mediaConfig: MediaConfig())
        #expect(tool.name == "media.arr")
        #expect(tool.permissionLevel == .requiresApproval)
        #expect(tool.description.contains("Sonarr"))
        #expect(tool.description.contains("Radarr"))
    }

    @Test
    func `Invalid JSON arguments return failure`() async throws {
        let tool = MediaArrTool(mediaConfig: MediaConfig())
        let input = ToolInput(toolName: "media.arr", argumentsJSON: "{ not valid json }", callID: "call-1")
        let context = ToolContext(conversationID: UUID())
        let output = try await tool.execute(input: input, context: context)
        #expect(output.isError == true)
        #expect(output.content.contains("Invalid media.arr arguments"))
        #expect(output.callID == "call-1")
    }

    @Test
    func `Unconfigured service returns descriptive guidance`() async throws {
        let mediaConfig = MediaConfig(
            sonarr: SonarrConfig(enabled: true, url: nil)
        )
        let tool = MediaArrTool(mediaConfig: mediaConfig)
        let input = ToolInput(
            toolName: "media.arr",
            argumentsJSON: #"{"service":"sonarr","action":"status"}"#,
            callID: "call-2"
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError == true)
        #expect(output.content.contains("Sonarr URL is not configured"))
    }

    @Test
    func `Disabled service returns descriptive error`() async throws {
        let mediaConfig = MediaConfig(
            sonarr: SonarrConfig(enabled: false, url: "http://localhost:8989")
        )
        let tool = MediaArrTool(mediaConfig: mediaConfig)
        let input = ToolInput(
            toolName: "media.arr",
            argumentsJSON: #"{"service":"sonarr","action":"status"}"#,
            callID: "call-3"
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError == true)
        #expect(output.content.contains("Sonarr integration is disabled"))
    }

    @Test
    func `Missing API key guides user to environment or keychain`() async throws {
        unsetenv("TEST_MISSING_KEY")
        let mediaConfig = MediaConfig(
            sonarr: SonarrConfig(enabled: true, url: "http://localhost:8989", apiKeyEnv: "TEST_MISSING_KEY")
        )
        let tool = MediaArrTool(mediaConfig: mediaConfig)
        let input = ToolInput(
            toolName: "media.arr",
            argumentsJSON: #"{"service":"sonarr","action":"status"}"#,
            callID: "call-4"
        )
        let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
        #expect(output.isError == true)
        #expect(output.content.contains("Missing API key for Sonarr"))
        #expect(output.content.contains("TEST_MISSING_KEY"))
        #expect(output.content.contains("com.runeweaver.secrets"))
    }

    @Test
    func `Status action reports version and online health`() async throws {
        let mediaConfig = MediaConfig(
            sonarr: SonarrConfig(enabled: true, url: "http://localhost:8989", apiKeyEnv: "TEST_MEDIA_KEY")
        )

        let mockTransport = MockMediaTransport { req in
            #expect(req.value(forHTTPHeaderField: "X-Api-Key") == "secret-test-token")
            #expect(req.url?.path == "/api/v3/system/status")
            let json = #"{"appName":"Sonarr","version":"4.0.5.1710"}"#
            return (Data(json.utf8), makeHTTPResponse(url: req.url))
        }

        let tool = MediaArrTool(mediaConfig: mediaConfig, transport: mockTransport)
        let input = ToolInput(
            toolName: "media.arr",
            argumentsJSON: #"{"service":"sonarr","action":"status"}"#,
            callID: "call-status"
        )
        try await ToolsTestSupport.withTestCredential(envVar: "TEST_MEDIA_KEY", value: "secret-test-token") {
            let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
            #expect(output.isError == false)
            #expect(output.content == "Sonarr is online and reachable. Version: 4.0.5.1710.")
        }
    }

    @Test
    func `Queue action reports active downloads`() async throws {
        let mediaConfig = MediaConfig(
            radarr: RadarrConfig(enabled: true, url: "http://localhost:7878", apiKeyEnv: "TEST_MEDIA_KEY")
        )

        let mockTransport = MockMediaTransport { req in
            #expect(req.url?.path == "/api/v3/queue")
            let json = """
            {
              "totalRecords": 1,
              "records": [
                {
                  "id": 10,
                  "title": "Gladiator II 2024",
                  "status": "downloading",
                  "timeleft": "12m 30s"
                }
              ]
            }
            """
            return (Data(json.utf8), makeHTTPResponse(url: req.url))
        }

        let tool = MediaArrTool(mediaConfig: mediaConfig, transport: mockTransport)
        let input = ToolInput(
            toolName: "media.arr",
            argumentsJSON: #"{"service":"radarr","action":"queue"}"#,
            callID: "call-queue"
        )
        try await ToolsTestSupport.withTestCredential(envVar: "TEST_MEDIA_KEY", value: "secret-test-token") {
            let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
            #expect(output.isError == false)
            #expect(output.content.contains("Radarr Download Queue (1 item(s)):"))
            #expect(output.content.contains("Gladiator II 2024 [downloading] ETA: 12m 30s"))
        }
    }

    @Test
    func `Search action formats compact results and strips bloated metadata`() async throws {
        let mediaConfig = MediaConfig(
            sonarr: SonarrConfig(enabled: true, url: "http://localhost:8989", apiKeyEnv: "TEST_MEDIA_KEY")
        )

        let mockTransport = MockMediaTransport { req in
            #expect(req.url?.path == "/api/v3/series/lookup")
            #expect(req.url?.query?.contains("term=Shogun") == true)
            let json = """
            [
              {
                "title": "Shogun",
                "year": 2024,
                "tvdbId": 359124,
                "overview": "Set in feudal Japan in the year 1600 at the dawn of a century-defining civil war.",
                "id": 0
              }
            ]
            """
            return (Data(json.utf8), makeHTTPResponse(url: req.url))
        }

        let tool = MediaArrTool(mediaConfig: mediaConfig, transport: mockTransport)
        let input = ToolInput(
            toolName: "media.arr",
            argumentsJSON: #"{"service":"sonarr","action":"search","query":"Shogun"}"#,
            callID: "call-search"
        )
        try await ToolsTestSupport.withTestCredential(envVar: "TEST_MEDIA_KEY", value: "secret-test-token") {
            let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
            #expect(output.isError == false)
            #expect(output.content.contains("Found 1 result(s) for 'Shogun':"))
            #expect(output.content.contains("1. Shogun (2024) [TVDB ID: 359124]"))
            #expect(output.content.contains("Overview: Set in feudal Japan"))
        }
    }

    @Test
    func `Dry run returns preview without making mutation request`() async throws {
        let mediaConfig = MediaConfig(
            radarr: RadarrConfig(enabled: true, url: "http://localhost:7878", apiKeyEnv: "TEST_MEDIA_KEY")
        )

        let mockTransport = MockMediaTransport { _ in
            Issue.record("Transport must not be invoked during dry run")
            throw URLError(.badURL)
        }

        let tool = MediaArrTool(mediaConfig: mediaConfig, transport: mockTransport)
        let input = ToolInput(
            toolName: "media.arr",
            argumentsJSON: #"{"service":"radarr","action":"add","query":"Inception"}"#,
            callID: "call-dry"
        )
        let context = ToolContext(conversationID: UUID(), dryRun: true)
        try await ToolsTestSupport.withTestCredential(envVar: "TEST_MEDIA_KEY", value: "secret-test-token") {
            let output = try await tool.execute(input: input, context: context)
            #expect(output.isError == false)
            #expect(output.content.contains("[DRY RUN] Would search and add 'Inception' to Radarr."))
        }
    }

    @Test
    func `Add action resolves root folder and quality profile then posts`() async throws {
        let mediaConfig = MediaConfig(
            sonarr: SonarrConfig(
                enabled: true,
                url: "http://localhost:8989",
                apiKeyEnv: "TEST_MEDIA_KEY",
                defaultQualityProfile: "HD-1080p",
                defaultRootFolder: "/data/media/tv"
            )
        )

        let mockTransport = MockMediaTransport { req in
            let path = req.url?.path ?? ""
            if path == "/api/v3/series/lookup" {
                let json = """
                [
                  {
                    "title": "Fallout",
                    "year": 2024,
                    "tvdbId": 385596,
                    "id": 0,
                    "titleSlug": "fallout"
                  }
                ]
                """
                return (Data(json.utf8), makeHTTPResponse(url: req.url))
            } else if path == "/api/v3/qualityprofile" {
                let json = """
                [
                  { "id": 1, "name": "Any" },
                  { "id": 4, "name": "HD-1080p" }
                ]
                """
                return (Data(json.utf8), makeHTTPResponse(url: req.url))
            } else if path == "/api/v3/series" {
                #expect(req.httpMethod == "POST")
                let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
                #expect(body.contains("\"qualityProfileId\":4"))
                #expect(body.contains("\"rootFolderPath\":\"\\/data\\/media\\/tv\""))
                #expect(body.contains("\"searchForMissingEpisodes\":true"))
                let respJson = #"{"id":42,"title":"Fallout"}"#
                return (Data(respJson.utf8), makeHTTPResponse(url: req.url, statusCode: 201))
            } else {
                return (Data(), makeHTTPResponse(url: req.url, statusCode: 404))
            }
        }

        let tool = MediaArrTool(mediaConfig: mediaConfig, transport: mockTransport)
        let input = ToolInput(
            toolName: "media.arr",
            argumentsJSON: #"{"service":"sonarr","action":"add","query":"Fallout"}"#,
            callID: "call-add"
        )
        try await ToolsTestSupport.withTestCredential(envVar: "TEST_MEDIA_KEY", value: "secret-test-token") {
            let output = try await tool.execute(input: input, context: ToolContext(conversationID: UUID()))
            #expect(output.isError == false)
            #expect(output.content.contains("Successfully added 'Fallout' to Sonarr!"))
            #expect(output.content.contains("Quality Profile: HD-1080p"))
            #expect(output.content.contains("Root Folder: /data/media/tv"))
            #expect(output.content.contains("Automatic search triggered."))
        }
    }
}
