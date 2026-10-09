import Foundation
import Testing
@testable import BookSender

struct EPUBRepairEngineTests {
    @Test
    func plansOnlySupportedAutomaticActionsInStableOrder() {
        let report = AuditReport(
            id: UUID(),
            findings: [
                finding(.mimetypeNotFirst, rule: "repair.mimetype"),
                finding(
                    .containerMissing,
                    rule: "repair.container",
                    evidence: ["package": "OEBPS/content.opf"]
                ),
                finding(.mimetypeCompressed, rule: "repair.mimetype"),
            ],
            inspectedAt: Date()
        )
        let engine = EPUBRepairEngine(
            writer: FailingArchiveWriter(
                failure: sanitizedFailure(.unexpectedRepair, family: .repair)
            ),
            workspaceStore: WorkspaceStore()
        )

        let plan = engine.plan(for: report)

        #expect(
            plan.actions == [
                .rebuildMimetype,
                .restoreContainer(packagePath: "OEBPS/content.opf"),
            ]
        )
        #expect(
            plan.expectedPostconditions
                == [.mimetypeNotFirst, .containerMissing, .mimetypeCompressed]
        )
    }

    @Test
    func blocksAmbiguousOrUnsupportedAutomaticEvidence() {
        let report = AuditReport(
            id: UUID(),
            findings: [
                finding(.referenceAmbiguous, rule: "repair.reference"),
            ],
            inspectedAt: Date()
        )
        let engine = EPUBRepairEngine(
            writer: FailingArchiveWriter(
                failure: sanitizedFailure(.unexpectedRepair, family: .repair)
            ),
            workspaceStore: WorkspaceStore()
        )

        #expect(engine.plan(for: report).decision == .blocked)
    }

    @Test
    func comparisonRejectsIntroducedCriticalFinding() {
        let original = AuditReport(
            id: UUID(),
            findings: [finding(.mimetypeInvalid, rule: "repair.mimetype")],
            inspectedAt: Date()
        )
        let prepared = AuditReport(
            id: UUID(),
            findings: [
                HealthFinding(
                    id: UUID(),
                    code: .remoteReference,
                    severity: .critical,
                    location: nil,
                    messageKey: "remote",
                    repairability: .forbidden,
                    evidence: [:]
                ),
            ],
            inspectedAt: Date()
        )
        let engine = EPUBRepairEngine(
            writer: FailingArchiveWriter(
                failure: sanitizedFailure(.unexpectedRepair, family: .repair)
            ),
            workspaceStore: WorkspaceStore()
        )

        let comparison = engine.compare(
            original: original,
            prepared: prepared,
            applied: [
                AppliedRepairAction(
                    id: UUID(),
                    action: .rebuildMimetype,
                    verified: true
                ),
            ]
        )

        #expect(comparison.readiness == .blocked)
        #expect(comparison.introducedFindingCodes == [.remoteReference])
    }

    @Test
    func forwardsTypedWorkingCopyFailureWithoutPathOrRawError() async throws {
        let stores = try TestStores.make()
        defer { stores.cleanup() }
        let workspaceStore = WorkspaceStore(
            rootURL: stores.rootURL.appending(component: "work")
        )
        let workspace = try await workspaceStore.createWorkspace(
            batchID: UUID(),
            itemID: UUID()
        )
        let original = try FixtureFactory.makeEPUB(
            .missingMimetype,
            in: stores.rootURL
        )
        let source = try await workspaceStore.stageReadOnlySource(
            original,
            in: workspace,
            maximumBytes: SafetyLimits.standard.maximumBookBytes
        )
        let writerFailure = SanitizedFailure(
            family: .repair,
            code: .repairWrite,
            message: "The working copy was not written.",
            recoveryAction: .reviewBook
        )
        let engine = EPUBRepairEngine(
            writer: FailingArchiveWriter(failure: writerFailure),
            workspaceStore: workspaceStore
        )

        let result = await engine.prepare(
            source: source,
            workspace: workspace,
            displayName: "Synthetic.epub"
        )

        #expect(result.failure?.code == .repairWrite)
        #expect(result.failure?.evidence.phase == .workingCopyWrite)
        #expect(String(describing: result.failure).contains(original.path) == false)
    }

    @Test
    func translatesUnexpectedWorkingCopyFailureWithExactPhase() async throws {
        let stores = try TestStores.make()
        defer { stores.cleanup() }
        let workspaceStore = WorkspaceStore(
            rootURL: stores.rootURL.appending(component: "work")
        )
        let workspace = try await workspaceStore.createWorkspace(
            batchID: UUID(),
            itemID: UUID()
        )
        let original = try FixtureFactory.makeEPUB(
            .validEPUB3,
            in: stores.rootURL
        )
        let source = try await workspaceStore.stageReadOnlySource(
            original,
            in: workspace,
            maximumBytes: SafetyLimits.standard.maximumBookBytes
        )
        let engine = EPUBRepairEngine(
            writer: UnexpectedArchiveWriter(),
            workspaceStore: workspaceStore
        )

        let result = await engine.prepare(
            source: source,
            workspace: workspace,
            displayName: "Synthetic.epub"
        )

        #expect(result.failure?.family == .repair)
        #expect(result.failure?.code == .unexpectedRepair)
        #expect(result.failure?.evidence.phase == .workingCopyWrite)
        #expect(String(describing: result.failure).contains("raw-writer") == false)
    }

    @Test(arguments: [
        "repair.container",
        "repair.media-type",
        "repair.reference",
        "repair.xml",
        "repair.spine",
        "repair.path",
        "repair.unknown",
    ])
    func blocksAutomaticRuleWithoutEvidence(rule: String) {
        let report = AuditReport(
            id: UUID(),
            findings: [finding(.referenceMissing, rule: rule)],
            inspectedAt: Date()
        )

        let plan = planEngine().plan(for: report)

        #expect(plan.decision == .blocked)
        #expect(plan.actions.isEmpty)
    }

    @Test
    func blocksMediaTypeRepairWhenEvidenceIsIncomplete() {
        let report = AuditReport(
            id: UUID(),
            findings: [
                finding(.mimetypeMissing, rule: "repair.mimetype"),
                finding(
                    .manifestMediaTypeMismatch,
                    rule: "repair.media-type",
                    evidence: [
                        "package": "OEBPS/content.opf",
                        "href": "Fonts/book.ttf",
                    ]
                ),
            ],
            inspectedAt: Date()
        )

        let plan = planEngine().plan(for: report)

        #expect(plan.decision == .blocked)
        #expect(plan.actions.isEmpty)
    }

    @Test
    func plansEachRuleInFirstSeenOrderAndDropsOnlyEqualActions() {
        let report = AuditReport(
            id: UUID(),
            findings: [
                finding(
                    .containerInvalid,
                    rule: "repair.xml",
                    evidence: ["path": "META-INF/container.xml"]
                ),
                finding(
                    .manifestMediaTypeMismatch,
                    rule: "repair.media-type",
                    evidence: [
                        "package": "OEBPS/content.opf",
                        "href": "Fonts/a.ttf",
                        "declared": "application/x-font-truetype",
                        "expected": "font/ttf",
                    ]
                ),
                finding(.mimetypeMissing, rule: "repair.mimetype"),
                finding(
                    .referenceMissing,
                    rule: "repair.spine",
                    evidence: [
                        "package": "OEBPS/content.opf",
                        "idref": "missing",
                    ]
                ),
                finding(
                    .referenceMissing,
                    rule: "repair.reference",
                    evidence: [
                        "package": "OEBPS/content.opf",
                        "from": "Chapter.xhtml",
                        "to": "chapter.xhtml",
                    ]
                ),
                finding(
                    .containerMissing,
                    rule: "repair.container",
                    evidence: ["package": "OEBPS/content.opf"]
                ),
                finding(.mimetypeCompressed, rule: "repair.mimetype"),
                finding(
                    .manifestMediaTypeMismatch,
                    rule: "repair.media-type",
                    evidence: [
                        "package": "OEBPS/content.opf",
                        "href": "Fonts/a.ttf",
                        "declared": "application/x-font-truetype",
                        "expected": "font/ttf",
                    ]
                ),
                finding(
                    .manifestMediaTypeMismatch,
                    rule: "repair.media-type",
                    evidence: [
                        "package": "OEBPS/content.opf",
                        "href": "Fonts/b.ttf",
                        "declared": "application/x-font-truetype",
                        "expected": "font/ttf",
                    ]
                ),
            ],
            inspectedAt: Date()
        )

        let plan = planEngine().plan(for: report)

        #expect(plan.decision == .writeEPUBWorkingCopy)
        #expect(
            plan.actions == [
                .normalizeXML(path: "META-INF/container.xml"),
                .correctMediaType(
                    package: "OEBPS/content.opf",
                    href: "Fonts/a.ttf",
                    from: "application/x-font-truetype",
                    to: "font/ttf"
                ),
                .rebuildMimetype,
                .removeDanglingSpineItem(
                    package: "OEBPS/content.opf",
                    idref: "missing"
                ),
                .repairReference(
                    document: "OEBPS/content.opf",
                    from: "Chapter.xhtml",
                    to: "chapter.xhtml"
                ),
                .restoreContainer(packagePath: "OEBPS/content.opf"),
                .correctMediaType(
                    package: "OEBPS/content.opf",
                    href: "Fonts/b.ttf",
                    from: "application/x-font-truetype",
                    to: "font/ttf"
                ),
            ]
        )
    }

    private func planEngine() -> EPUBRepairEngine {
        EPUBRepairEngine(
            writer: FailingArchiveWriter(
                failure: sanitizedFailure(.unexpectedRepair, family: .repair)
            ),
            workspaceStore: WorkspaceStore()
        )
    }

    private func finding(
        _ code: FindingCode,
        rule: String,
        evidence: [String: String] = [:]
    ) -> HealthFinding {
        HealthFinding(
            id: UUID(),
            code: code,
            severity: .error,
            location: nil,
            messageKey: code.rawValue,
            repairability: .automatic(ruleID: rule),
            evidence: evidence
        )
    }
}

private struct UnexpectedArchiveWriter: EPUBArchiveWriting {
    private struct RawWriterError: Error {}

    func write(
        source: StagedFileReference,
        plan: PreparationPlan,
        workspace: WorkspaceReference,
        limits: SafetyLimits
    ) async throws -> StagedFileReference {
        throw RawWriterError()
    }
}
