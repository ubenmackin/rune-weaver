// Rune Weaver Tests — Tool hasConfig contract tests.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing

@Suite("Tool hasConfig Contract")
struct ToolRouteTests {
    @Test
    func `Bash tool reports settings support through buildToolInfo`() {
        let tool = BashTool(bashConfig: BashConfig(), filesConfig: FilesConfig())
        let info = buildToolInfo(for: tool, isEnabled: true, recordByPluginID: [:])
        #expect(info.name == "bash.exec")
        #expect(info.hasConfig == true)
        #expect(info.isEnabled == true)
    }

    @Test
    func `Files tools report settings support through buildToolInfo`() throws {
        let tools = FilesTools.makeTools(filesConfig: FilesConfig())
        // The Files category exposes only the files.write write review mode;
        // Files & Access (allow roots, deny patterns, approval on deny) lives
        // under Security, so every other `files.*` tool reports no Configure
        // action.
        for tool in tools {
            let listed = buildToolInfo(for: tool, isEnabled: true, recordByPluginID: [:])
            #expect(listed.hasConfig == (tool.name == "files.write"))
            #expect(listed.isEnabled == true)
        }
        let write = tools.first { $0.name == "files.write" }
        let writeTool = try #require(write)
        let writeInfo = buildToolInfo(for: writeTool, isEnabled: true, recordByPluginID: [:])
        #expect(writeInfo.name == "files.write")
        #expect(writeInfo.hasConfig == true)
        #expect(writeInfo.isEnabled == true)

        let read = tools.first { $0.name == "files.read" }
        let readTool = try #require(read)
        let readInfo = buildToolInfo(for: readTool, isEnabled: true, recordByPluginID: [:])
        #expect(readInfo.name == "files.read")
        #expect(readInfo.hasConfig == false)
        #expect(readInfo.isEnabled == true)
    }

    @Test
    func `Unconfigurable tool reports no settings support`() {
        let tool = UnconfigurableStubTool()
        let info = buildToolInfo(for: tool, isEnabled: true, recordByPluginID: [:])
        #expect(info.name == "custom.widget")
        #expect(info.hasConfig == false)
        #expect(info.isEnabled == true)
    }

    @Test
    func `Bash tool stays present when disabled`() async {
        // Disabled tools stay registered and visible in GET /tools instead
        // of shape-shifting with config; the persisted toggle is the sole
        // authority for enablement.
        let bus = ToolBus()
        let tool = BashTool(bashConfig: BashConfig(), filesConfig: FilesConfig())
        await bus.register(tool: tool, isEnabled: false)
        #expect(await bus.tool(named: "bash.exec") != nil)
        #expect(await bus.isToolEnabled(named: "bash.exec") == false)

        // The listing row keeps the settings flag even while disabled so
        // the dashboard Configure action stays available.
        let info = buildToolInfo(for: tool, isEnabled: false, recordByPluginID: [:])
        #expect(info.hasConfig == true)
        #expect(info.isEnabled == false)
    }
}

private struct UnconfigurableStubTool: Tool, Sendable {
    let name = "custom.widget"
    let description = "Unconfigurable stub."
    let inputSchema = JSONSchema(rawValue: #"{"type":"object"}"#)
    let permissionLevel = PermissionLevel.readOnly

    func execute(input: ToolInput, context _: ToolContext) async throws -> ToolOutput {
        .success("widget-ok", callID: input.callID)
    }
}
