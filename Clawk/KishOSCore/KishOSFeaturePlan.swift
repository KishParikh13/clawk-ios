import Foundation

enum KishOSMilestone: String, CaseIterable, Identifiable, Codable {
    case foundation = "M0"
    case streaming = "M1"
    case decisions = "M2"
    case voice = "M3"
    case iOSParity = "M4"
    case attachments = "M5"
    case liveCall = "M6"
    case glassesAudio = "M7"
    case supervision = "M8"
    case memoryRoutines = "M9"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .foundation:
            return "Foundation"
        case .streaming:
            return "Streaming"
        case .decisions:
            return "Decisions"
        case .voice:
            return "Voice"
        case .iOSParity:
            return "iOS"
        case .attachments:
            return "Attachments"
        case .liveCall:
            return "Live call"
        case .glassesAudio:
            return "Glasses audio"
        case .supervision:
            return "Supervision"
        case .memoryRoutines:
            return "Memory"
        }
    }

    var goal: String {
        switch self {
        case .foundation:
            return "Native Mac chat backed by kish-agent."
        case .streaming:
            return "Live text, events, and run visibility."
        case .decisions:
            return "Answer questions and approve work."
        case .voice:
            return "Dictation that fills the composer."
        case .iOSParity:
            return "Same minimal experience on iPhone."
        case .attachments:
            return "Send files, photos, and snapshots."
        case .liveCall:
            return "Hands-free agent conversation."
        case .glassesAudio:
            return "Use glasses as the audio route."
        case .supervision:
            return "Supervise long-running agent work."
        case .memoryRoutines:
            return "Remember, brief, and initiate."
        }
    }

    var userCheckpoint: [String] {
        switch self {
        case .foundation:
            return [
                "Create and continue conversations.",
                "Quit and reopen the app.",
                "Confirm the Mac mini connection recovers.",
                "Confirm offline sends save locally and requeue."
            ]
        case .streaming:
            return [
                "Send a slow prompt.",
                "Confirm partial output appears.",
                "Open Steps while streaming.",
                "Confirm duplicate final/tool noise is filtered."
            ]
        case .decisions:
            return [
                "Trigger one multi-choice question.",
                "Answer with a preset.",
                "Answer with Other.",
                "Cancel or deny and confirm the agent sees it."
            ]
        case .voice:
            return [
                "Tap the mic to start dictation.",
                "Tap again to stop.",
                "Confirm the live transcript appears.",
                "Confirm the transcript lands in the composer without sending."
            ]
        case .iOSParity:
            return [
                "Connect from iPhone over Tailscale.",
                "Create and continue a thread.",
                "Confirm Mac and iOS share conversations.",
                "Delete on one device and confirm it stays deleted."
            ]
        case .attachments:
            return [
                "Attach a Mac file.",
                "Choose an iOS photo.",
                "Confirm image previews render.",
                "Ask a question about the attachment."
            ]
        case .liveCall:
            return [
                "Start a call in an existing thread.",
                "Speak, pause, and let silence finalize.",
                "Confirm the agent response streams and is spoken.",
                "Interrupt or stop cleanly."
            ]
        case .glassesAudio:
            return [
                "Pair glasses.",
                "Confirm the app reports the active input and output routes.",
                "Capture dictation through the selected route.",
                "Confirm the transcript lands in the composer before sending."
            ]
        case .supervision:
            return [
                "Start a longer agent task.",
                "Leave and return to the app.",
                "Confirm the current run state is visible.",
                "Answer a pending decision from the inbox."
            ]
        case .memoryRoutines:
            return [
                "Ask for a daily brief.",
                "Pin or forget one memory.",
                "Create one routine.",
                "Confirm routine output lands in a normal thread."
            ]
        }
    }
}

enum KishOSFeature: String, CaseIterable, Identifiable, Codable {
    case nativeMacShell
    case kishAgentBridge
    case persistentConversations
    case retryFailedMessage
    case offlineQueue
    case sharedConversationSync
    case deleteReconciliation
    case connectionRecovery
    case streamingEvents
    case approvalCards
    case decisionInbox
    case toolInventory
    case pushToTalk
    case iOSSharedShell
    case nativeAttachments
    case explicitSnapshot
    case snapshotReview
    case liveCallMode
    case wakePhrase
    case audioRouteAwareness
    case audioRoutePicker
    case spokenReplies
    case glassesWalkMode
    case liveRunTimeline
    case interruptSteering
    case statusNotifications
    case sessionRecovery
    case capabilityMap
    case dailyBrief
    case memoryPins
    case routines

    var id: String { rawValue }

    var milestone: KishOSMilestone {
        switch self {
        case .nativeMacShell, .kishAgentBridge, .persistentConversations, .retryFailedMessage, .offlineQueue, .connectionRecovery:
            return .foundation
        case .streamingEvents:
            return .streaming
        case .approvalCards, .decisionInbox, .toolInventory:
            return .decisions
        case .pushToTalk:
            return .voice
        case .iOSSharedShell, .sharedConversationSync, .deleteReconciliation:
            return .iOSParity
        case .nativeAttachments, .explicitSnapshot, .snapshotReview:
            return .attachments
        case .liveCallMode, .spokenReplies, .wakePhrase:
            return .liveCall
        case .audioRouteAwareness, .audioRoutePicker, .glassesWalkMode:
            return .glassesAudio
        case .liveRunTimeline, .interruptSteering, .statusNotifications, .sessionRecovery, .capabilityMap:
            return .supervision
        case .dailyBrief, .memoryPins, .routines:
            return .memoryRoutines
        }
    }

    var title: String {
        switch self {
        case .nativeMacShell:
            return "Native Mac shell"
        case .kishAgentBridge:
            return "kish-agent bridge"
        case .persistentConversations:
            return "Persistent conversations"
        case .retryFailedMessage:
            return "Retry failed messages"
        case .offlineQueue:
            return "Offline queue"
        case .sharedConversationSync:
            return "Shared conversations"
        case .deleteReconciliation:
            return "Delete reconciliation"
        case .connectionRecovery:
            return "Connection recovery"
        case .streamingEvents:
            return "Streaming events"
        case .approvalCards:
            return "Questions and approvals"
        case .decisionInbox:
            return "Decision inbox"
        case .toolInventory:
            return "Tool inventory"
        case .pushToTalk:
            return "Dictation"
        case .iOSSharedShell:
            return "iOS shared shell"
        case .nativeAttachments:
            return "Native attachments"
        case .explicitSnapshot:
            return "Snapshot ask"
        case .snapshotReview:
            return "Snapshot review"
        case .liveCallMode:
            return "Live call mode"
        case .wakePhrase:
            return "Wake phrase"
        case .audioRouteAwareness:
            return "Audio route awareness"
        case .audioRoutePicker:
            return "Audio route picker"
        case .spokenReplies:
            return "Spoken replies"
        case .glassesWalkMode:
            return "Walkie-talkie mode"
        case .liveRunTimeline:
            return "Live run timeline"
        case .interruptSteering:
            return "Interrupt steering"
        case .statusNotifications:
            return "Status notifications"
        case .sessionRecovery:
            return "Session recovery"
        case .capabilityMap:
            return "Capability map"
        case .dailyBrief:
            return "Daily brief"
        case .memoryPins:
            return "Memory pins"
        case .routines:
            return "Routines"
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
        case .nativeMacShell,
             .kishAgentBridge,
             .persistentConversations,
             .retryFailedMessage,
             .offlineQueue,
             .sharedConversationSync,
             .deleteReconciliation,
             .streamingEvents,
             .approvalCards,
             .toolInventory,
             .pushToTalk,
             .iOSSharedShell,
             .nativeAttachments,
             .audioRouteAwareness:
            state = .available
        case .connectionRecovery,
             .decisionInbox,
             .liveCallMode,
             .wakePhrase,
             .audioRoutePicker,
             .spokenReplies,
             .explicitSnapshot,
             .snapshotReview,
             .sessionRecovery:
            state = .inProgress
        case .glassesWalkMode,
             .liveRunTimeline,
             .interruptSteering,
             .statusNotifications,
             .capabilityMap,
             .dailyBrief,
             .memoryPins,
             .routines:
            state = .planned
        }
        return KishOSCapability(id: feature, state: state)
    }
}
