import Foundation
import Testing
@testable import BookSender

struct EPUBPreparationJourneyTests {
    @Test(arguments: [
        FixtureFactory.EPUBVariant.validEPUB3,
        .epub2LegacyTrueTypeMediaType,
        .rootPackageLegacyTrueType,
        .missingMimetype,
        .missingContainer,
    ])
    func writesReopensRevalidatesAndPreservesOriginal(
        variant: FixtureFactory.EPUBVariant
    ) async throws {
        let stores = try TestStores.make()
        defer { stores.cleanup() }
        let workspaceStore = WorkspaceStore(
            rootURL: stores.rootURL.appending(component: "work")
        )
        let workspace = try await workspaceStore.createWorkspace(
            batchID: UUID(),
            itemID: UUID()
        )
        let original = try FixtureFactory.makeEPUB(variant, in: stores.rootURL)
        let originalDigest = try FixtureFactory.digest(of: original)
        let source = try await workspaceStore.stageReadOnlySource(
            original,
            in: workspace,
            maximumBytes: SafetyLimits.standard.maximumBookBytes
        )
        let engine = EPUBRepairEngine(
            writer: EPUBArchiveWriter(),
            workspaceStore: workspaceStore
        )

        let result = await engine.prepare(
            source: source,
            workspace: workspace,
            displayName: original.lastPathComponent
        )

        let prepared = try #require(result.preparedBook)
        #expect(result.preparedReport?.health == .healthy)
        #expect(result.comparison?.readiness == .ready)
        #expect(prepared.file.url.lastPathComponent == "prepared.epub")
        #expect(prepared.contentDigest.isEmpty == false)
        #expect(try FixtureFactory.digest(of: original) == originalDigest)
        #expect(prepared.file.url != original)
    }

    @Test
    func pipelineAddsTypedFailureWhenPreparerReturnsNoTerminalResult() async throws {
        let stores = try TestStores.make()
        defer { stores.cleanup() }
        let workspaceStore = WorkspaceStore(
            rootURL: stores.rootURL.appending(component: "work")
        )
        let pipeline = PipelineActor(
            intakeService: BookIntakeService(
                workspaceStore: workspaceStore
            ),
            epubPreparer: EmptyEPUBPreparer(),
            pdfPreparer: PDFEligibilityService(
                workspaceStore: workspaceStore
            ),
            deliveryService: BookDeliveryService(
                credentials: InMemoryCredentialStore(),
                transport: StubSMTPTransport(outcomes: [.submitted])
            ),
            workspaceStore: workspaceStore,
            historyService: SendHistoryService(
                store: InMemorySendHistoryStore()
            )
        )
        let original = try FixtureFactory.makeEPUB(
            .validEPUB3,
            in: stores.rootURL
        )

        await pipeline.add([original])
        for _ in 0..<2_000 {
            let snapshot = await pipeline.snapshot()
            if snapshot.items.first?.preparation.isTerminal == true {
                break
            }
            await Task.yield()
        }

        let item = try #require(await pipeline.snapshot().items.first)
        guard case .needsAttention(let failure) = item.preparation else {
            Issue.record("Expected a typed preparation failure")
            return
        }
        #expect(failure.family == .filesystem)
        #expect(failure.code == .pipelinePreparationResult)
        #expect(failure.evidence.phase == .revalidation)
    }
}

private struct EmptyEPUBPreparer: EPUBPreparing {
    func prepare(
        source: StagedFileReference,
        workspace: WorkspaceReference,
        displayName: String
    ) async -> PreparationResult {
        PreparationResult(
            originalReport: nil,
            plan: PreparationPlan(
                id: UUID(),
                originalAuditIdentifier: UUID(),
                actions: [],
                decision: .blocked
            ),
            appliedActions: [],
            preparedReport: nil,
            comparison: nil,
            preparedBook: nil,
            failure: nil
        )
    }
}
