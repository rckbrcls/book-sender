import Foundation
import Testing
@testable import BookSender

struct EPUBAuditRuleTests {
    @Test
    func everyLegacyAliasRepairsWithoutConfirmingBytes() async throws {
        for alias in legacyAliases {
            let finding = try await mediaTypeFinding(
                href: alias.href,
                declared: alias.declared,
                bytes: Data("not-a-matching-signature".utf8)
            )
            #expect(
                ruleID(finding) == "repair.media-type",
                "Expected automatic repair for \(alias.declared)"
            )
            #expect(finding?.evidence["package"] == "OEBPS/content.opf")
            #expect(finding?.evidence["href"] == alias.href)
            #expect(finding?.evidence["declared"] == alias.declared)
            #expect(finding?.evidence["expected"] == alias.expected)
        }
    }

    @Test
    func alreadyCompatibleLegacyTypesStayHealthy() async throws {
        let accepted = [
            ("Fonts/book.ttf", "application/x-font-ttf"),
            ("Fonts/book.ttf", "application/font-sfnt"),
            ("Fonts/book.otf", "application/x-font-opentype"),
            ("Fonts/book.otf", "application/vnd.ms-opentype"),
            ("Fonts/book.woff", "application/font-woff"),
            ("Fonts/book.woff", "application/x-font-woff"),
        ]
        for (href, declared) in accepted {
            let report = try await auditResource(
                href: href,
                declared: declared,
                bytes: Data("legacy".utf8)
            )
            #expect(
                report.findings.contains { $0.code == .manifestMediaTypeMismatch } == false,
                "Unexpected mismatch for \(declared)"
            )
            #expect(report.health == .healthy, "Unexpected health for \(declared)")
        }
    }

    @Test
    func unknownMediaTypeWithoutConfirmationStaysManual() async throws {
        let finding = try await mediaTypeFinding(
            href: "styles/book.css",
            declared: "text/plain",
            bytes: Data("body { color: black; }".utf8)
        )
        #expect(finding?.repairability == .manualReview)
        #expect(ruleID(finding) == nil)
    }

    @Test
    func magicBytesConfirmRepairAndDisagreementStaysManual() async throws {
        let automatic: [(String, String, Data, String)] = [
            ("cover.jpg", "application/octet-stream", jpeg, "image/jpeg"),
            ("cover.png", "application/octet-stream", png, "image/png"),
            ("cover.gif", "application/octet-stream", Data("GIF89a".utf8), "image/gif"),
            ("cover.gif", "application/octet-stream", Data("GIF87a".utf8), "image/gif"),
            ("Fonts/book.ttf", "application/octet-stream", ttf, "font/ttf"),
            ("Fonts/book.ttf", "application/octet-stream", Data("true".utf8), "font/ttf"),
            ("Fonts/book.otf", "application/octet-stream", Data("OTTO".utf8), "font/otf"),
        ]
        for (href, declared, bytes, expected) in automatic {
            let finding = try await mediaTypeFinding(
                href: href,
                declared: declared,
                bytes: bytes
            )
            #expect(ruleID(finding) == "repair.media-type", "Expected repair for \(href)")
            #expect(finding?.evidence["expected"] == expected)
            #expect(finding?.evidence["href"] == href)
        }

        let manual: [(String, String, Data)] = [
            ("cover.jpg", "application/octet-stream", Data([0xFF, 0xD8])),
            ("cover.jpg", "application/octet-stream", Data([0x00, 0x11, 0x22, 0x33])),
            ("cover.png", "application/octet-stream", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A])),
            ("Fonts/book.ttf", "application/octet-stream", Data([0x00, 0x01])),
            ("Fonts/book.ttf", "application/octet-stream", Data("OTTO".utf8)),
            ("Fonts/book.otf", "application/octet-stream", ttf),
            ("chapter.xhtml", "application/octet-stream", png),
        ]
        for (href, declared, bytes) in manual {
            let finding = try await mediaTypeFinding(
                href: href,
                declared: declared,
                bytes: bytes
            )
            #expect(
                finding?.repairability == .manualReview,
                "Expected manual review for \(href)"
            )
        }
    }

    @Test
    func wellFormedXMLConfirmsMarkupButImageDeclarationStaysManual() async throws {
        let confirmed = try await mediaTypeFinding(
            href: "chapter.xhtml",
            declared: "application/octet-stream",
            bytes: xhtml
        )
        #expect(ruleID(confirmed) == "repair.media-type")
        #expect(confirmed?.evidence["expected"] == "application/xhtml+xml")

        let html = try await mediaTypeFinding(
            href: "page.html",
            declared: "application/octet-stream",
            bytes: xhtml
        )
        #expect(html?.evidence["expected"] == "application/xhtml+xml")

        let ncx = try await mediaTypeFinding(
            href: "toc.ncx",
            declared: "application/octet-stream",
            bytes: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><head></head></ncx>
            """.utf8)
        )
        #expect(ruleID(ncx) == "repair.media-type")
        #expect(ncx?.evidence["expected"] == "application/x-dtbncx+xml")

        let report = try await auditResource(
            href: "chapter.xhtml",
            declared: "image/png",
            bytes: xhtml
        )
        let finding = report.findings.first { $0.code == .manifestMediaTypeMismatch }
        #expect(report.health == .needsReview)
        #expect(finding?.repairability == .manualReview)
        #expect(finding?.evidence["declared"] == "image/png")
        #expect(finding?.evidence["package"] == nil)
    }

    @Test
    func singleReferenceCandidateRepairsAndAmbiguityStaysManual() async throws {
        let caseMatch = try await referenceReport(
            href: "Chapter.xhtml",
            files: ["OEBPS/chapter.xhtml": Data("x".utf8)]
        )
        let caseFinding = try #require(
            caseMatch.findings.first { $0.code == .referenceMissing }
        )
        #expect(ruleID(caseFinding) == "repair.reference")
        #expect(caseFinding.evidence["package"] == "OEBPS/content.opf")
        #expect(caseFinding.evidence["from"] == "Chapter.xhtml")
        #expect(caseFinding.evidence["to"] == "chapter.xhtml")

        let composed = "OEBPS/caf\u{00E9}.xhtml"
        let decomposed = "caf\u{0065}\u{0301}.xhtml"
        let canonical = try await referenceReport(
            href: decomposed,
            files: [composed: Data("x".utf8)]
        )
        let canonicalFinding = try #require(
            canonical.findings.first { $0.code == .referenceMissing }
        )
        #expect(ruleID(canonicalFinding) == "repair.reference")
        #expect(canonicalFinding.evidence["from"] == decomposed)
        #expect(canonicalFinding.evidence["to"] == "caf\u{00E9}.xhtml")

        let basename = try await referenceReport(
            href: "text/chapter.xhtml",
            files: ["OEBPS/chapter.xhtml": Data("x".utf8)]
        )
        let basenameFinding = try #require(
            basename.findings.first { $0.code == .referenceMissing }
        )
        #expect(ruleID(basenameFinding) == "repair.reference")
        #expect(basenameFinding.evidence["from"] == "text/chapter.xhtml")
        #expect(basenameFinding.evidence["to"] == "chapter.xhtml")

        let manyBasenames = try await referenceReport(
            href: "text/chapter.xhtml",
            files: [
                "OEBPS/one/chapter.xhtml": Data("x".utf8),
                "OEBPS/two/chapter.xhtml": Data("x".utf8),
            ]
        )
        #expect(
            manyBasenames.findings.contains {
                $0.code == .referenceAmbiguous && $0.repairability == .manualReview
            }
        )

        let manyCanonical = try await referenceReport(
            href: "CHAPTER.xhtml",
            files: [
                "OEBPS/Chapter.xhtml": Data("x".utf8),
                "OEBPS/chapter.xhtml": Data("x".utf8),
            ]
        )
        #expect(
            manyCanonical.findings.contains {
                $0.code == .referenceAmbiguous && $0.repairability == .manualReview
            }
        )

        let none = try await referenceReport(
            href: "missing.xhtml",
            files: [:]
        )
        #expect(
            none.findings.contains {
                $0.code == .referenceMissing && $0.repairability == .manualReview
            }
        )
        #expect(none.findings.contains { ruleID($0) == "repair.reference" } == false)
    }

    @Test
    func danglingSpineItemRepairsOnlyWhenAnotherItemRemains() async throws {
        let repaired = try await spineReport(
            spine: #"<itemref idref="chapter"/><itemref idref="missing"/>"#
        )
        let dangling = try #require(
            repaired.findings.first { ruleID($0) == "repair.spine" }
        )
        #expect(repaired.health == .repairable)
        #expect(dangling.evidence["package"] == "OEBPS/content.opf")
        #expect(dangling.evidence["idref"] == "missing")
        #expect(dangling.code == .referenceMissing)

        let blocked = try await spineReport(
            spine: #"<itemref idref="missing"/>"#
        )
        #expect(blocked.health == .needsReview)
        #expect(
            blocked.findings.contains {
                $0.code == .referenceMissing && $0.repairability == .manualReview
            }
        )
        #expect(blocked.findings.contains { ruleID($0) == "repair.spine" } == false)

        let missingAttribute = try await spineReport(
            spine: #"<itemref idref="chapter"/><itemref/>"#
        )
        #expect(
            missingAttribute.findings.contains {
                $0.code == .referenceMissing && $0.repairability == .manualReview
            }
        )
    }

    @Test
    func invalidContainerRepairsOnlyWhenExactlyOnePackageExists() async throws {
        let counts = [0, 1, 2]
        for count in counts {
            let report = try await containerReport(
                container: Data("<container><rootfiles>".utf8),
                packagePaths: (0..<count).map { "OEBPS/book-\($0).opf" }
            )
            let finding = try #require(
                report.findings.first { $0.code == .containerInvalid }
            )
            if count == 1 {
                #expect(ruleID(finding) == "repair.container")
                #expect(finding.evidence["package"] == "OEBPS/book-0.opf")
                #expect(report.health == .repairable)
            } else {
                #expect(finding.repairability == .manualReview)
                #expect(report.health == .needsReview)
            }
        }

        let wrongRoot = try await containerReport(
            container: Data(
                "<?xml version=\"1.0\"?><wrapper/>".utf8
            ),
            packagePaths: ["OEBPS/content.opf"]
        )
        #expect(
            wrongRoot.findings.contains {
                $0.code == .containerInvalid && ruleID($0) == "repair.container"
                    && $0.evidence["package"] == "OEBPS/content.opf"
            }
        )
    }

    @Test
    func missingRootfileRepairsOnlyWhenExactlyOnePackageExists() async throws {
        let none = try await rootfileReport(packagePaths: [])
        #expect(
            none.findings.contains {
                $0.code == .packageMissing && $0.repairability == .notApplicable
            }
        )
        #expect(none.health == .unsupported)

        let one = try await rootfileReport(packagePaths: ["OEBPS/content.opf"])
        let repaired = try #require(
            one.findings.first { $0.code == .packageMissing }
        )
        #expect(ruleID(repaired) == "repair.container")
        #expect(repaired.evidence["package"] == "OEBPS/content.opf")
        #expect(one.health == .repairable)

        let many = try await rootfileReport(
            packagePaths: ["OEBPS/one.opf", "OEBPS/two.opf"]
        )
        #expect(
            many.findings.contains {
                $0.code == .packageMissing && $0.repairability == .manualReview
            }
        )
        #expect(many.health == .needsReview)
    }

    @Test
    func xmlPrefixRepairsOnlyWhenStrippingMakesTheDocumentParse() async throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let container = try await audit(
            archive(
                container: bom + Data("<?xml version=\"1.0\"?><container></container>".utf8),
                package: Data("<?xml version=\"1.0\"?><package></package>".utf8),
                files: ["OEBPS/chapter.xhtml": Data("x".utf8)]
            ),
            parser: ScriptedXMLParser()
        )
        #expect(
            container.findings.contains {
                ruleID($0) == "repair.xml"
                    && $0.evidence["path"] == "META-INF/container.xml"
                    && $0.code == .containerInvalid
            }
        )
        #expect(container.findings.contains { ruleID($0) == "repair.container" } == false)

        let spacedPackage = try await audit(
            archive(
                container: Data("<?xml version=\"1.0\"?><container></container>".utf8),
                package: Data("\t\r\n<?xml version=\"1.0\"?><package></package>".utf8),
                files: ["OEBPS/chapter.xhtml": Data("x".utf8)]
            ),
            parser: ScriptedXMLParser()
        )
        #expect(
            spacedPackage.findings.contains {
                ruleID($0) == "repair.xml"
                    && $0.evidence["path"] == "OEBPS/content.opf"
                    && $0.code == .packageInvalid
            }
        )

        let stillBroken = try await audit(
            archive(
                container: bom + Data(
                    "<?xml version=\"1.0\"?><container>BROKEN</container>".utf8
                ),
                package: Data("<?xml version=\"1.0\"?><package></package>".utf8),
                files: ["OEBPS/chapter.xhtml": Data("x".utf8)]
            ),
            parser: ScriptedXMLParser()
        )
        #expect(stillBroken.findings.contains { ruleID($0) == "repair.xml" } == false)
        #expect(
            stillBroken.findings.contains {
                ruleID($0) == "repair.container"
                    && $0.evidence["package"] == "OEBPS/content.opf"
            }
        )

        let acceptedPrefix = try await audit(
            archive(
                container: bom + Data("<?xml version=\"1.0\"?><container></container>".utf8),
                package: Data("<?xml version=\"1.0\"?><package></package>".utf8),
                files: ["OEBPS/chapter.xhtml": Data("x".utf8)]
            ),
            parser: ScriptedXMLParser(acceptPrefix: true)
        )
        #expect(acceptedPrefix.findings.contains { ruleID($0) == "repair.xml" } == false)
        #expect(acceptedPrefix.health == .healthy)
    }

    @Test
    func unsafeRemoteAndActiveFindingsStayForbidden() async throws {
        let unsafe = try await audit(
            archive(
                container: Data("<!DOCTYPE container><container></container>".utf8),
                package: Data("<?xml version=\"1.0\"?><package></package>".utf8),
                files: ["OEBPS/content.opf": Data("ignored".utf8)]
            ),
            parser: ScriptedXMLParser()
        )
        #expect(unsafe.health == .unsafe)
        #expect(
            unsafe.findings.contains {
                $0.code == .xmlUnsafe && $0.repairability == .forbidden
            }
        )

        let bomAndDoctype = Data([0xEF, 0xBB, 0xBF]) + Data(
            "<!DOCTYPE container><container></container>".utf8
        )
        let prefixedUnsafe = try await audit(
            archive(
                container: bomAndDoctype,
                package: Data("<?xml version=\"1.0\"?><package></package>".utf8)
            ),
            parser: ScriptedXMLParser()
        )
        #expect(prefixedUnsafe.health == .unsafe)
        #expect(prefixedUnsafe.findings.contains { ruleID($0) == "repair.xml" } == false)

        let remote = try await referenceReport(
            href: "https://example.invalid/chapter.xhtml",
            files: [:]
        )
        #expect(
            remote.findings.contains {
                $0.code == .remoteReference && $0.repairability == .forbidden
            }
        )
        #expect(remote.health == .unsafe)

        let active = try await auditResource(
            href: "script.js",
            declared: "text/javascript",
            bytes: Data("document.body.textContent = 'x';".utf8)
        )
        #expect(
            active.findings.contains {
                $0.code == .activeContent && $0.repairability == .forbidden
            }
        )
        #expect(active.health == .unsafe)

        let duplicates = try await packageReport(
            manifest: """
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="chapter" href="other.xhtml" media-type="application/xhtml+xml"/>
            """,
            spine: #"<itemref idref="chapter"/>"#,
            files: [
                "OEBPS/chapter.xhtml": Data("x".utf8),
                "OEBPS/other.xhtml": Data("x".utf8),
            ]
        )
        #expect(
            duplicates.findings.contains {
                $0.code == .packageInvalid && $0.repairability == .manualReview
            }
        )
    }

    private func mediaTypeFinding(
        href: String,
        declared: String,
        bytes: Data
    ) async throws -> HealthFinding? {
        let report = try await auditResource(
            href: href,
            declared: declared,
            bytes: bytes
        )
        return report.findings.first { $0.code == .manifestMediaTypeMismatch }
    }

    private func auditResource(
        href: String,
        declared: String,
        bytes: Data
    ) async throws -> AuditReport {
        try await packageReport(
            manifest: """
            <item id="resource" href="\(href)" media-type="\(declared)"/>
            """,
            spine: #"<itemref idref="resource"/>"#,
            files: ["OEBPS/\(href)": bytes]
        )
    }

    private func referenceReport(
        href: String,
        files: [String: Data]
    ) async throws -> AuditReport {
        try await packageReport(
            manifest: """
            <item id="chapter" href="\(href)" media-type="application/xhtml+xml"/>
            """,
            spine: #"<itemref idref="chapter"/>"#,
            files: files
        )
    }

    private func spineReport(spine: String) async throws -> AuditReport {
        try await packageReport(
            manifest: """
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            """,
            spine: spine,
            files: ["OEBPS/chapter.xhtml": Data("x".utf8)]
        )
    }

    private func packageReport(
        manifest: String,
        spine: String,
        files: [String: Data]
    ) async throws -> AuditReport {
        let package = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>\(manifest)</manifest>
          <spine>\(spine)</spine>
        </package>
        """.utf8)
        return try await audit(
            archive(
                container: containerXML(packagePath: "OEBPS/content.opf"),
                package: package,
                files: files
            )
        )
    }

    private func containerReport(
        container: Data,
        packagePaths: [String]
    ) async throws -> AuditReport {
        var files: [String: Data] = [:]
        for path in packagePaths {
            files[path] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """.utf8)
        }
        if packagePaths.count == 1 {
            files["OEBPS/chapter.xhtml"] = Data("x".utf8)
        }
        return try await audit(
            archive(container: container, package: nil, files: files)
        )
    }

    private func rootfileReport(packagePaths: [String]) async throws -> AuditReport {
        var files: [String: Data] = [:]
        for path in packagePaths {
            files[path] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """.utf8)
        }
        if packagePaths == ["OEBPS/content.opf"] {
            files["OEBPS/chapter.xhtml"] = Data("x".utf8)
        }
        return try await audit(
            archive(
                container: containerXML(packagePath: "OEBPS/missing.opf"),
                package: nil,
                files: files
            )
        )
    }

    private func audit(
        _ archive: MemoryEPUBArchive,
        parser: any BoundedXMLParsing = BoundedXMLParser()
    ) async throws -> AuditReport {
        try await EPUBAuditEngine(xmlParser: parser).audit(
            archive,
            source: StagedFileReference(
                identifier: UUID(),
                url: URL(fileURLWithPath: "/synthetic/book.epub")
            )
        )
    }

    private func ruleID(_ finding: HealthFinding?) -> String? {
        guard let finding else { return nil }
        if case .automatic(let ruleID) = finding.repairability {
            return ruleID
        }
        return nil
    }
}

private struct AliasCase: Sendable {
    let href: String
    let declared: String
    let expected: String
}

private let legacyAliases: [AliasCase] = [
    AliasCase(href: "Fonts/book.ttf", declared: "application/x-font-truetype", expected: "font/ttf"),
    AliasCase(href: "Fonts/book.ttf", declared: "application/font-truetype", expected: "font/ttf"),
    AliasCase(href: "Fonts/book.ttf", declared: "font/truetype", expected: "font/ttf"),
    AliasCase(href: "Fonts/book.otf", declared: "application/x-font-otf", expected: "font/otf"),
    AliasCase(href: "Fonts/book.otf", declared: "application/font-opentype", expected: "font/otf"),
    AliasCase(href: "Fonts/book.otf", declared: "font/opentype", expected: "font/otf"),
    AliasCase(href: "Fonts/book.woff", declared: "application/x-woff", expected: "font/woff"),
    AliasCase(href: "Fonts/book.woff", declared: "font/x-woff", expected: "font/woff"),
    AliasCase(href: "Fonts/book.woff2", declared: "application/font-woff", expected: "font/woff2"),
    AliasCase(href: "Fonts/book.woff2", declared: "application/x-font-woff", expected: "font/woff2"),
    AliasCase(href: "Fonts/book.woff2", declared: "application/font-woff2", expected: "font/woff2"),
    AliasCase(href: "Fonts/book.woff2", declared: "application/x-font-woff2", expected: "font/woff2"),
    AliasCase(href: "Fonts/book.woff2", declared: "font/x-woff2", expected: "font/woff2"),
    AliasCase(href: "cover.jpg", declared: "image/jpg", expected: "image/jpeg"),
    AliasCase(href: "cover.jpg", declared: "image/pjpeg", expected: "image/jpeg"),
    AliasCase(href: "cover.png", declared: "image/x-png", expected: "image/png"),
    AliasCase(href: "cover.gif", declared: "image/x-gif", expected: "image/gif"),
]

private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
private let ttf = Data([0x00, 0x01, 0x00, 0x00])
private let xhtml = Data("""
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Book Sender fixture.</p></body></html>
""".utf8)

private func containerXML(packagePath: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="\(packagePath)" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """.utf8)
}

private func archive(
    container: Data,
    package: Data?,
    packagePath: String = "OEBPS/content.opf",
    files: [String: Data] = [:]
) -> MemoryEPUBArchive {
    var entries = [
        MemoryEntry(path: "mimetype", data: Data("application/epub+zip".utf8)),
        MemoryEntry(path: "META-INF/container.xml", data: container),
    ]
    if let package {
        entries.append(MemoryEntry(path: packagePath, data: package))
    }
    for (path, data) in files.sorted(by: { $0.key < $1.key }) where path != packagePath {
        entries.append(MemoryEntry(path: path, data: data))
    }
    return MemoryEPUBArchive(entries: entries)
}

private struct MemoryEntry: Sendable {
    let path: String
    let data: Data
}

private struct MemoryEPUBArchive: EPUBArchiveReading, Sendable {
    let entries: [MemoryEntry]

    func preflight(
        _ file: StagedFileReference,
        limits: SafetyLimits
    ) async throws -> [ArchiveEntryDescriptor] {
        entries.map { entry in
            ArchiveEntryDescriptor(
                path: entry.path,
                compressedSize: Int64(entry.data.count),
                uncompressedSize: Int64(entry.data.count),
                compressionMethod: 0,
                isDirectory: false,
                isEncrypted: false
            )
        }
    }

    func data(for path: String, maximumBytes: Int) async throws -> Data {
        guard let data = entries.first(where: { $0.path == path })?.data,
              data.count <= maximumBytes
        else {
            throw SanitizedFailure(
                family: .archive,
                code: .archiveEntryUnavailable,
                message: "The archive entry is unavailable.",
                recoveryAction: .reviewBook
            )
        }
        return data
    }
}

private struct ScriptedXMLParser: BoundedXMLParsing, Sendable {
    var acceptPrefix = false

    func parse(
        _ data: Data,
        limits: SafetyLimits
    ) async throws -> XMLDocumentProjection {
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("<!DOCTYPE") {
            throw xmlFailure(.xmlExternalEntity)
        }
        if !acceptPrefix && hasRejectedPrefix(data) {
            throw xmlFailure(.xmlInvalid)
        }
        if text.contains("BROKEN") {
            throw xmlFailure(.xmlInvalid)
        }
        if text.contains("<container") {
            return XMLDocumentProjection(
                rootName: "container",
                namespaces: [:],
                elements: [
                    XMLElementProjection(
                        name: "rootfile",
                        path: ["container", "rootfiles", "rootfile"],
                        attributes: ["full-path": "OEBPS/content.opf"],
                        text: ""
                    ),
                ]
            )
        }
        if text.contains("<package") {
            return XMLDocumentProjection(
                rootName: "package",
                namespaces: [:],
                elements: [
                    XMLElementProjection(
                        name: "item",
                        path: ["package", "manifest", "item"],
                        attributes: [
                            "id": "chapter",
                            "href": "chapter.xhtml",
                            "media-type": "application/xhtml+xml",
                        ],
                        text: ""
                    ),
                    XMLElementProjection(
                        name: "itemref",
                        path: ["package", "spine", "itemref"],
                        attributes: ["idref": "chapter"],
                        text: ""
                    ),
                ]
            )
        }
        throw xmlFailure(.xmlInvalid)
    }

    private func hasRejectedPrefix(_ data: Data) -> Bool {
        if data.starts(with: Data([0xEF, 0xBB, 0xBF])) {
            return true
        }
        guard let first = data.first else { return false }
        return first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D
    }
}

private func xmlFailure(_ code: DiagnosticCode) -> SanitizedFailure {
    SanitizedFailure(
        family: .xml,
        code: code,
        message: "XML failed.",
        recoveryAction: .reviewBook
    )
}
