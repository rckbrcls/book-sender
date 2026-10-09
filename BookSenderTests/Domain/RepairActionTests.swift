import Foundation
import Testing
@testable import BookSender

struct RepairActionTests {
    @Test(arguments: sampleActions)
    func identifierAndCodableRoundTrip(_ action: RepairAction) throws {
        #expect(action.identifier == expectedIdentifier(action))
        let encoded = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(RepairAction.self, from: encoded)
        #expect(decoded == action)
    }

    @Test(arguments: sampleActions)
    func actionTitleCoversEveryRepairAction(_ action: RepairAction) {
        #expect(
            ItemDetailDisclosure.actionTitle(for: action) == expectedTitle(action)
        )
        #expect(ItemDetailDisclosure.actionTitle(for: action).isEmpty == false)
    }

    @Test
    func postconditionsMatchEachAction() {
        let engine = EPUBRepairEngine(
            writer: FailingArchiveWriter(
                failure: sanitizedFailure(.unexpectedRepair, family: .repair)
            ),
            workspaceStore: WorkspaceStore()
        )

        #expect(
            engine.postconditions(for: .rebuildMimetype)
                == [
                    .mimetypeMissing,
                    .mimetypeInvalid,
                    .mimetypeNotFirst,
                    .mimetypeCompressed,
                ]
        )
        #expect(
            engine.postconditions(for: .restoreContainer(packagePath: "OEBPS/content.opf"))
                == [.containerMissing, .containerInvalid, .packageMissing]
        )
        #expect(
            engine.postconditions(
                for: .correctMediaType(
                    package: "OEBPS/content.opf",
                    href: "Fonts/book.ttf",
                    from: "application/x-font-truetype",
                    to: "font/ttf"
                )
            ) == [.manifestMediaTypeMismatch]
        )
        #expect(
            engine.postconditions(for: .normalizePath(from: "A.xhtml", to: "a.xhtml"))
                == [.referenceMissing]
        )
        #expect(
            engine.postconditions(
                for: .repairReference(
                    document: "OEBPS/content.opf",
                    from: "Chapter.xhtml",
                    to: "chapter.xhtml"
                )
            ) == [.referenceMissing, .referenceAmbiguous]
        )
        #expect(
            engine.postconditions(for: .normalizeXML(path: "OEBPS/content.opf"))
                == [.containerInvalid, .packageInvalid]
        )
        #expect(
            engine.postconditions(
                for: .removeDanglingSpineItem(
                    package: "OEBPS/content.opf",
                    idref: "missing"
                )
            ) == [.referenceMissing]
        )
    }

    @Test
    func spineDiagnosticCodeBelongsToRepair() {
        #expect(DiagnosticCode.repairSpine.rawValue == "repair.spine")
        #expect(DiagnosticCode.repairSpine.expectedFamily == .repair)
    }

    private func expectedIdentifier(_ action: RepairAction) -> String {
        switch action {
        case .rebuildMimetype: "repair.mimetype"
        case .restoreContainer: "repair.container"
        case .correctMediaType: "repair.media-type"
        case .normalizePath: "repair.path"
        case .repairReference: "repair.reference"
        case .normalizeXML: "repair.xml"
        case .removeDanglingSpineItem: "repair.spine"
        }
    }

    private func expectedTitle(_ action: RepairAction) -> String {
        switch action {
        case .rebuildMimetype: "Rebuilt EPUB package marker"
        case .restoreContainer: "Restored EPUB container"
        case .correctMediaType: "Corrected resource type"
        case .normalizePath: "Normalized resource path"
        case .repairReference: "Repaired internal reference"
        case .normalizeXML: "Normalized EPUB XML"
        case .removeDanglingSpineItem: "Removed dangling spine entry"
        }
    }
}

private let sampleActions: [RepairAction] = [
    .rebuildMimetype,
    .restoreContainer(packagePath: "OEBPS/content.opf"),
    .correctMediaType(
        package: "OEBPS/content.opf",
        href: "Fonts/book.ttf",
        from: "application/x-font-truetype",
        to: "font/ttf"
    ),
    .normalizePath(from: "A.xhtml", to: "a.xhtml"),
    .repairReference(
        document: "OEBPS/content.opf",
        from: "Chapter.xhtml",
        to: "chapter.xhtml"
    ),
    .normalizeXML(path: "OEBPS/content.opf"),
    .removeDanglingSpineItem(package: "OEBPS/content.opf", idref: "missing"),
]
