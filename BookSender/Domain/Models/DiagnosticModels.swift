import Foundation

enum DiagnosticCode: String, Codable, CaseIterable, Hashable, Sendable {
    case deliverySetupValidation = "delivery-setup.validation"

    case intakeCapacity = "intake.capacity"
    case intakeChanged = "intake.changed"
    case intakeDuplicate = "intake.duplicate"
    case intakeFailed = "intake.failed"
    case intakeSize = "intake.size"
    case intakeUnreadable = "intake.unreadable"
    case intakeUnsupported = "intake.unsupported"

    case archiveDuplicatePath = "archive.duplicate-path"
    case archiveEncrypted = "archive.encrypted"
    case archiveEntryLimit = "archive.entry-limit"
    case archiveEntryUnavailable = "archive.entry-unavailable"
    case archiveExpansionRatio = "archive.expansion-ratio"
    case archiveExtract = "archive.extract"
    case archiveOpen = "archive.open"
    case archiveSizeLimit = "archive.size-limit"
    case archiveTimeout = "archive.timeout"
    case archiveUnsafePath = "archive.unsafe-path"
    case archiveUnsupportedEntry = "archive.unsupported-entry"

    case xmlByteLimit = "xml.byte-limit"
    case xmlCancelled = "xml.cancelled"
    case xmlExternalEntity = "xml.external-entity"
    case xmlInvalid = "xml.invalid"
    case xmlStructureLimit = "xml.structure-limit"
    case xmlTextLimit = "xml.text-limit"
    case xmlTimeout = "xml.timeout"

    case repairAttachmentSize = "repair.attachment-size"
    case repairBlocked = "repair.blocked"
    case repairCancelled = "repair.cancelled"
    case repairContainer = "repair.container"
    case repairEntryCreate = "repair.entry-create"
    case repairEntryMissing = "repair.entry-missing"
    case repairFailed = "repair.failed"
    case repairInvalidPlan = "repair.invalid-plan"
    case repairMediaType = "repair.media-type"
    case repairMimetype = "repair.mimetype"
    case repairOutputCreate = "repair.output-create"
    case repairPath = "repair.path"
    case repairPrecondition = "repair.precondition"
    case repairReference = "repair.reference"
    case repairRevalidationFailed = "repair.revalidation-failed"
    case repairSpine = "repair.spine"
    case repairTimeout = "repair.timeout"
    case repairUnsupportedAction = "repair.unsupported-action"
    case repairWrite = "repair.write"
    case repairXML = "repair.xml"

    case workspaceCollision = "workspace.collision"
    case workspaceCopy = "workspace.copy"
    case workspaceInvalidMarker = "workspace.invalid-marker"
    case workspaceInvalidPath = "workspace.invalid-path"
    case workspaceMarker = "workspace.marker"
    case workspacePartialCreate = "workspace.partial-create"
    case workspacePromote = "workspace.promote"
    case workspaceSizeLimit = "workspace.size-limit"
    case workspaceTimeout = "workspace.timeout"
    case pipelineMissingStagedSource = "pipeline.missing-staged-source"
    case pipelinePreparationResult = "pipeline.preparation-result"

    case credentialDelete = "credential.delete"
    case credentialEmpty = "credential.empty"
    case credentialMissing = "credential.missing"
    case credentialRead = "credential.read"
    case credentialSave = "credential.save"
    case credentialUITest = "credential.ui-test"
    case preferencesInvalid = "preferences.invalid"
    case preferencesInvalidRevision = "preferences.invalid-revision"

    case deliveryFailed = "delivery.failed"
    case mimeHeaderInjection = "mime.header-injection"
    case pdfCancelled = "pdf.cancelled"
    case pdfRead = "pdf.read"
    case pdfSignature = "pdf.signature"
    case pdfSize = "pdf.size"
    case pdfStructure = "pdf.structure"
    case smtpAttachmentSize = "smtp.attachment-size"
    case smtpAuthenticationRejected = "smtp.authentication-rejected"
    case smtpAuthenticationUnavailable = "smtp.auth-unavailable"
    case smtpCommandSize = "smtp.command-size"
    case smtpConnectionClosed = "smtp.connection-closed"
    case smtpDataRejected = "smtp.data-rejected"
    case smtpDeliveryUnknown = "smtp.delivery-unknown"
    case smtpEHLO = "smtp.ehlo"
    case smtpFinalAcceptanceRejected = "smtp.final-acceptance-rejected"
    case smtpGreeting = "smtp.greeting"
    case smtpRecipientRejected = "smtp.recipient-rejected"
    case smtpReplyCode = "smtp.reply-code"
    case smtpReplyCount = "smtp.reply-count"
    case smtpReplyFormat = "smtp.reply-format"
    case smtpReplyLine = "smtp.reply-line"
    case smtpSecureEHLO = "smtp.secure-ehlo"
    case smtpSecureChannel = "smtp.secure-channel"
    case smtpSenderRejected = "smtp.sender-rejected"
    case smtpStartTLS = "smtp.starttls"
    case smtpStartTLSState = "smtp.starttls-state"
    case smtpStartTLSUnavailable = "smtp.starttls-unavailable"
    case smtpTimeout = "smtp.timeout"
    case smtpTransport = "smtp.transport"
    case smtpUITestRejected = "smtp.ui-test-rejected"

    case shortcutConflict = "shortcut.conflict"
    case clipboardWrite = "clipboard.write"
    case historyUnavailable = "history.unavailable"
    case historyRead = "history.read"
    case historyDecode = "history.decode"
    case historyUnsupportedSchema = "history.unsupported-schema"
    case historyLimit = "history.limit"
    case historyWrite = "history.write"
    case historyClear = "history.clear"
    case startupBootstrap = "startup.bootstrap"
    case updateConfiguration = "update.configuration"

    case unexpectedIntake = "unexpected.intake"
    case unexpectedArchive = "unexpected.archive"
    case unexpectedXML = "unexpected.xml"
    case unexpectedAudit = "unexpected.audit"
    case unexpectedRepair = "unexpected.repair"
    case unexpectedFilesystem = "unexpected.filesystem"
    case unexpectedCredential = "unexpected.credential"
    case unexpectedDelivery = "unexpected.delivery"
    case unexpectedShortcut = "unexpected.shortcut"

    var expectedFamily: FailureFamily {
        switch self {
        case .intakeCapacity, .intakeChanged, .intakeDuplicate, .intakeFailed,
             .intakeSize, .intakeUnreadable, .intakeUnsupported,
             .pdfCancelled, .pdfRead, .pdfSignature, .pdfSize, .pdfStructure,
             .unexpectedIntake:
            return .intake
        case .archiveDuplicatePath, .archiveEncrypted, .archiveEntryLimit,
             .archiveEntryUnavailable, .archiveExpansionRatio, .archiveExtract,
             .archiveOpen, .archiveSizeLimit, .archiveTimeout,
             .archiveUnsafePath, .archiveUnsupportedEntry, .unexpectedArchive:
            return .archive
        case .xmlByteLimit, .xmlCancelled, .xmlExternalEntity, .xmlInvalid,
             .xmlStructureLimit, .xmlTextLimit, .xmlTimeout, .unexpectedXML:
            return .xml
        case .unexpectedAudit:
            return .audit
        case .repairAttachmentSize, .repairBlocked, .repairCancelled,
             .repairContainer, .repairEntryCreate, .repairEntryMissing,
             .repairFailed, .repairInvalidPlan, .repairMediaType,
             .repairMimetype, .repairOutputCreate, .repairPath,
             .repairPrecondition, .repairReference, .repairRevalidationFailed,
             .repairSpine, .repairTimeout, .repairUnsupportedAction,
             .repairWrite, .repairXML, .unexpectedRepair:
            return .repair
        case .workspaceCollision, .workspaceCopy, .workspaceInvalidMarker,
             .workspaceInvalidPath, .workspaceMarker, .workspacePartialCreate,
             .workspacePromote, .workspaceSizeLimit, .workspaceTimeout,
             .pipelineMissingStagedSource, .pipelinePreparationResult,
             .clipboardWrite, .historyUnavailable, .historyRead,
             .historyDecode, .historyUnsupportedSchema, .historyLimit,
             .historyWrite, .historyClear, .startupBootstrap,
             .updateConfiguration,
             .unexpectedFilesystem:
            return .filesystem
        case .deliverySetupValidation, .credentialDelete, .credentialEmpty,
             .credentialMissing, .credentialRead, .credentialSave,
             .credentialUITest, .preferencesInvalid,
             .preferencesInvalidRevision, .unexpectedCredential:
            return .credential
        case .deliveryFailed, .mimeHeaderInjection, .smtpAttachmentSize,
             .smtpAuthenticationRejected, .smtpAuthenticationUnavailable,
             .smtpCommandSize, .smtpConnectionClosed, .smtpDataRejected,
             .smtpDeliveryUnknown, .smtpEHLO, .smtpFinalAcceptanceRejected,
             .smtpGreeting, .smtpRecipientRejected, .smtpReplyCode,
             .smtpReplyCount, .smtpReplyFormat, .smtpReplyLine,
             .smtpSecureEHLO, .smtpSecureChannel, .smtpSenderRejected,
             .smtpStartTLS, .smtpStartTLSState, .smtpStartTLSUnavailable,
             .smtpTimeout, .smtpTransport, .smtpUITestRejected,
             .unexpectedDelivery:
            return .delivery
        case .shortcutConflict, .unexpectedShortcut:
            return .shortcut
        }
    }

    static func unexpected(for family: FailureFamily) -> DiagnosticCode {
        switch family {
        case .intake: .unexpectedIntake
        case .archive: .unexpectedArchive
        case .xml: .unexpectedXML
        case .audit: .unexpectedAudit
        case .repair: .unexpectedRepair
        case .filesystem: .unexpectedFilesystem
        case .credential: .unexpectedCredential
        case .delivery: .unexpectedDelivery
        case .shortcut: .unexpectedShortcut
        }
    }
}

enum DiagnosticPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case bootstrap
    case preferenceRead
    case preferenceWrite
    case credentialRead
    case credentialWrite
    case credentialDelete
    case inputValidation
    case intake
    case workspaceStaging
    case archiveSafety
    case xmlParsing
    case structuralAudit
    case repairPlanning
    case workingCopyWrite
    case revalidation
    case shortcutRegistration
    case updateCheck
    case smtpConnecting
    case smtpSecuring
    case smtpAuthenticating
    case smtpSender
    case smtpRecipient
    case smtpData
    case smtpFinalAcceptance
    case clipboardWrite
    case historyLoad
    case historyRecord
    case historyClear
    case cleanup
}

enum DiagnosticSeverity: String, Codable, CaseIterable, Hashable, Sendable {
    case info
    case warning
    case error
    case critical
}

enum RetryDisposition: String, Codable, CaseIterable, Hashable, Sendable {
    case notRetryable
    case editSetup
    case retrySafe
    case checkBeforeRetry
    case chooseAnotherFile
    case reviewBook
    case restartApplication
}

struct EnhancedStatusCode: Codable, Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    let statusClass: Int
    let subject: Int
    let detail: Int

    init?(parsing value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let statusClass = Int(components[0]),
              let subject = Int(components[1]),
              let detail = Int(components[2]),
              [2, 4, 5].contains(statusClass),
              components[1].count <= 3,
              components[2].count <= 3,
              (0...999).contains(subject),
              (0...999).contains(detail)
        else {
            return nil
        }
        self.statusClass = statusClass
        self.subject = subject
        self.detail = detail
    }

    var description: String {
        "\(statusClass).\(subject).\(detail)"
    }
}

struct ProviderStatus: Codable, Equatable, Hashable, Sendable {
    let replyCode: Int
    let enhancedStatus: EnhancedStatusCode?

    init?(replyCode: Int, enhancedStatus: EnhancedStatusCode? = nil) {
        guard (200...599).contains(replyCode) else { return nil }
        self.replyCode = replyCode
        self.enhancedStatus = enhancedStatus
    }
}

enum SafetyLimitIdentifier: String, Codable, CaseIterable, Hashable, Sendable {
    case batchItems
    case bookBytes
    case archiveEntries
    case archiveCompressedBytes
    case archiveExpandedBytes
    case archiveEntryBytes
    case archiveExpansionRatio
    case xmlBytes
    case xmlStructure
    case xmlText
    case smtpLine
    case smtpReplyLines
    case attachmentBytes
    case operationTimeout
    case smtpTimeout
}

struct DiagnosticContext: Codable, Equatable, Hashable, Sendable {
    var appVersion: String?
    var operationID: UUID?
    var setupRevision: Int?
    var batchTotal: Int?
    var batchCompleted: Int?
    var transmissionStarted: Bool?
    var safetyLimit: SafetyLimitIdentifier?

    init(
        appVersion: String? = nil,
        operationID: UUID? = nil,
        setupRevision: Int? = nil,
        batchTotal: Int? = nil,
        batchCompleted: Int? = nil,
        transmissionStarted: Bool? = nil,
        safetyLimit: SafetyLimitIdentifier? = nil
    ) {
        self.appVersion = appVersion
        self.operationID = operationID
        self.setupRevision = setupRevision
        self.batchTotal = batchTotal
        self.batchCompleted = batchCompleted
        self.transmissionStarted = transmissionStarted
        self.safetyLimit = safetyLimit
    }

    var isValid: Bool {
        guard setupRevision.map({ $0 >= 0 }) ?? true,
              batchTotal.map({ $0 >= 0 }) ?? true,
              batchCompleted.map({ $0 >= 0 }) ?? true
        else {
            return false
        }
        if let batchTotal, let batchCompleted {
            return batchCompleted <= batchTotal
        }
        return true
    }
}

struct DiagnosticEvidence: Codable, Equatable, Hashable, Sendable {
    let phase: DiagnosticPhase
    let severity: DiagnosticSeverity
    let retryDisposition: RetryDisposition
    let providerStatus: ProviderStatus?
    let context: DiagnosticContext

    init(
        phase: DiagnosticPhase,
        severity: DiagnosticSeverity = .error,
        retryDisposition: RetryDisposition,
        providerStatus: ProviderStatus? = nil,
        context: DiagnosticContext = DiagnosticContext()
    ) {
        precondition(context.isValid, "Diagnostic context must be bounded.")
        self.phase = phase
        self.severity = severity
        self.retryDisposition = retryDisposition
        self.providerStatus = providerStatus
        self.context = context
    }

    static func inferred(
        family: FailureFamily,
        code: DiagnosticCode,
        recoveryAction: RecoveryAction?
    ) -> DiagnosticEvidence {
        DiagnosticEvidence(
            phase: inferredPhase(family: family, code: code),
            retryDisposition: inferredRetry(recoveryAction),
            context: inferredContext(code: code)
        )
    }

    private static func inferredPhase(
        family: FailureFamily,
        code: DiagnosticCode
    ) -> DiagnosticPhase {
        switch code {
        case .deliverySetupValidation:
            return .inputValidation
        case .intakeCapacity, .intakeDuplicate, .intakeSize,
             .intakeUnreadable, .intakeUnsupported, .intakeChanged,
             .intakeFailed, .pdfSize, .pdfSignature, .pdfStructure,
             .pdfRead, .pdfCancelled:
            return .intake
        case .preferencesInvalid: return .preferenceRead
        case .preferencesInvalidRevision: return .preferenceWrite
        case .credentialRead, .credentialMissing: return .credentialRead
        case .credentialSave, .credentialEmpty, .credentialUITest:
            return .credentialWrite
        case .credentialDelete: return .credentialDelete
        case .smtpConnectionClosed, .smtpTransport:
            return .smtpConnecting
        case .smtpGreeting, .smtpSecureChannel, .smtpStartTLS, .smtpStartTLSState,
             .smtpStartTLSUnavailable, .smtpSecureEHLO, .smtpEHLO:
            return .smtpSecuring
        case .smtpAuthenticationRejected, .smtpAuthenticationUnavailable,
             .smtpCommandSize:
            return .smtpAuthenticating
        case .smtpSenderRejected: return .smtpSender
        case .smtpRecipientRejected: return .smtpRecipient
        case .smtpFinalAcceptanceRejected: return .smtpFinalAcceptance
        case .smtpDataRejected, .smtpAttachmentSize, .mimeHeaderInjection,
             .smtpDeliveryUnknown:
            return .smtpData
        case .smtpTimeout, .smtpReplyCode, .smtpReplyCount, .smtpReplyFormat,
             .smtpReplyLine, .smtpUITestRejected, .deliveryFailed:
            return .smtpConnecting
        case .clipboardWrite: return .clipboardWrite
        case .historyUnavailable, .historyRead, .historyDecode,
             .historyUnsupportedSchema, .historyLimit:
            return .historyLoad
        case .historyWrite:
            return .historyRecord
        case .historyClear:
            return .historyClear
        case .startupBootstrap: return .bootstrap
        case .updateConfiguration: return .updateCheck
        case .workspaceCollision, .workspaceCopy, .workspaceInvalidMarker,
             .workspaceInvalidPath, .workspaceMarker, .workspacePartialCreate,
             .workspaceSizeLimit, .workspaceTimeout:
            return .workspaceStaging
        case .workspacePromote:
            return .workingCopyWrite
        case .repairOutputCreate, .repairEntryCreate, .repairEntryMissing,
             .repairWrite, .repairPrecondition, .repairTimeout,
             .repairUnsupportedAction, .repairInvalidPlan:
            return .workingCopyWrite
        case .repairRevalidationFailed, .repairAttachmentSize:
            return .revalidation
        case .pipelineMissingStagedSource:
            return .workspaceStaging
        case .pipelinePreparationResult:
            return .revalidation
        default:
            switch family {
            case .intake: return .intake
            case .archive: return .archiveSafety
            case .xml: return .xmlParsing
            case .audit: return .structuralAudit
            case .repair:
                return code == .repairRevalidationFailed
                    ? .revalidation
                    : .repairPlanning
            case .filesystem: return .workspaceStaging
            case .credential: return .credentialRead
            case .delivery: return .smtpConnecting
            case .shortcut: return .shortcutRegistration
            }
        }
    }

    private static func inferredContext(
        code: DiagnosticCode
    ) -> DiagnosticContext {
        let limit: SafetyLimitIdentifier? = switch code {
        case .intakeCapacity: .batchItems
        case .intakeSize, .pdfSize: .bookBytes
        case .archiveEntryLimit: .archiveEntries
        case .archiveSizeLimit: .archiveExpandedBytes
        case .archiveExpansionRatio: .archiveExpansionRatio
        case .xmlByteLimit: .xmlBytes
        case .xmlStructureLimit: .xmlStructure
        case .xmlTextLimit: .xmlText
        case .archiveTimeout, .xmlTimeout, .repairTimeout,
             .workspaceTimeout: .operationTimeout
        case .repairAttachmentSize, .smtpAttachmentSize: .attachmentBytes
        case .smtpCommandSize, .smtpReplyLine: .smtpLine
        case .smtpReplyCount: .smtpReplyLines
        case .smtpTimeout: .smtpTimeout
        default: nil
        }
        return DiagnosticContext(safetyLimit: limit)
    }

    private static func inferredRetry(
        _ recoveryAction: RecoveryAction?
    ) -> RetryDisposition {
        switch recoveryAction {
        case .editSetup: .editSetup
        case .chooseAnotherFile: .chooseAnotherFile
        case .reviewBook: .reviewBook
        case .retryFailed: .retrySafe
        case .retryHistoryLoad, .retryHistoryClear: .retrySafe
        case .confirmUnknownRetry: .checkBeforeRetry
        case .chooseAnotherShortcut, nil: .notRetryable
        }
    }
}

enum DiagnosticOutcome: String, Codable, Equatable, Hashable, Sendable {
    case failed
    case uncertain
}

struct DiagnosticEvent: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let occurredAt: Date
    let action: FeedbackAction
    let outcome: DiagnosticOutcome
    let failure: SanitizedFailure
    let occurrenceCount: Int

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        action: FeedbackAction,
        outcome: DiagnosticOutcome,
        failure: SanitizedFailure,
        occurrenceCount: Int = 1
    ) {
        precondition(occurrenceCount > 0)
        self.id = id
        self.occurredAt = occurredAt
        self.action = action
        self.outcome = outcome
        self.failure = failure
        self.occurrenceCount = occurrenceCount
    }
}

struct DiagnosticCopy: Equatable, Hashable, Sendable {
    let text: String
}

extension SanitizedFailure {
    static func deliveryUnknown(
        phase: DiagnosticPhase = .smtpFinalAcceptance,
        providerStatus: ProviderStatus? = nil
    ) -> SanitizedFailure {
        SanitizedFailure(
            family: .delivery,
            code: .smtpDeliveryUnknown,
            message: "The final delivery result is unknown.",
            recoveryAction: .confirmUnknownRetry,
            evidence: DiagnosticEvidence(
                phase: phase,
                severity: .warning,
                retryDisposition: .checkBeforeRetry,
                providerStatus: providerStatus,
                context: DiagnosticContext(transmissionStarted: true)
            )
        )
    }
}
