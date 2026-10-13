// Rune Weaver Tests — Tool hasConfig contract tests.

import Foundation
import RuneWeaverCore
@testable import RuneWeaverServer
import RuneWeaverTools
import Testing

@Suite("Tool hasConfig Contract")
struct ToolRouteTests {
    @Test
    func `Bash tool keeps only the enablement toggle`() {
        // The shell policy moved to the Access surface, so the row no longer
        // advertises a Configure action that would open a moved editor.
        let tool = BashTool(bashConfig: BashConfig(), filesConfig: FilesConfig())
        let info = buildToolInfo(for: tool, isEnabled: true, recordByPluginID: [:])
        #expect(info.name == "bash.exec")
        #expect(info.hasConfig == false)
        #expect(info.isEnabled == true)
    }

    @Test
    func `Files tools report no Configure action`() throws {
        let tools = FilesTools.makeTools(filesConfig: FilesConfig())
        // The write review policy moved to the Access surface alongside the
        // allow roots and deny patterns, so no files row keeps a Configure
        // action and every toggle stays on the shared enablement path.
        for tool in tools {
            let listed = buildToolInfo(for: tool, isEnabled: true, recordByPluginID: [:])
            #expect(listed.hasConfig == false)
            #expect(listed.isEnabled == true)
        }
        let write = tools.first { $0.name == "files.write" }
        let writeTool = try #require(write)
        let writeInfo = buildToolInfo(for: writeTool, isEnabled: true, recordByPluginID: [:])
        #expect(writeInfo.name == "files.write")
        #expect(writeInfo.hasConfig == false)
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

        // The listing row keeps the enablement toggle while disabled so the
        // dashboard can re-enable it without a restart.
        let info = buildToolInfo(for: tool, isEnabled: false, recordByPluginID: [:])
        #expect(info.hasConfig == false)
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
