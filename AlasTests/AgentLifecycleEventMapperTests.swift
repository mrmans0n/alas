import Testing
@testable import Alas

struct AgentLifecycleEventMapperTests {
    @Test func claudeStyleEvents_mapToLifecycleEvents() {
        #expect(AgentLifecycleEventMapper.map("SessionStart") == .attached)
        #expect(AgentLifecycleEventMapper.map("SessionEnd") == .detached)
        #expect(AgentLifecycleEventMapper.map("PermissionRequest") == .permissionRequest)
        #expect(AgentLifecycleEventMapper.map("PreToolUse") == .permissionRequest)
    }

    @Test func codexStyleEvents_mapToLifecycleEvents() {
        #expect(AgentLifecycleEventMapper.map("exec_approval_request") == .permissionRequest)
        #expect(AgentLifecycleEventMapper.map("apply_patch_approval_request") == .permissionRequest)
        #expect(AgentLifecycleEventMapper.map("request_user_input") == .permissionRequest)
        #expect(AgentLifecycleEventMapper.map("agent-turn-complete") == .idle)
    }

    @Test func cursorAndSupersetStyleEvents_mapToLifecycleEvents() {
        #expect(AgentLifecycleEventMapper.map("userPromptSubmitted") == .busy)
        #expect(AgentLifecycleEventMapper.map("postToolUse") == .busy)
        #expect(AgentLifecycleEventMapper.map("task_started") == .busy)
        #expect(AgentLifecycleEventMapper.map("task_complete") == .idle)
    }

    @Test func normalizedEvents_mapToThemselves() {
        #expect(AgentLifecycleEventMapper.map("busy") == .busy)
        #expect(AgentLifecycleEventMapper.map("awaiting_input") == .awaitingInput)
        #expect(AgentLifecycleEventMapper.map("permission_request") == .permissionRequest)
        #expect(AgentLifecycleEventMapper.map("idle") == .idle)
        #expect(AgentLifecycleEventMapper.map("attached") == .attached)
        #expect(AgentLifecycleEventMapper.map("detached") == .detached)
    }

    @Test func unknownEvent_returnsNil() {
        #expect(AgentLifecycleEventMapper.map("future_event") == nil)
    }
}
