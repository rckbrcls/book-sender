import Foundation

struct EPUBRepairEngine: RepairPlanning, ReportComparing, EPUBPreparing {
    private let writer: any EPUBArchiveWriting
    private let workspaceStore: any WorkspaceStoring
    private let auditor: EPUBAuditEngine
    private let limits: SafetyLimits

    init(
        writer: any EPUBArchiveWriting,
        workspaceStore: any WorkspaceStoring,
        auditor: EPUBAuditEngine = EPUBAuditEngine(),
        limits: SafetyLimits = .standard
    ) {
        self.writer = writer
        self.workspaceStore = workspaceStore
        self.auditor = auditor
        self.limits = limits
    }

    func plan(for report: AuditReport) -> PreparationPlan {
        guard report.health == .healthy || report.health == .repairable else {
            return PreparationPlan(
                id: UUID(),
                originalAuditIdentifier: report.id,
                actions: [],
                limitsVersion: limits.version,
                decision: .blocked
            )
        }

        var actions: [RepairAction] = []
        var postconditions = Set<FindingCode>()
        for finding in report.findings {
            guard case .automatic(let ruleID) = finding.repairability else {
                continue
            }
            guard let action = repairAction(ruleID: ruleID, evidence: finding.evidence) else {
                return PreparationPlan(
                    id: UUID(),
                    originalAuditIdentifier: report.id,
                    actions: [],
                    limitsVersion: limits.version,
                    decision: .blocked
                )
            }
            postconditions.insert(finding.code)
            if !actions.contains(action) {
                actions.append(action)
            }
        }

        return PreparationPlan(
            id: UUID(),
            originalAuditIdentifier: report.id,
            actions: actions,
            expectedPostconditions: postconditions,
            limitsVersion: limits.version,
            decision: .writeEPUBWorkingCopy
        )
    }

    func compare(
        original: AuditReport,
        prepared: AuditReport,
        applied: [AppliedRepairAction]
    ) -> RevalidationComparison {
        let originalCodes = Set(original.findings.map(\.code))
        let preparedCodes = Set(prepared.findings.map(\.code))
        let introduced = preparedCodes.subtracting(originalCodes)
        let hasCriticalRegression = prepared.findings.contains {
            introduced.contains($0.code) && $0.severity == .critical
        }
        let allVerified = applied.allSatisfy(\.verified)
        return RevalidationComparison(
            originalReportID: original.id,
            preparedReportID: prepared.id,
            resolvedFindingCodes: originalCodes.subtracting(preparedCodes),
            retainedFindingCodes: originalCodes.intersection(preparedCodes),
            introducedFindingCodes: introduced,
            verifiedActionIDs: Set(applied.filter(\.verified).map(\.id)),
            readiness: !hasCriticalRegression
                && allVerified
                && prepared.health == .healthy
                ? .ready
                : .blocked
        )
    }

    func prepare(
        source: StagedFileReference,
        workspace: WorkspaceReference,
        displayName: String
    ) async -> PreparationResult {
        var originalReport: AuditReport?
        var plan = blockedPlan()
        var preparedReport: AuditReport?
        var applied: [AppliedRepairAction] = []
        var comparison: RevalidationComparison?
        var activePhase = DiagnosticPhase.structuralAudit

        do {
            try Task.checkCancellation()
            let originalArchive = ZIPFoundationEPUBArchive(source: source)
            let original = try await auditor.audit(
                originalArchive,
                source: source
            )
            originalReport = original
            plan = self.plan(for: original)
            guard plan.decision == .writeEPUBWorkingCopy else {
                activePhase = .repairPlanning
                throw failure(
                    .repairBlocked,
                    message: "This EPUB needs attention before it can be sent."
                )
            }

            activePhase = .workingCopyWrite
            let partial = try await writer.write(
                source: source,
                plan: plan,
                workspace: workspace,
                limits: limits
            )
            let preparedArchive = ZIPFoundationEPUBArchive(source: partial)
            activePhase = .revalidation
            let revalidated = try await auditor.audit(
                preparedArchive,
                source: partial
            )
            preparedReport = revalidated
            let remainingCodes = Set(revalidated.findings.map(\.code))
            applied = plan.actions.map { action in
                AppliedRepairAction(
                    id: UUID(),
                    action: action,
                    verified: postconditions(for: action)
                        .isDisjoint(with: remainingCodes)
                )
            }
            let compared = compare(
                original: original,
                prepared: revalidated,
                applied: applied
            )
            comparison = compared
            guard compared.readiness == .ready,
                  plan.expectedPostconditions.isSubset(
                      of: compared.resolvedFindingCodes
                  )
            else {
                throw failure(.repairRevalidationFailed)
            }

            let promoted = try await workspaceStore.promotePartial(
                partial.url.lastPathComponent,
                to: "prepared.epub",
                in: workspace
            )
            let digest = try await workspaceStore.digest(of: promoted)
            let values = try promoted.url.resourceValues(forKeys: [.fileSizeKey])
            let byteCount = Int64(values.fileSize ?? 0)
            guard byteCount > 0,
                  limits.permitsAttachmentBytes(byteCount)
            else {
                throw failure(
                    .repairAttachmentSize,
                    message: "The prepared EPUB exceeds the delivery size limit."
                )
            }

            let book = PreparedBook(
                id: UUID(),
                batchItemID: workspace.itemID,
                file: promoted,
                originalDisplayName: displayName,
                format: .epub,
                byteCount: byteCount,
                contentDigest: digest,
                comparison: compared
            )
            return PreparationResult(
                originalReport: original,
                plan: plan,
                appliedActions: applied,
                preparedReport: revalidated,
                comparison: compared,
                preparedBook: book,
                failure: nil
            )
        } catch is CancellationError {
            await workspaceStore.cleanupPartialFiles(in: workspace)
            return result(
                originalReport: originalReport,
                plan: plan,
                applied: applied,
                preparedReport: preparedReport,
                comparison: comparison,
                failure: SanitizedFailure(
                    family: .repair,
                    code: .repairCancelled,
                    message: "EPUB preparation was cancelled.",
                    recoveryAction: nil
                )
            )
        } catch let sanitized as SanitizedFailure {
            await workspaceStore.cleanupPartialFiles(in: workspace)
            return result(
                originalReport: originalReport,
                plan: plan,
                applied: applied,
                preparedReport: preparedReport,
                comparison: comparison,
                failure: sanitized
            )
        } catch {
            await workspaceStore.cleanupPartialFiles(in: workspace)
            let family: FailureFamily =
                activePhase == .structuralAudit || activePhase == .revalidation
                ? .audit
                : .repair
            return result(
                originalReport: originalReport,
                plan: plan,
                applied: applied,
                preparedReport: preparedReport,
                comparison: comparison,
                failure: SanitizedFailure(
                    family: family,
                    code: .unexpected(for: family),
                    message: "An unexpected EPUB preparation step failed.",
                    recoveryAction: .reviewBook,
                    evidence: DiagnosticEvidence(
                        phase: activePhase,
                        retryDisposition: .reviewBook
                    )
                )
            )
        }
    }

    func postconditions(for action: RepairAction) -> Set<FindingCode> {
        switch action {
        case .rebuildMimetype:
            [.mimetypeMissing, .mimetypeInvalid, .mimetypeNotFirst, .mimetypeCompressed]
        case .restoreContainer:
            [.containerMissing, .containerInvalid, .packageMissing]
        case .correctMediaType:
            [.manifestMediaTypeMismatch]
        case .normalizePath:
            [.referenceMissing]
        case .repairReference:
            [.referenceMissing, .referenceAmbiguous]
        case .normalizeXML:
            [.containerInvalid, .packageInvalid]
        case .removeDanglingSpineItem:
            [.referenceMissing]
        }
    }

    private func repairAction(
        ruleID: String,
        evidence: [String: String]
    ) -> RepairAction? {
        switch ruleID {
        case "repair.mimetype":
            .rebuildMimetype
        case "repair.container":
            evidenceValue(evidence, "package").map {
                .restoreContainer(packagePath: $0)
            }
        case "repair.media-type":
            mediaTypeAction(evidence)
        case "repair.reference":
            referenceAction(evidence)
        case "repair.xml":
            evidenceValue(evidence, "path").map {
                .normalizeXML(path: $0)
            }
        case "repair.spine":
            spineAction(evidence)
        default:
            nil
        }
    }

    private func mediaTypeAction(_ evidence: [String: String]) -> RepairAction? {
        guard let package = evidenceValue(evidence, "package"),
              let href = evidenceValue(evidence, "href"),
              let from = evidenceValue(evidence, "declared"),
              let to = evidenceValue(evidence, "expected")
        else {
            return nil
        }
        return .correctMediaType(package: package, href: href, from: from, to: to)
    }

    private func referenceAction(_ evidence: [String: String]) -> RepairAction? {
        guard let document = evidenceValue(evidence, "package"),
              let from = evidenceValue(evidence, "from"),
              let to = evidenceValue(evidence, "to")
        else {
            return nil
        }
        return .repairReference(document: document, from: from, to: to)
    }

    private func spineAction(_ evidence: [String: String]) -> RepairAction? {
        guard let package = evidenceValue(evidence, "package"),
              let idref = evidenceValue(evidence, "idref")
        else {
            return nil
        }
        return .removeDanglingSpineItem(package: package, idref: idref)
    }

    private func evidenceValue(
        _ evidence: [String: String],
        _ key: String
    ) -> String? {
        guard let value = evidence[key], !value.isEmpty else { return nil }
        return value
    }

    private func blockedPlan() -> PreparationPlan {
        PreparationPlan(
            id: UUID(),
            originalAuditIdentifier: UUID(),
            actions: [],
            limitsVersion: limits.version,
            decision: .blocked
        )
    }

    private func result(
        originalReport: AuditReport?,
        plan: PreparationPlan,
        applied: [AppliedRepairAction],
        preparedReport: AuditReport?,
        comparison: RevalidationComparison?,
        failure: SanitizedFailure
    ) -> PreparationResult {
        PreparationResult(
            originalReport: originalReport,
            plan: plan,
            appliedActions: applied,
            preparedReport: preparedReport,
            comparison: comparison,
            preparedBook: nil,
            failure: failure
        )
    }

    private func failure(
        _ code: DiagnosticCode,
        message: String = "The prepared EPUB did not pass revalidation."
    ) -> SanitizedFailure {
        SanitizedFailure(
            family: .repair,
            code: code,
            message: message,
            recoveryAction: .reviewBook
        )
    }
}
