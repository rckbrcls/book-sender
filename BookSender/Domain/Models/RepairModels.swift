import Foundation

enum RepairAction: Codable, Equatable, Sendable {
    case rebuildMimetype
    case restoreContainer(packagePath: String)
    case correctMediaType(package: String, href: String, from: String, to: String)
    case normalizePath(from: String, to: String)
    case repairReference(document: String, from: String, to: String)
    case normalizeXML(path: String)
    case removeDanglingSpineItem(package: String, idref: String)

    var identifier: String {
        switch self {
        case .rebuildMimetype: "repair.mimetype"
        case .restoreContainer: "repair.container"
        case .correctMediaType: "repair.media-type"
        case .normalizePath: "repair.path"
        case .repairReference: "repair.reference"
        case .normalizeXML: "repair.xml"
        case .removeDanglingSpineItem: "repair.spine"
        }
    }
}

enum PreparationDecision: String, Codable, Sendable {
    case writeEPUBWorkingCopy
    case deliverImmutablePDFSnapshot
    case blocked
}

struct PreparationPlan: Identifiable, Codable, Sendable {
    let id: UUID
    let originalAuditIdentifier: UUID
    let actions: [RepairAction]
    let expectedPostconditions: Set<FindingCode>
    let limitsVersion: Int
    let decision: PreparationDecision

    init(
        id: UUID,
        originalAuditIdentifier: UUID,
        actions: [RepairAction],
        expectedPostconditions: Set<FindingCode> = [],
        limitsVersion: Int = 1,
        decision: PreparationDecision
    ) {
        self.id = id
        self.originalAuditIdentifier = originalAuditIdentifier
        self.actions = actions
        self.expectedPostconditions = expectedPostconditions
        self.limitsVersion = limitsVersion
        self.decision = decision
    }
}

struct AppliedRepairAction: Identifiable, Codable, Sendable {
    let id: UUID
    let action: RepairAction
    let verified: Bool
}

enum ReadinessDecision: String, Codable, Sendable {
    case ready
    case blocked
}

struct RevalidationComparison: Codable, Sendable {
    let originalReportID: UUID
    let preparedReportID: UUID
    let resolvedFindingCodes: Set<FindingCode>
    let retainedFindingCodes: Set<FindingCode>
    let introducedFindingCodes: Set<FindingCode>
    let verifiedActionIDs: Set<UUID>
    let readiness: ReadinessDecision
}

struct PreparedBook: Identifiable, Sendable {
    let id: UUID
    let batchItemID: UUID
    let file: StagedFileReference
    let originalDisplayName: String
    let format: BookFormat
    let byteCount: Int64
    let contentDigest: String
    let comparison: RevalidationComparison?
}

struct PreparationResult: Sendable {
    let originalReport: AuditReport?
    let plan: PreparationPlan
    let appliedActions: [AppliedRepairAction]
    let preparedReport: AuditReport?
    let comparison: RevalidationComparison?
    let preparedBook: PreparedBook?
    let failure: SanitizedFailure?

    var isReady: Bool {
        preparedBook != nil && failure == nil
    }
}
