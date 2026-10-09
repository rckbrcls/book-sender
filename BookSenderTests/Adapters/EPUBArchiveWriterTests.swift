import Foundation
import Testing
import ZIPFoundation
@testable import BookSender

struct EPUBArchiveWriterTests {
    @Test
    func writesFirstUncompressedMimetypeAndOnlyPlannedRestoration() async throws {
        let stores = try TestStores.make()
        defer { stores.cleanup() }
        let workspaceStore = WorkspaceStore(
            rootURL: stores.rootURL.appending(component: "work")
        )
        let batchID = UUID()
        let itemID = UUID()
        let workspace = try await workspaceStore.createWorkspace(
            batchID: batchID,
            itemID: itemID
        )
        let original = try FixtureFactory.makeEPUB(
            .missingContainer,
            in: stores.rootURL
        )
        let source = try await workspaceStore.stageReadOnlySource(
            original,
            in: workspace,
            maximumBytes: SafetyLimits.standard.maximumBookBytes
        )
        let plan = PreparationPlan(
            id: UUID(),
            originalAuditIdentifier: UUID(),
            actions: [
                .rebuildMimetype,
                .restoreContainer(packagePath: "OEBPS/content.opf"),
            ],
            decision: .writeEPUBWorkingCopy
        )

        let partial = try await EPUBArchiveWriter().write(
            source: source,
            plan: plan,
            workspace: workspace,
            limits: .standard
        )
        let archive = ZIPFoundationEPUBArchive(source: partial)
        let entries = try await archive.preflight(partial, limits: .standard)

        #expect(entries.first?.path == "mimetype")
        #expect(entries.first?.compressionMethod == 0)
        #expect(entries.contains(where: { $0.path == "META-INF/container.xml" }))
        #expect(entries.contains(where: { $0.path == "OEBPS/chapter.xhtml" }))
    }

    @Test
    func rejectsUnsupportedActionAndRemovesPartialOutput() async throws {
        let stores = try TestStores.make()
        defer { stores.cleanup() }
        let workspaceStore = WorkspaceStore(
            rootURL: stores.rootURL.appending(component: "work")
        )
        let workspace = try await workspaceStore.createWorkspace(
            batchID: UUID(),
            itemID: UUID()
        )
        let original = try FixtureFactory.makeEPUB(.validEPUB3, in: stores.rootURL)
        let source = try await workspaceStore.stageReadOnlySource(
            original,
            in: workspace,
            maximumBytes: SafetyLimits.standard.maximumBookBytes
        )
        let plan = PreparationPlan(
            id: UUID(),
            originalAuditIdentifier: UUID(),
            actions: [
                .normalizePath(
                    from: "OEBPS/chapter.xhtml",
                    to: "OEBPS/Chapter.xhtml"
                ),
            ],
            decision: .writeEPUBWorkingCopy
        )

        do {
            _ = try await EPUBArchiveWriter().write(
                source: source,
                plan: plan,
                workspace: workspace,
                limits: .standard
            )
            Issue.record("Expected unsupported repair action")
        } catch let failure as SanitizedFailure {
            #expect(failure.code == .repairUnsupportedAction)
            #expect(failure.evidence.phase == .workingCopyWrite)
            #expect(String(describing: failure).contains(source.url.path) == false)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.rootURL
                    .appending(component: "prepared.partial.epub").path
            ) == false
        )
    }

    @Test
    func cancellationBeforeWriteLeavesNoPartialOutput() async throws {
        let stores = try TestStores.make()
        defer { stores.cleanup() }
        let workspaceStore = WorkspaceStore(
            rootURL: stores.rootURL.appending(component: "work")
        )
        let workspace = try await workspaceStore.createWorkspace(
            batchID: UUID(),
            itemID: UUID()
        )
        let original = try FixtureFactory.makeEPUB(.validEPUB3, in: stores.rootURL)
        let source = try await workspaceStore.stageReadOnlySource(
            original,
            in: workspace,
            maximumBytes: SafetyLimits.standard.maximumBookBytes
        )
        let plan = PreparationPlan(
            id: UUID(),
            originalAuditIdentifier: UUID(),
            actions: [],
            decision: .writeEPUBWorkingCopy
        )
        let task = Task {
            try await EPUBArchiveWriter().write(
                source: source,
                plan: plan,
                workspace: workspace,
                limits: .standard
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.rootURL
                    .appending(component: "prepared.partial.epub").path
            ) == false
        )
    }

    @Test
    func mediaTypeSubstitutionPreservesEveryOtherByte() async throws {
        try await withStagedEPUB(.rootPackageLegacyTrueType) { harness in
            let originalDigest = try FixtureFactory.digest(of: harness.original)
            let sourceDigest = try FixtureFactory.digest(of: harness.source.url)
            let originalPackage = try await archivedText(
                "content.opf",
                in: harness.source
            )
            let partial = try await write(
                harness,
                actions: [
                    .correctMediaType(
                        package: "content.opf",
                        href: "Fonts/font-1.ttf",
                        from: "application/x-font-truetype",
                        to: "font/ttf"
                    ),
                    .correctMediaType(
                        package: "content.opf",
                        href: "Fonts/font-2.ttf",
                        from: "application/x-font-truetype",
                        to: "font/ttf"
                    ),
                ]
            )
            let edited = try await archivedText("content.opf", in: partial)
            let expected = originalPackage.replacingOccurrences(
                of: "media-type=\"application/x-font-truetype\"",
                with: "media-type=\"font/ttf\""
            )

            #expect(originalPackage != expected)
            #expect(originalPackage.contains("<!--preserve-->"))
            #expect(edited == expected)
            let sourceChapter = try await archivedData(
                "chapter.xhtml",
                in: harness.source
            )
            let preparedChapter = try await archivedData(
                "chapter.xhtml",
                in: partial
            )
            #expect(preparedChapter == sourceChapter)
            let archive = ZIPFoundationEPUBArchive(source: partial)
            let entries = try await archive.preflight(partial, limits: .standard)
            #expect(entries.first?.path == "mimetype")
            #expect(entries.first?.compressionMethod == 0)
            #expect(try FixtureFactory.digest(of: harness.original) == originalDigest)
            #expect(try FixtureFactory.digest(of: harness.source.url) == sourceDigest)
        }
    }

    @Test
    func escapesAmpersandAndQuoteInReplacedAttribute() async throws {
        try await withStagedEPUB(.rootPackageLegacyTrueType) { harness in
            let original = try await archivedText("content.opf", in: harness.source)
            let partial = try await write(
                harness,
                actions: [
                    .correctMediaType(
                        package: "content.opf",
                        href: "Fonts/font-1.ttf",
                        from: "application/x-font-truetype",
                        to: "a&b\"c"
                    ),
                ]
            )
            let sourceItem = """
            <item id="font-1" href="Fonts/font-1.ttf" media-type="application/x-font-truetype"/>
            """
            let expectedItem = """
            <item id="font-1" href="Fonts/font-1.ttf" media-type="a&amp;b&quot;c"/>
            """
            let expected = original.replacingOccurrences(
                of: sourceItem,
                with: expectedItem
            )
            let edited = try await archivedText("content.opf", in: partial)
            #expect(edited.contains("media-type=\"application/x-font-truetype\""))
            #expect(edited == expected)
        }
    }

    @Test
    func rejectsMismatchedAttributeAndMissingTarget() async throws {
        try await expectPrecondition(
            .rootPackageLegacyTrueType,
            actions: [
                .correctMediaType(
                    package: "content.opf",
                    href: "Fonts/font-1.ttf",
                    from: "font/ttf",
                    to: "font/ttf"
                ),
            ]
        )
        try await expectPrecondition(
            .danglingSpineItem,
            actions: [
                .removeDanglingSpineItem(
                    package: "OEBPS/content.opf",
                    idref: "absent"
                ),
            ]
        )
        try await expectPrecondition(
            .validEPUB3,
            actions: [.normalizeXML(path: "OEBPS/missing.opf")]
        )
    }

    @Test
    func rejectsOPFAboveXMLByteLimit() async throws {
        try await withStagedEPUB(.validEPUB3) { harness in
            let limits = makeSafetyLimits(maximumXMLBytes: 32)
            do {
                _ = try await EPUBArchiveWriter().write(
                    source: harness.source,
                    plan: plan([
                        .normalizeXML(path: "OEBPS/content.opf"),
                    ]),
                    workspace: harness.workspace,
                    limits: limits
                )
                Issue.record("Expected an oversized OPF to fail")
            } catch let failure as SanitizedFailure {
                #expect(failure.code == .repairXML)
            }
            #expect(harness.partialExists() == false)
        }
    }

    @Test
    func timeoutRemovesPartialOutput() async throws {
        try await withStagedEPUB(.validEPUB3) { harness in
            let limits = makeSafetyLimits(operationTimeout: .zero)
            do {
                _ = try await EPUBArchiveWriter().write(
                    source: harness.source,
                    plan: plan([.rebuildMimetype]),
                    workspace: harness.workspace,
                    limits: limits
                )
                Issue.record("Expected the working-copy write to time out")
            } catch let failure as SanitizedFailure {
                #expect(failure.code == .repairTimeout)
            }
            #expect(harness.partialExists() == false)
        }
    }

    @Test
    func multipleActionsOnOneFileComposeWithoutReserializing() async throws {
        let package = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\">",
            "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
            "    <dc:identifier id=\"book-id\">fixture</dc:identifier>",
            "    <dc:title>Keep &amp; this</dc:title>",
            "    <dc:language>en</dc:language>",
            "  </metadata>",
            "  <!--preserve-->",
            "  <manifest>",
            "    <item id=\"chapter\" href=\"Chapter.xhtml\" media-type=\"application/xhtml+xml\"/>",
            "    <item id=\"font-1\" href=\"Fonts/font-1.ttf\" media-type=\"application/x-font-truetype\"/>",
            "    <item id=\"font-2\" href=\"Fonts/font-2.ttf\" media-type='application/x-font-truetype'/>",
            "  </manifest>",
            "  <spine><itemref idref=\"chapter\"/><itemref idref=\"missing\"/></spine>",
            "</package>",
        ].joined(separator: "\n")
        let expected = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\">",
            "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
            "    <dc:identifier id=\"book-id\">fixture</dc:identifier>",
            "    <dc:title>Keep &amp; this</dc:title>",
            "    <dc:language>en</dc:language>",
            "  </metadata>",
            "  <!--preserve-->",
            "  <manifest>",
            "    <item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>",
            "    <item id=\"font-1\" href=\"Fonts/font-1.ttf\" media-type=\"a&amp;b&quot;c\"/>",
            "    <item id=\"font-2\" href=\"Fonts/font-2.ttf\" media-type='a&amp;b&quot;c'/>",
            "  </manifest>",
            "  <spine><itemref idref=\"chapter\"/></spine>",
            "</package>",
        ].joined(separator: "\n")
        let prefixed = Data([0xEF, 0xBB, 0xBF, 0x20, 0x0A]) + Data(package.utf8)

        try await withStagedEPUB(file: { directory in
            try makeZIP(
                entries: [
                    ("mimetype", Data("application/epub+zip".utf8)),
                    ("META-INF/container.xml", Data(containerXML("content.opf").utf8)),
                    ("content.opf", prefixed),
                    ("chapter.xhtml", Data("<html/>".utf8)),
                    ("Fonts/font-1.ttf", Data([0x00, 0x01, 0x00, 0x00])),
                    ("Fonts/font-2.ttf", Data([0x00, 0x01, 0x00, 0x00])),
                ],
                in: directory
            )
        }) { harness in
            let originalDigest = try FixtureFactory.digest(of: harness.original)
            let partial = try await write(
                harness,
                actions: [
                    .normalizeXML(path: "content.opf"),
                    .repairReference(
                        document: "content.opf",
                        from: "Chapter.xhtml",
                        to: "chapter.xhtml"
                    ),
                    .correctMediaType(
                        package: "content.opf",
                        href: "Fonts/font-1.ttf",
                        from: "application/x-font-truetype",
                        to: "a&b\"c"
                    ),
                    .correctMediaType(
                        package: "content.opf",
                        href: "Fonts/font-2.ttf",
                        from: "application/x-font-truetype",
                        to: "a&b\"c"
                    ),
                    .removeDanglingSpineItem(
                        package: "content.opf",
                        idref: "missing"
                    ),
                ]
            )
            #expect(try await archivedText("content.opf", in: partial) == expected)
            #expect(try FixtureFactory.digest(of: harness.original) == originalDigest)
        }
    }

    @Test
    func rewritesEachLegacyFontAliasInPlace() async throws {
        try await withStagedEPUB(.legacyFontAliases) { harness in
            let original = try await archivedText(
                "OEBPS/content.opf",
                in: harness.source
            )
            let partial = try await write(
                harness,
                actions: [
                    .correctMediaType(
                        package: "OEBPS/content.opf",
                        href: "Fonts/book.ttf",
                        from: "application/x-font-truetype",
                        to: "font/ttf"
                    ),
                    .correctMediaType(
                        package: "OEBPS/content.opf",
                        href: "Fonts/book.otf",
                        from: "application/x-font-otf",
                        to: "font/otf"
                    ),
                    .correctMediaType(
                        package: "OEBPS/content.opf",
                        href: "Fonts/book-opentype.otf",
                        from: "application/x-font-opentype",
                        to: "font/otf"
                    ),
                    .correctMediaType(
                        package: "OEBPS/content.opf",
                        href: "Fonts/book-ms.otf",
                        from: "application/vnd.ms-opentype",
                        to: "font/otf"
                    ),
                    .correctMediaType(
                        package: "OEBPS/content.opf",
                        href: "Fonts/book.woff",
                        from: "application/font-woff",
                        to: "font/woff"
                    ),
                ]
            )
            var expected = original
            let replacements = [
                ("media-type=\"application/x-font-truetype\"", "media-type=\"font/ttf\""),
                ("media-type=\"application/x-font-opentype\"", "media-type=\"font/otf\""),
                ("media-type=\"application/x-font-otf\"", "media-type=\"font/otf\""),
                ("media-type=\"application/vnd.ms-opentype\"", "media-type=\"font/otf\""),
                ("media-type=\"application/font-woff\"", "media-type=\"font/woff\""),
            ]
            for (source, replacement) in replacements {
                expected = expected.replacingOccurrences(of: source, with: replacement)
            }
            let edited = try await archivedText("OEBPS/content.opf", in: partial)
            #expect(edited.contains("<!--preserve-->"))
            #expect(edited == expected)
        }
    }

    @Test
    func rewritesSingleCanonicalReference() async throws {
        try await withStagedEPUB(.referenceCaseDifference) { harness in
            let original = try await archivedText(
                "OEBPS/content.opf",
                in: harness.source
            )
            let partial = try await write(
                harness,
                actions: [
                    .repairReference(
                        document: "OEBPS/content.opf",
                        from: FixtureFactory.canonicalReferenceHref,
                        to: FixtureFactory.canonicalReferenceFilename
                    ),
                ]
            )
            let expected = original.replacingOccurrences(
                of: "href=\"\(FixtureFactory.canonicalReferenceHref)\"",
                with: "href=\"\(FixtureFactory.canonicalReferenceFilename)\""
            )
            #expect(original != expected)
            #expect(try await archivedText("OEBPS/content.opf", in: partial) == expected)
        }
    }

    @Test
    func removesOnlyTheDanglingSpineItem() async throws {
        try await withStagedEPUB(.danglingSpineItem) { harness in
            let original = try await archivedText(
                "OEBPS/content.opf",
                in: harness.source
            )
            let partial = try await write(
                harness,
                actions: [
                    .removeDanglingSpineItem(
                        package: "OEBPS/content.opf",
                        idref: FixtureFactory.danglingSpineIDRef
                    ),
                ]
            )
            let expected = original.replacingOccurrences(
                of: "<itemref idref=\"\(FixtureFactory.danglingSpineIDRef)\"/>",
                with: ""
            )
            let edited = try await archivedText("OEBPS/content.opf", in: partial)
            #expect(edited.contains("<itemref idref=\"chapter\"/>"))
            #expect(edited.contains(FixtureFactory.danglingSpineIDRef) == false)
            #expect(edited == expected)
        }
    }

    @Test
    func stripsLeadingBOMAndWhitespaceBeforeXMLDeclaration() async throws {
        try await withStagedEPUB(.packageLeadingBOM) { harness in
            let original = try await archivedData(
                "OEBPS/content.opf",
                in: harness.source
            )
            let prefix = Data([0xEF, 0xBB, 0xBF, 0x20, 0x0A])
            let partial = try await write(
                harness,
                actions: [.normalizeXML(path: "OEBPS/content.opf")]
            )
            let edited = try await archivedData("OEBPS/content.opf", in: partial)
            #expect(original.starts(with: prefix))
            #expect(edited == original.dropFirst(prefix.count))
        }
    }

    @Test
    func restoresContainerWhenTheOnlyPackageRemains() async throws {
        try await withStagedEPUB(.containerInvalidSinglePackage) { harness in
            let originalPackage = try await archivedData(
                "OEBPS/content.opf",
                in: harness.source
            )
            let partial = try await write(
                harness,
                actions: [.restoreContainer(packagePath: "OEBPS/content.opf")]
            )
            let archive = ZIPFoundationEPUBArchive(source: partial)
            let entries = try await archive.preflight(partial, limits: .standard)
            let container = try await archivedText(
                "META-INF/container.xml",
                in: partial
            )
            #expect(entries.first?.path == "mimetype")
            #expect(entries.first?.compressionMethod == 0)
            #expect(container.contains("full-path=\"OEBPS/content.opf\""))
            #expect(container.contains("not-container") == false)
            #expect(
                try await archivedData("OEBPS/content.opf", in: partial)
                    == originalPackage
            )
        }
    }
}

private struct WriterHarness {
    let workspace: WorkspaceReference
    let original: URL
    let source: StagedFileReference

    func partialExists() -> Bool {
        FileManager.default.fileExists(
            atPath: workspace.rootURL
                .appending(component: "prepared.partial.epub").path
        )
    }
}

private func withStagedEPUB(
    _ variant: FixtureFactory.EPUBVariant,
    _ body: (WriterHarness) async throws -> Void
) async throws {
    try await withStagedEPUB(
        file: { try FixtureFactory.makeEPUB(variant, in: $0) },
        body
    )
}

private func withStagedEPUB(
    file makeFile: (URL) throws -> URL,
    _ body: (WriterHarness) async throws -> Void
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
    let original = try makeFile(stores.rootURL)
    let source = try await workspaceStore.stageReadOnlySource(
        original,
        in: workspace,
        maximumBytes: SafetyLimits.standard.maximumBookBytes
    )
    let harness = WriterHarness(
        workspace: workspace,
        original: original,
        source: source
    )
    try await body(harness)
}

private func plan(_ actions: [RepairAction]) -> PreparationPlan {
    PreparationPlan(
        id: UUID(),
        originalAuditIdentifier: UUID(),
        actions: actions,
        decision: .writeEPUBWorkingCopy
    )
}

private func write(
    _ harness: WriterHarness,
    actions: [RepairAction],
    limits: SafetyLimits = .standard
) async throws -> StagedFileReference {
    try await EPUBArchiveWriter().write(
        source: harness.source,
        plan: plan(actions),
        workspace: harness.workspace,
        limits: limits
    )
}

private func expectPrecondition(
    _ variant: FixtureFactory.EPUBVariant,
    actions: [RepairAction]
) async throws {
    try await withStagedEPUB(variant) { harness in
        let originalDigest = try FixtureFactory.digest(of: harness.original)
        do {
            _ = try await write(harness, actions: actions)
            Issue.record("Expected a repair precondition failure")
        } catch let failure as SanitizedFailure {
            #expect(failure.code == .repairPrecondition)
        }
        #expect(harness.partialExists() == false)
        #expect(try FixtureFactory.digest(of: harness.original) == originalDigest)
    }
}

private func archivedData(
    _ path: String,
    in file: StagedFileReference
) async throws -> Data {
    let archive = ZIPFoundationEPUBArchive(source: file)
    _ = try await archive.preflight(file, limits: .standard)
    return try await archive.data(
        for: path,
        maximumBytes: SafetyLimits.standard.maximumXMLBytes
    )
}

private func archivedText(
    _ path: String,
    in file: StagedFileReference
) async throws -> String {
    let data = try await archivedData(path, in: file)
    let text = String(decoding: data, as: UTF8.self)
    return text
}

private func containerXML(_ packagePath: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="\(packagePath)" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """
}

private func makeZIP(
    entries: [(String, Data)],
    in directory: URL
) throws -> URL {
    let url = directory.appending(component: "composed.epub")
    let archive = try Archive(url: url, accessMode: .create)
    let date = Date(timeIntervalSince1970: 978_307_200)
    for (path, data) in entries {
        let bytes = data
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(bytes.count),
            modificationDate: date,
            compressionMethod: .none,
            provider: { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }
    return url
}
