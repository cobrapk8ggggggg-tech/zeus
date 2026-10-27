import Foundation

@MainActor enum ZeusCloudPresentation {
    static func begin(_ vm: AIChatViewModel) -> ChatMessage {
        if let existing = vm.messages.last, existing.role == .assistant, existing.isAwaitingModelResponse, existing.blocks.isEmpty, existing.error == nil { return existing }
        let message = ChatMessage(role: .assistant, content: "", blocks: [])
        message.isAwaitingModelResponse = true
        vm.messages.append(message); vm.publishUnlessTransitioning()
        return message
    }
    @discardableResult static func append(_ delta: String, vm: AIChatViewModel, message: ChatMessage, block: AssistantBlock?) -> AssistantBlock {
        let current = block ?? AssistantBlock(kind: .text, content: "")
        if block == nil { message.blocks.append(current) }
        message.isAwaitingModelResponse = false
        if let msgIdx = vm.messages.firstIndex(where: { $0.id == message.id }), let blockIdx = message.blocks.firstIndex(where: { $0.id == current.id }) {
            vm.setStreamingTextBlockContent(msgIdx: msgIdx, blockIdx: blockIdx, text: current.content + delta, parsedMarkdown: nil, cacheAttributedString: true, requestScroll: true)
            vm.publishUnlessTransitioning()
        }
        return current
    }
}
