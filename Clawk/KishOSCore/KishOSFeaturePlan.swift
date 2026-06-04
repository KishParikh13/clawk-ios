import Foundation

enum KishOSMilestone: String, CaseIterable, Identifiable, Codable {
    case textChat = "M0"
    case streaming = "M1"
    case approvals = "M2"
    case macVoice = "M3"
    case iOSParity = "M4"
    case glassesAudio = "M5"
    case glassesVision = "M6"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textChat:
            return "Text chat"
        case .streaming:
            return "Streaming"
        case .approvals:
            return "Approvals"
        case .macVoice:
            return "Mac voice"
        case .iOSParity:
            return "iOS"
        case .glassesAudio:
            return "Glasses audio"
        case .glassesVision:
            return "Vision"
        }
    }

    var goal: String {
        switch self {
        case .textChat:
            return "Reliable persistent chat with kish-agent."
        case .streaming:
            return "Live text, events, and run visibility."
        case .approvals:
            return "Approve or deny real agent actions."
        case .macVoice:
            return "Dictation that fills the composer."
        case .iOSParity:
            return "Same minimal experience on iPhone."
        case .glassesAudio:
            return "Use glasses as the audio route."
        case .glassesVision:
            return "Explicit first-person snapshots."
        }
    }

    var userCheckpoint: [String] {
        switch self {
        case .textChat:
            return [
                "Create two conversations.",
                "Ask follow-ups in each thread.",
                "Quit and reopen the app.",
                "Confirm each thread keeps context."
            ]
        case .streaming:
            return [
                "Send a slow prompt.",
                "Confirm partial output appears.",
                "Confirm events explain what the agent is doing."
            ]
        case .approvals:
            return [
                "Trigger one question or approval.",
                "Answer from the app.",
                "Confirm the agent continues with the exact answer."
            ]
        case .macVoice:
            return [
                "Tap the mic to start dictation.",
                "Tap again to stop.",
                "Confirm the transcript lands in the composer without sending."
            ]
        case .iOSParity:
            return [
                "Connect from iPhone over Tailscale.",
                "Create and continue a thread.",
                "Confirm voice works on iOS."
            ]
        case .glassesAudio:
            return [
                "Pair glasses.",
                "Confirm mic input route.",
                "Confirm glasses audio route."
            ]
        case .glassesVision:
            return [
                "Capture one explicit snapshot.",
                "Ask about the image.",
                "Confirm nothing sends without action."
            ]
        }
    }
}

enum KishOSFeature: String, CaseIterable, Identifiable, Codable {
    case persistentConversations
    case retryFailedMessage
    case connectionRecovery
    case streamingEvents
    case approvalCards
    case toolInventory
    case pushToTalk
    case iOSSharedShell
    case audioRoutePicker
    case explicitSnapshot

    var id: String { rawValue }

    var milestone: KishOSMilestone {
        switch self {
        case .persistentConversations, .retryFailedMessage, .connectionRecovery:
            return .textChat
        case .streamingEvents:
            return .streaming
        case .approvalCards, .toolInventory:
            return .approvals
        case .pushToTalk:
            return .macVoice
        case .iOSSharedShell:
            return .iOSParity
        case .audioRoutePicker:
            return .glassesAudio
        case .explicitSnapshot:
            return .glassesVision
        }
    }

    var title: String {
        switch self {
        case .persistentConversations:
            return "Persistent conversations"
        case .retryFailedMessage:
            return "Retry failed messages"
        case .connectionRecovery:
            return "Connection recovery"
        case .streamingEvents:
            return "Streaming events"
        case .approvalCards:
            return "Questions and approvals"
        case .toolInventory:
            return "Tool inventory"
        case .pushToTalk:
            return "Dictation"
        case .iOSSharedShell:
            return "iOS shared shell"
        case .audioRoutePicker:
            return "Audio route picker"
        case .explicitSnapshot:
            return "Explicit snapshot"
        }
    }
}

enum KishOSCapabilityState: String, Codable {
    case available = "Available"
    case inProgress = "In progress"
    case planned = "Planned"
    case off = "Off"
}

struct KishOSCapability: Identifiable, Codable, Equatable {
    let id: KishOSFeature
    var state: KishOSCapabilityState

    var title: String { id.title }
    var milestone: KishOSMilestone { id.milestone }
}

enum KishOSFactoryPlan {
    static let capabilities: [KishOSCapability] = KishOSFeature.allCases.map { feature in
        let state: KishOSCapabilityState
        switch feature {
        case .persistentConversations, .retryFailedMessage, .streamingEvents, .approvalCards, .toolInventory, .pushToTalk, .iOSSharedShell:
            state = .available
        case .connectionRecovery:
            state = .inProgress
        case .audioRoutePicker, .explicitSnapshot:
            state = .planned
        }
        return KishOSCapability(id: feature, state: state)
    }
}
