import Foundation

enum MemoryState: String, Codable, Equatable {
    case active
    case pinned
    case archived
    case forgotten
}

enum MemoryReviewFlag: String, Codable, Equatable {
    case needsReview
    case sensitive
    case conflicted
}

enum ContextSource: String, Codable, Equatable {
    case conversation
    case routineRun
    case memory
    case projectContext
    case screenContextSummary
}

enum MemoryProvenanceSource: String, Codable, Equatable {
    case conversation
    case routineRun
    case dailyBrief
    case projectContext
    case screenContextSummary
    case manualEdit
}

enum RoutineState: String, Codable, Equatable {
    case proposed
    case enabled
    case paused
    case disabled
}

enum RoutineTemplate: String, Codable, Equatable {
    case dailyBrief
    case ideaGeneration
    case projectMaintenance
    case prioritization
}

enum ActionClass: String, Codable, Equatable {
    case readContext
    case summarize
    case draftArtifact
    case createReviewCard
    case runLightChecks
    case startCoding
    case sendExternalMessage
    case deleteOrDestructive
    case mergeDeployPublish
}

enum OutputMode: String, Codable, Equatable {
    case newConversationPerRun
}

enum NotificationBehavior: String, Codable, Equatable {
    case dailyBriefDigest
    case autonomyInbox
    case urgentActiveNotification
    case silent
}

enum RuntimeClass: String, Codable, Equatable {
    case short
    case medium
    case long
}

enum CostClass: String, Codable, Equatable {
    case low
    case medium
    case high
}

enum TriggerType: String, Codable, Equatable {
    case manual
    case scheduled
    case event
}

enum RoutineRunState: String, Codable, Equatable {
    case queued
    case running
    case done
    case failed
    case needsReview
    case needsApproval
}

enum ReviewCardState: String, Codable, Equatable {
    case open
    case approved
    case rejected
    case resolved
    case dismissed
}

enum ReviewCardKind: String, Codable, Equatable {
    case approveRoutine
    case resolveMemoryConflict
    case reviewSensitiveMemory
    case chooseProjectPriority
    case approveLongCodingWork
    case recoverFailedRoutine
    case reviewIdea
}

enum RecommendedAction: String, Codable, Equatable {
    case approve
    case reject
    case resolve
    case dismiss
    case openConversation
    case editMemory
    case enableRoutine
    case pauseRoutine
    case retryRun
}

enum PolicyIssueSeverity: String, Codable, Equatable {
    case info
    case warning
    case blocking
}

struct AutonomySummary: Codable, Equatable {
    let latestBrief: DailyBrief?
    let pendingReviewCount: Int
    let urgentReviewCount: Int
    let recentRuns: [RoutineRun]
    let memoryCounts: AutonomyMemoryCounts
    let routineCounts: AutonomyRoutineCounts
    let policyIssues: [PolicyIssue]
    let updatedAt: Date
}

struct AutonomyMemoryCounts: Codable, Equatable {
    let active: Int
    let pinned: Int
    let archived: Int
    let forgotten: Int
    let needsReview: Int
    let sensitive: Int
    let conflicted: Int
}

struct AutonomyRoutineCounts: Codable, Equatable {
    let proposed: Int
    let enabled: Int
    let paused: Int
    let disabled: Int
}

struct PolicyIssue: Codable, Equatable, Identifiable {
    let id: String
    let policyId: String?
    let routineId: String?
    let severity: PolicyIssueSeverity
    let message: String
    let reviewCardId: String?
}

struct KishMemory: Codable, Equatable, Identifiable {
    let id: String
    let state: MemoryState
    let text: String
    let summary: String?
    let reviewFlags: [MemoryReviewFlag]
    let confidence: Double
    let provenance: [MemoryProvenance]
    let createdAt: Date
    let updatedAt: Date
    let lastUsedAt: Date?
    let forgottenAt: Date?
    let tombstoneReason: String?
}

struct MemoryProvenance: Codable, Equatable, Identifiable {
    let id: String
    let sourceType: MemoryProvenanceSource
    let sourceId: String?
    let threadId: String?
    let routineRunId: String?
    let quote: String?
    let observedAt: Date
    let url: String?
}

struct KishRoutine: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let template: RoutineTemplate
    let state: RoutineState
    let policyId: String?
    let trigger: RoutineDefinitionTrigger
    let allowedContextSources: [ContextSource]
    let allowedProjectPaths: [String]
    let allowedActionClasses: [ActionClass]
    let outputMode: OutputMode
    let createdAt: Date
    let updatedAt: Date
}

struct RoutinePolicy: Codable, Equatable, Identifiable {
    let id: String
    let routineId: String
    let allowedActions: [ActionClass]
    let blockedActions: [ActionClass]
    let allowedContextSources: [ContextSource]
    let allowedProjectPaths: [String]
    let maxRuntimeClass: RuntimeClass
    let maxCostClass: CostClass
    let notificationBehavior: NotificationBehavior
    let createdAt: Date
    let approvedAt: Date?
    let updatedAt: Date
}

struct RoutineDefinitionTrigger: Codable, Equatable {
    let type: TriggerType
    let schedule: String?
    let timezone: String?
    let eventName: String?

    init(type: TriggerType, schedule: String? = nil, timezone: String? = nil, eventName: String? = nil) {
        self.type = type
        self.schedule = schedule
        self.timezone = timezone
        self.eventName = eventName
    }
}

struct RoutineRunTrigger: Codable, Equatable {
    let type: TriggerType
    let manualRunId: String?
    let scheduledFor: String?
    let eventName: String?

    init(type: TriggerType, manualRunId: String? = nil, scheduledFor: String? = nil, eventName: String? = nil) {
        self.type = type
        self.manualRunId = manualRunId
        self.scheduledFor = scheduledFor
        self.eventName = eventName
    }
}

struct RoutineRun: Codable, Equatable, Identifiable {
    let id: String
    let routineId: String
    let idempotencyKey: String
    let status: RoutineRunState
    let conversationId: String?
    let threadId: String?
    let startedAt: Date?
    let finishedAt: Date?
    let priorRunIdsUsed: [String]
    let error: RoutineRunError?
    let retryOfRunId: String?
    let reviewCardIdsCreated: [String]
    let createdAt: Date
    let updatedAt: Date
}

struct RoutineRunError: Codable, Equatable {
    let code: String
    let message: String
    let details: [String: JSONValue]?
    let retryable: Bool
}

struct ReviewCard: Codable, Equatable, Identifiable {
    let id: String
    let kind: ReviewCardKind
    let state: ReviewCardState
    let title: String
    let body: String
    let routineId: String?
    let routineRunId: String?
    let memoryId: String?
    let policyId: String?
    let conversationId: String?
    let threadId: String?
    let reviewFlags: [MemoryReviewFlag]
    let recommendedAction: RecommendedAction
    let notificationBehavior: NotificationBehavior
    let createdAt: Date
    let updatedAt: Date
    let resolvedAt: Date?
}

struct DailyBrief: Codable, Equatable, Identifiable {
    let id: String
    let routineRunId: String
    let conversationId: String
    let threadId: String
    let previousBriefRunId: String?
    let summary: String
    let sections: [DailyBriefSection]
    let reviewCardIds: [String]
    let createdAt: Date
}

struct DailyBriefSection: Codable, Equatable {
    let title: String
    let items: [String]
}

struct DailyBriefRunResult: Codable, Equatable {
    let brief: DailyBrief
    let run: RoutineRun
    let reviewCards: [ReviewCard]
    let conversationId: String
    let threadId: String
}

struct RoutineRunResult: Codable, Equatable {
    let run: RoutineRun
    let reviewCards: [ReviewCard]
    let conversationId: String?
    let threadId: String?
    let duplicate: Bool?
}

struct ReviewCardUpdateResult: Codable, Equatable {
    let reviewCard: ReviewCard
    let relatedMemory: KishMemory?
    let relatedRoutine: KishRoutine?
    let relatedPolicy: RoutinePolicy?
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
