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

    var summary: String {
        switch self {
        case .nativeMacShell:
            return "A minimal SwiftUI Mac app that is fast to iterate on."
        case .kishAgentBridge:
            return "The app talks to the Mac mini agent through the native HTTP bridge."
        case .persistentConversations:
            return "Threads survive relaunch and keep the same agent session."
        case .retryFailedMessage:
            return "Failed messages can be sent again without losing thread context."
        case .offlineQueue:
            return "Disconnected sends are saved locally and retried after reconnect."
        case .sharedConversationSync:
            return "Mac and iOS load the same backend conversation history."
        case .deleteReconciliation:
            return "Deleted conversations stay deleted across devices."
        case .connectionRecovery:
            return "Deferred: the current offline queue is enough until live calls and long-running runs need stronger recovery."
        case .streamingEvents:
            return "Show text, steps, and tool activity while the agent works."
        case .approvalCards:
            return "Render agent questions as clear answer controls in the composer area."
        case .decisionInbox:
            return "Deferred: current question cards work; build the inbox after richer approval types exist."
        case .toolInventory:
            return "Show the practical tools and engines the agent can use right now."
        case .pushToTalk:
            return "Dictation fills the composer without sending automatically."
        case .iOSSharedShell:
            return "The iPhone app uses the same KishOS core and conversation model."
        case .nativeAttachments:
            return "Upload files and photos to the agent with previews and backend ids."
        case .explicitSnapshot:
            return "Validated through the native attachment path: capture or choose an image, upload it, then send the attachment id with the chat turn."
        case .snapshotReview:
            return "Mostly UI: make the image review, retake, and send flow feel intentional before camera-first use."
        case .liveCallMode:
            return "Hands-free call surface with conversation continuity, interruption controls, and a Live Activity override while a call is active."
        case .wakePhrase:
            return "Glassbridge-style local Speech wake phrase that pauses while chat or call mode owns the mic."
        case .audioRouteAwareness:
            return "Detect Bluetooth, AirPods, and glasses-like audio routes."
        case .audioRoutePicker:
            return "Prefer headset/glasses routes when available, then fall back cleanly to the iPhone route."
        case .spokenReplies:
            return "Use call-only spoken output, with stop/barge-in and no surprise read-aloud in normal chat."
        case .glassesWalkMode:
            return "Use glasses or headset audio as a walkie-talkie interface to KishOS."
        case .liveRunTimeline:
            return "Show the current task, latest step, elapsed time, and blocked state."
        case .interruptSteering:
            return "Let you steer or stop a running agent without waiting for the final answer."
        case .statusNotifications:
            return "Use Live Activity and notifications to surface recent sessions, review-needed work, and completed runs."
        case .sessionRecovery:
            return "Reopen the app and recover the final state of an in-flight run."
        case .capabilityMap:
            return "Summarize what the agent can do, what needs setup, and what is broken."
        case .dailyBrief:
            return "Generate a short daily brief from active threads and recent work."
        case .memoryPins:
            return "Pin, update, or forget durable facts and preferences."
        case .routines:
            return "Turn cron/background work into simple personal routines."
        }
    }

    var tags: [String] {
        switch self {
        case .nativeMacShell:
            return ["Mac", "UI"]
        case .kishAgentBridge:
            return ["Backend", "HTTP"]
        case .persistentConversations:
            return ["Chat", "Storage"]
        case .retryFailedMessage:
            return ["Recovery", "Chat"]
        case .offlineQueue:
            return ["Offline", "Queue"]
        case .sharedConversationSync:
            return ["Sync", "Mac+iOS"]
        case .deleteReconciliation:
            return ["Sync", "Safety"]
        case .connectionRecovery:
            return ["Deferred", "Recovery"]
        case .streamingEvents:
            return ["Streaming", "Tools"]
        case .approvalCards:
            return ["Questions", "Control"]
        case .decisionInbox:
            return ["Deferred", "Decisions"]
        case .toolInventory:
            return ["Tools", "Status"]
        case .pushToTalk:
            return ["Voice", "Composer"]
        case .iOSSharedShell:
            return ["iOS", "Shared Core"]
        case .nativeAttachments:
            return ["Files", "Photos"]
        case .explicitSnapshot:
            return ["Validated", "Vision"]
        case .snapshotReview:
            return ["UI", "Privacy"]
        case .liveCallMode:
            return ["M6", "Live Activity"]
        case .wakePhrase:
            return ["Glassbridge", "Wake"]
        case .audioRouteAwareness:
            return ["Audio", "Routes"]
        case .audioRoutePicker:
            return ["Audio", "Glassbridge"]
        case .spokenReplies:
            return ["Voice", "Output"]
        case .glassesWalkMode:
            return ["Glasses", "Walk mode"]
        case .liveRunTimeline:
            return ["Runs", "Visibility"]
        case .interruptSteering:
            return ["Runs", "Steering"]
        case .statusNotifications:
            return ["Live Activity", "Runs"]
        case .sessionRecovery:
            return ["Recovery", "Runs"]
        case .capabilityMap:
            return ["Tools", "Trust"]
        case .dailyBrief:
            return ["Memory", "Brief"]
        case .memoryPins:
            return ["Memory", "Control"]
        case .routines:
            return ["Routines", "Cron"]
        }
    }
}

enum KishOSCapabilityState: String, Codable {
    case available = "Available"
    case inProgress = "In progress"
    case planned = "Planned"
    case deferred = "Deferred"
    case off = "Off"
}

struct KishOSCapability: Identifiable, Codable, Equatable {
    let id: KishOSFeature
    var state: KishOSCapabilityState

    var title: String { id.title }
    var summary: String { id.summary }
    var tags: [String] { id.tags }
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
             .explicitSnapshot,
             .audioRouteAwareness,
             .liveCallMode,
             .wakePhrase,
             .audioRoutePicker,
             .spokenReplies:
            state = .available
        case .connectionRecovery,
             .decisionInbox:
            state = .deferred
        case .snapshotReview,
             .statusNotifications,
             .sessionRecovery:
            state = .inProgress
        case .glassesWalkMode,
             .liveRunTimeline,
             .interruptSteering,
             .capabilityMap,
             .dailyBrief,
             .memoryPins,
             .routines:
            state = .planned
        }
        return KishOSCapability(id: feature, state: state)
    }
}
