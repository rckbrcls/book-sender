import Foundation
import Testing
@testable import BookSender

struct EPUBAuditEngineTests {
    @Test
    func derivesExpectedHealthAndFindingForEveryShippedEPUBRule() async throws {
        let cases: [
            (
                FixtureFactory.EPUBVariant,
                BookHealth,
                Set<FindingCode>
            )
        ] = [
            (.validEPUB2, .healthy, []),
            (.validEPUB3, .healthy, []),
            (.epub2LegacyTrueTypeMediaType, .healthy, []),
            (.missingMimetype, .repairable, [.mimetypeMissing]),
            (.invalidMimetype, .repairable, [.mimetypeInvalid]),
            (.lateMimetype, .repairable, [.mimetypeNotFirst]),
            (.compressedMimetype, .repairable, [.mimetypeCompressed]),
            (.missingContainer, .repairable, [.containerMissing]),
            (.invalidContainer, .repairable, [.containerInvalid]),
            (.missingPackage, .unsupported, [.packageMissing]),
            (.invalidPackage, .needsReview, [.packageInvalid]),
            (.ambiguousPackage, .needsReview, [.packageAmbiguous]),
            (.mediaTypeMismatch, .needsReview, [.manifestMediaTypeMismatch]),
            (.missingReference, .needsReview, [.referenceMissing]),
            (.ambiguousReference, .needsReview, [.referenceAmbiguous]),
            (.encryptedContent, .unsafe, [.encryptedContent]),
            (.activeContent, .unsafe, [.activeContent]),
            (.textJavaScriptActiveContent, .unsafe, [.activeContent]),
            (.remoteReference, .unsafe, [.remoteReference]),
            (.pathTraversal, .unsafe, [.archiveUnsafePath]),
            (.absolutePath, .unsafe, [.archiveUnsafePath]),
            (.duplicateNormalizedPath, .unsafe, [.archiveDuplicatePath]),
            (.symbolicLink, .unsafe, [.archiveUnsupportedEntry]),
            (.unsupportedCompression, .unsafe, [.archiveUnsupportedEntry]),
            (.encryptedArchive, .unsafe, [.archiveEncrypted]),
            (.expansionRatio, .unsafe, [.archiveLimitExceeded]),
            (.directoryEntry, .healthy, []),
            (.externalEntity, .unsafe, [.xmlUnsafe]),
            (.deepXML, .unsafe, [.xmlUnsafe]),
            (.excessiveXML, .unsafe, [.xmlUnsafe]),
        ]
        let directory = try FixtureFactory.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditor = EPUBAuditEngine()

        for (variant, expectedHealth, expectedCodes) in cases {
            let url = try FixtureFactory.makeEPUB(variant, in: directory)
            let source = StagedFileReference(identifier: UUID(), url: url)
            let report = try await auditor.audit(
                ZIPFoundationEPUBArchive(source: source),
                source: source
            )

            #expect(report.health == expectedHealth, "Unexpected health for \(variant)")
            #expect(
                expectedCodes.isSubset(of: Set(report.findings.map(\.code))),
                "Missing finding for \(variant)"
            )
        }
    }

    @Test
    func serializesNeedsReviewWithContractRawValue() throws {
        let encoded = try JSONEncoder().encode(BookHealth.needsReview)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"needs_review\"")
        #expect(
            try JSONDecoder().decode(BookHealth.self, from: encoded)
                == .needsReview
        )
    }

    @Test
    func keepsSeverityIndependentFromRepairability() {
        let automatic = HealthFinding(
            id: UUID(),
            code: .mimetypeInvalid,
            severity: .error,
            location: nil,
            messageKey: "mimetype",
            repairability: .automatic(ruleID: "repair.mimetype"),
            evidence: [:]
        )
        let manual = HealthFinding(
            id: UUID(),
            code: .referenceMissing,
            severity: .warning,
            location: nil,
            messageKey: "reference",
            repairability: .manualReview,
            evidence: [:]
        )

        #expect(
            AuditReport(
                id: UUID(),
                findings: [automatic],
                inspectedAt: Date()
            ).health == .repairable
        )
        #expect(
            AuditReport(
                id: UUID(),
                findings: [manual],
                inspectedAt: Date()
            ).health == .needsReview
        )
    }

    @Test
    func translatesUnexpectedArchiveBoundaryIntoAuditEvidence() async {
        let source = StagedFileReference(
            identifier: UUID(),
            url: URL(fileURLWithPath: "/synthetic/book.epub")
        )

        do {
            _ = try await EPUBAuditEngine().audit(
                UnexpectedAuditArchive(),
                source: source
            )
            Issue.record("Expected an unexpected audit failure")
        } catch let failure as SanitizedFailure {
            #expect(failure.family == .audit)
            #expect(failure.code == .unexpectedAudit)
            #expect(failure.evidence.phase == .structuralAudit)
            #expect(
                String(describing: failure).contains("raw-audit") == false
            )
        } catch {
            Issue.record("Expected a sanitized audit failure")
        }
    }
}

private struct UnexpectedAuditArchive: EPUBArchiveReading {
    private struct RawAuditError: Error {}

    func preflight(
        _ file: StagedFileReference,
        limits: SafetyLimits
    ) async throws -> [ArchiveEntryDescriptor] {
        throw RawAuditError()
    }

    func data(
        for path: String,
        maximumBytes: Int
    ) async throws -> Data {
        throw RawAuditError()
    }
}
