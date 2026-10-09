import Foundation

struct EPUBAuditEngine: EPUBAuditing {
    private let limits: SafetyLimits
    private let xmlParser: any BoundedXMLParsing

    init(
        limits: SafetyLimits = .standard,
        xmlParser: any BoundedXMLParsing = BoundedXMLParser()
    ) {
        self.limits = limits
        self.xmlParser = xmlParser
    }

    func audit(
        _ archive: any EPUBArchiveReading,
        source: StagedFileReference
    ) async throws -> AuditReport {
        let entries: [ArchiveEntryDescriptor]
        do {
            entries = try await archive.preflight(source, limits: limits)
        } catch let failure as SanitizedFailure {
            return report([archiveFinding(for: failure)])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw unexpectedAuditFailure()
        }

        var findings: [HealthFinding] = []
        let files = entries.filter { !$0.isDirectory }
        let paths = Set(files.map(\.path))
        do {
            findings.append(
                contentsOf: try await auditMimetype(files, archive: archive)
            )
        } catch let failure as SanitizedFailure {
            return report([archiveFinding(for: failure)])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw unexpectedAuditFailure()
        }

        let packagePath: String
        if !paths.contains("META-INF/container.xml") {
            if let package = solePackagePath(in: paths) {
                findings.append(
                    finding(
                        .containerMissing,
                        .error,
                        .automatic(ruleID: "repair.container"),
                        evidence: ["package": package]
                    )
                )
                packagePath = package
            } else {
                let packages = paths.filter { $0.lowercased().hasSuffix(".opf") }
                findings.append(
                    finding(
                        .containerMissing,
                        .error,
                        packages.isEmpty ? .notApplicable : .manualReview
                    )
                )
                if packages.isEmpty {
                    findings.append(
                        finding(.packageMissing, .error, .notApplicable)
                    )
                } else {
                    findings.append(
                        finding(.packageAmbiguous, .error, .manualReview)
                    )
                }
                return report(findings)
            }
        } else if let package = try await selectedPackage(
            paths: paths,
            archive: archive,
            findings: &findings
        ) {
            packagePath = package
        } else {
            return report(findings)
        }

        findings.append(
            contentsOf: try await auditPackage(
                packagePath,
                paths: paths,
                archive: archive
            )
        )
        findings.append(
            contentsOf: await auditEncryption(paths: paths, archive: archive)
        )
        return report(deduplicated(findings))
    }

    private func auditMimetype(
        _ entries: [ArchiveEntryDescriptor],
        archive: any EPUBArchiveReading
    ) async throws -> [HealthFinding] {
        guard let mimetype = entries.first(where: { $0.path == "mimetype" }) else {
            return [
                finding(
                    .mimetypeMissing,
                    .error,
                    .automatic(ruleID: "repair.mimetype")
                ),
            ]
        }

        var findings: [HealthFinding] = []
        if entries.first?.path != "mimetype" {
            findings.append(
                finding(
                    .mimetypeNotFirst,
                    .error,
                    .automatic(ruleID: "repair.mimetype")
                )
            )
        }
        if mimetype.compressionMethod != 0 {
            findings.append(
                finding(
                    .mimetypeCompressed,
                    .error,
                    .automatic(ruleID: "repair.mimetype")
                )
            )
        }
        let data = try await archive.data(for: mimetype.path, maximumBytes: 64)
        if data != Data("application/epub+zip".utf8) {
            findings.append(
                finding(
                    .mimetypeInvalid,
                    .error,
                    .automatic(ruleID: "repair.mimetype")
                )
            )
        }
        return findings
    }

    private func auditPackage(
        _ packagePath: String,
        paths: Set<String>,
        archive: any EPUBArchiveReading
    ) async throws -> [HealthFinding] {
        let data: Data
        do {
            data = try await archive.data(
                for: packagePath,
                maximumBytes: limits.maximumXMLBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as SanitizedFailure {
            return [
                xmlFinding(
                    failure,
                    fallback: .packageInvalid,
                    location: packagePath
                ),
            ]
        } catch {
            return [
                finding(
                    .packageInvalid,
                    .error,
                    .manualReview,
                    location: packagePath
                ),
            ]
        }

        let parsed: ParsedMarkup
        do {
            parsed = try await parseMarkup(
                data,
                path: packagePath,
                failureCode: .packageInvalid
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as SanitizedFailure {
            return [
                xmlFinding(
                    failure,
                    fallback: .packageInvalid,
                    location: packagePath
                ),
            ]
        } catch {
            return [
                finding(
                    .packageInvalid,
                    .error,
                    .manualReview,
                    location: packagePath
                ),
            ]
        }

        var findings: [HealthFinding] = []
        if let normalized = parsed.normalizedXML {
            findings.append(normalized)
        }
        let package = parsed.document
        guard package.rootName.hasSuffix("package") else {
            findings.append(
                finding(
                    .packageInvalid,
                    .error,
                    .manualReview,
                    location: packagePath
                )
            )
            return findings
        }

        let packageDirectory = (packagePath as NSString).deletingLastPathComponent
        let manifestItems = package.elements.filter { $0.name.hasSuffix("item") }
        guard !manifestItems.isEmpty else {
            findings.append(
                finding(
                    .packageInvalid,
                    .error,
                    .manualReview,
                    location: packagePath
                )
            )
            return findings
        }
        var IDs = Set<String>()
        for item in manifestItems {
            guard let identifier = item.attributes["id"],
                  let href = item.attributes["href"],
                  let declaredType = item.attributes["media-type"],
                  IDs.insert(identifier).inserted
            else {
                findings.append(
                    finding(
                        .packageInvalid,
                        .error,
                        .manualReview,
                        location: packagePath
                    )
                )
                continue
            }

            if isRemote(href) {
                findings.append(
                    finding(
                        .remoteReference,
                        .critical,
                        .forbidden,
                        location: packagePath
                    )
                )
                continue
            }
            guard let resolved = resolve(href, relativeTo: packageDirectory) else {
                findings.append(
                    finding(
                        .referenceMissing,
                        .error,
                        .manualReview,
                        location: packagePath
                    )
                )
                continue
            }
            if !paths.contains(resolved) {
                findings.append(
                    referenceFinding(
                        href: href,
                        resolved: resolved,
                        packagePath: packagePath,
                        packageDirectory: packageDirectory,
                        paths: paths
                    )
                )
            }

            let normalizedDeclaredType = normalizedMediaType(declaredType)
            if let expectation = mediaTypeExpectation(for: resolved),
               !expectation.compatible.contains(normalizedDeclaredType) {
                let decision = try await mediaTypeDecision(
                    declared: normalizedDeclaredType,
                    path: resolved,
                    archive: archive
                )
                if decision == .unsafe {
                    findings.append(
                        finding(
                            .xmlUnsafe,
                            .critical,
                            .forbidden,
                            location: resolved
                        )
                    )
                }
                let repairsMediaType = decision == .automatic
                    && !packagePath.isEmpty
                    && !href.isEmpty
                    && !declaredType.isEmpty
                    && !expectation.preferred.isEmpty
                var evidence = [
                    "declared": declaredType,
                    "expected": expectation.preferred,
                ]
                if repairsMediaType {
                    evidence["package"] = packagePath
                    evidence["href"] = href
                }
                findings.append(
                    finding(
                        .manifestMediaTypeMismatch,
                        .error,
                        repairsMediaType
                            ? .automatic(ruleID: "repair.media-type")
                            : .manualReview,
                        location: resolved,
                        evidence: evidence
                    )
                )
            }
            let properties = item.attributes["properties"]?.lowercased() ?? ""
            if scriptMediaTypes.contains(normalizedDeclaredType)
                || properties.split(separator: " ").contains("scripted") {
                findings.append(
                    finding(
                        .activeContent,
                        .critical,
                        .forbidden,
                        location: resolved
                    )
                )
            }
        }

        let spineReferences = package.elements.filter {
            $0.name.hasSuffix("itemref")
        }
        let resolvableSpineCount = spineReferences.filter { itemReference in
            guard let identifier = itemReference.attributes["idref"] else {
                return false
            }
            return IDs.contains(identifier)
        }.count
        for itemReference in spineReferences {
            guard let identifier = itemReference.attributes["idref"] else {
                findings.append(
                    finding(
                        .referenceMissing,
                        .error,
                        .manualReview,
                        location: packagePath
                    )
                )
                continue
            }
            guard !IDs.contains(identifier) else { continue }
            if resolvableSpineCount >= 1, !identifier.isEmpty {
                findings.append(
                    finding(
                        .referenceMissing,
                        .error,
                        .automatic(ruleID: "repair.spine"),
                        location: "\(packagePath)#\(identifier)",
                        evidence: [
                            "package": packagePath,
                            "idref": identifier,
                        ]
                    )
                )
            } else {
                findings.append(
                    finding(
                        .referenceMissing,
                        .error,
                        .manualReview,
                        location: packagePath
                    )
                )
            }
        }

        for element in package.elements {
            if element.attributes.values.contains(where: isRemote) {
                findings.append(
                    finding(
                        .remoteReference,
                        .critical,
                        .forbidden,
                        location: packagePath
                    )
                )
            }
        }
        return findings
    }

    private func auditEncryption(
        paths: Set<String>,
        archive: any EPUBArchiveReading
    ) async -> [HealthFinding] {
        guard paths.contains("META-INF/encryption.xml") else { return [] }
        do {
            let data = try await archive.data(
                for: "META-INF/encryption.xml",
                maximumBytes: limits.maximumXMLBytes
            )
            let projection = try await xmlParser.parse(data, limits: limits)
            let algorithms = projection.elements.compactMap {
                $0.name.hasSuffix("EncryptionMethod")
                    ? $0.attributes["Algorithm"]
                    : nil
            }
            let permittedFontAlgorithms: Set<String> = [
                "http://www.idpf.org/2008/embedding",
                "http://ns.adobe.com/pdf/enc#RC",
            ]
            guard !algorithms.isEmpty,
                  algorithms.allSatisfy(permittedFontAlgorithms.contains)
            else {
                return [
                    finding(
                        .encryptedContent,
                        .critical,
                        .forbidden,
                        location: "META-INF/encryption.xml"
                    ),
                ]
            }
            return []
        } catch {
            return [
                finding(
                    .encryptedContent,
                    .critical,
                    .forbidden,
                    location: "META-INF/encryption.xml"
                ),
            ]
        }
    }

    private func selectedPackage(
        paths: Set<String>,
        archive: any EPUBArchiveReading,
        findings: inout [HealthFinding]
    ) async throws -> String? {
        let containerPath = "META-INF/container.xml"
        let containerData: Data
        do {
            containerData = try await archive.data(
                for: containerPath,
                maximumBytes: limits.maximumXMLBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as SanitizedFailure {
            return containerRecovery(
                failure: failure,
                paths: paths,
                findings: &findings
            )
        } catch {
            return restoredPackage(
                paths: paths,
                findings: &findings,
                code: .containerInvalid,
                location: containerPath
            )
        }

        do {
            let parsed = try await parseMarkup(
                containerData,
                path: containerPath,
                failureCode: .containerInvalid
            )
            if let normalized = parsed.normalizedXML {
                findings.append(normalized)
            }
            guard parsed.document.rootName.hasSuffix("container") else {
                return restoredPackage(
                    paths: paths,
                    findings: &findings,
                    code: .containerInvalid,
                    location: containerPath
                )
            }
            let declaredPackages = parsed.document.elements.compactMap {
                $0.name.hasSuffix("rootfile") ? $0.attributes["full-path"] : nil
            }
            let uniquePackages = Array(Set(declaredPackages))
            guard uniquePackages.count == 1, let selected = uniquePackages.first else {
                findings.append(
                    finding(
                        uniquePackages.isEmpty ? .packageMissing : .packageAmbiguous,
                        .error,
                        uniquePackages.isEmpty ? .notApplicable : .manualReview
                    )
                )
                return nil
            }
            if paths.contains(selected) {
                return selected
            }
            guard let package = solePackagePath(in: paths) else {
                let packageCount = paths.filter {
                    $0.lowercased().hasSuffix(".opf")
                }.count
                findings.append(
                    finding(
                        .packageMissing,
                        .error,
                        packageCount > 1 ? .manualReview : .notApplicable,
                        location: selected
                    )
                )
                return nil
            }
            findings.append(
                finding(
                    .packageMissing,
                    .error,
                    .automatic(ruleID: "repair.container"),
                    location: selected,
                    evidence: ["package": package]
                )
            )
            return package
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as SanitizedFailure {
            return containerRecovery(
                failure: failure,
                paths: paths,
                findings: &findings
            )
        } catch {
            return restoredPackage(
                paths: paths,
                findings: &findings,
                code: .containerInvalid,
                location: containerPath
            )
        }
    }

    private func containerRecovery(
        failure: SanitizedFailure,
        paths: Set<String>,
        findings: inout [HealthFinding]
    ) -> String? {
        if Self.unsafeXMLCodes.contains(failure.code) {
            findings.append(
                xmlFinding(
                    failure,
                    fallback: .containerInvalid,
                    location: "META-INF/container.xml"
                )
            )
            return nil
        }
        return restoredPackage(
            paths: paths,
            findings: &findings,
            code: .containerInvalid,
            location: "META-INF/container.xml"
        )
    }

    private func restoredPackage(
        paths: Set<String>,
        findings: inout [HealthFinding],
        code: FindingCode,
        location: String
    ) -> String? {
        guard let package = solePackagePath(in: paths) else {
            findings.append(
                finding(code, .error, .manualReview, location: location)
            )
            return nil
        }
        findings.append(
            finding(
                code,
                .error,
                .automatic(ruleID: "repair.container"),
                location: location,
                evidence: ["package": package]
            )
        )
        return package
    }

    private func solePackagePath(in paths: Set<String>) -> String? {
        let packages = paths.filter { $0.lowercased().hasSuffix(".opf") }
        guard packages.count == 1 else { return nil }
        return packages.first
    }

    private func parseMarkup(
        _ data: Data,
        path: String,
        failureCode: FindingCode
    ) async throws -> ParsedMarkup {
        do {
            return ParsedMarkup(
                document: try await xmlParser.parse(data, limits: limits),
                normalizedXML: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as SanitizedFailure {
            if Self.unsafeXMLCodes.contains(failure.code) {
                throw failure
            }
            guard let stripped = strippedXMLPrefix(data) else { throw failure }
            do {
                let document = try await xmlParser.parse(stripped, limits: limits)
                return ParsedMarkup(
                    document: document,
                    normalizedXML: finding(
                        failureCode,
                        .error,
                        .automatic(ruleID: "repair.xml"),
                        location: path,
                        evidence: ["path": path]
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let strippedFailure as SanitizedFailure {
                if Self.unsafeXMLCodes.contains(strippedFailure.code) {
                    throw strippedFailure
                }
                throw failure
            }
        }
    }

    private func strippedXMLPrefix(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        var stripped = false
        while index < bytes.count {
            if index + 2 < bytes.count,
               bytes[index] == 0xEF,
               bytes[index + 1] == 0xBB,
               bytes[index + 2] == 0xBF {
                index += 3
                stripped = true
                continue
            }
            if bytes[index] == 0x20
                || bytes[index] == 0x09
                || bytes[index] == 0x0A
                || bytes[index] == 0x0D {
                index += 1
                stripped = true
                continue
            }
            break
        }
        guard stripped, index < bytes.count else { return nil }
        let remainder = Data(bytes[index...])
        guard remainder.starts(with: Data("<?xml".utf8)) else { return nil }
        return remainder
    }

    private func referenceFinding(
        href: String,
        resolved: String,
        packagePath: String,
        packageDirectory: String,
        paths: Set<String>
    ) -> HealthFinding {
        let canonicalKey = resolved.precomposedStringWithCanonicalMapping.lowercased()
        let canonicalMatches = paths.filter {
            $0.precomposedStringWithCanonicalMapping.lowercased() == canonicalKey
        }
        let candidate: String?
        let ambiguous: Bool
        if !canonicalMatches.isEmpty {
            candidate = canonicalMatches.count == 1 ? canonicalMatches.first : nil
            ambiguous = canonicalMatches.count > 1
        } else {
            let basename = (resolved as NSString).lastPathComponent
            let suffixMatches = paths.filter {
                ($0 as NSString).lastPathComponent == basename
            }
            candidate = suffixMatches.count == 1 ? suffixMatches.first : nil
            ambiguous = suffixMatches.count > 1
        }
        if ambiguous {
            return finding(
                .referenceAmbiguous,
                .error,
                .manualReview,
                location: resolved
            )
        }
        if let candidate,
           let rewritten = manifestHref(
               for: candidate,
               packageDirectory: packageDirectory
           ),
           rewritten != href {
            return finding(
                .referenceMissing,
                .error,
                .automatic(ruleID: "repair.reference"),
                location: resolved,
                evidence: [
                    "package": packagePath,
                    "from": href,
                    "to": rewritten,
                ]
            )
        }
        return finding(
            .referenceMissing,
            .error,
            .manualReview,
            location: resolved
        )
    }

    private func manifestHref(
        for archivePath: String,
        packageDirectory: String
    ) -> String? {
        let relative: String
        if packageDirectory.isEmpty {
            relative = archivePath
        } else if archivePath.hasPrefix(packageDirectory + "/") {
            relative = String(archivePath.dropFirst(packageDirectory.count + 1))
        } else {
            let base = packageDirectory.split(separator: "/").map(String.init)
            let target = archivePath.split(separator: "/").map(String.init)
            var shared = 0
            while shared < base.count,
                  shared < target.count,
                  base[shared] == target[shared] {
                shared += 1
            }
            let upward = Array(repeating: "..", count: base.count - shared)
            relative = (upward + Array(target[shared...])).joined(separator: "/")
        }
        guard !relative.isEmpty else { return nil }
        return relative
    }

    private func mediaTypeDecision(
        declared: String,
        path: String,
        archive: any EPUBArchiveReading
    ) async throws -> MediaTypeDecision {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        if legacyMediaTypeAliases(for: pathExtension).contains(declared) {
            return .automatic
        }
        switch try await contentVerdict(for: path, archive: archive) {
        case .confirms:
            if Self.xmlExtensions.contains(pathExtension),
               declaredTypeConflictsWithXMLExtension(declared) {
                return .manual
            }
            return .automatic
        case .contradicts, .unknown:
            return .manual
        case .unsafe:
            return .unsafe
        }
    }

    private func contentVerdict(
        for path: String,
        archive: any EPUBArchiveReading
    ) async throws -> ContentVerdict {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        let maximumBytes = Self.xmlExtensions.contains(pathExtension)
            ? limits.maximumXMLBytes
            : Int(limits.maximumEntryBytes)
        let data: Data
        do {
            data = try await archive.data(for: path, maximumBytes: maximumBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown
        }
        switch pathExtension {
        case "jpg", "jpeg":
            return binaryVerdict(
                data,
                confirming: { self.isJPEG($0) },
                signatureLength: 3
            )
        case "png":
            return binaryVerdict(
                data,
                confirming: { self.isPNG($0) },
                signatureLength: 8
            )
        case "gif":
            return binaryVerdict(
                data,
                confirming: { self.isGIF($0) },
                signatureLength: 6
            )
        case "ttf":
            return binaryVerdict(
                data,
                confirming: { self.isTrueType($0) },
                signatureLength: 4
            )
        case "otf":
            return binaryVerdict(
                data,
                confirming: { self.isOpenType($0) },
                signatureLength: 4
            )
        case "xhtml", "html", "htm", "ncx":
            if hasKnownBinaryMagic(data) { return .contradicts }
            return try await xmlContentVerdict(data)
        default:
            return .unknown
        }
    }

    private func binaryVerdict(
        _ data: Data,
        confirming: (Data) -> Bool,
        signatureLength: Int
    ) -> ContentVerdict {
        guard data.count >= signatureLength else { return .unknown }
        return confirming(data) ? .confirms : .contradicts
    }

    private func xmlContentVerdict(_ data: Data) async throws -> ContentVerdict {
        guard !data.isEmpty else { return .unknown }
        do {
            _ = try await xmlParser.parse(data, limits: limits)
            return .confirms
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as SanitizedFailure
            where Self.unsafeXMLCodes.contains(failure.code) {
            return .unsafe
        } catch {
            return .unknown
        }
    }

    private func legacyMediaTypeAliases(for pathExtension: String) -> Set<String> {
        switch pathExtension {
        case "ttf":
            [
                "application/x-font-truetype",
                "application/font-truetype",
                "font/truetype",
            ]
        case "otf":
            [
                "application/x-font-otf",
                "application/font-opentype",
                "font/opentype",
            ]
        case "woff":
            [
                "application/x-woff",
                "font/x-woff",
            ]
        case "woff2":
            [
                "application/font-woff",
                "application/x-font-woff",
                "application/font-woff2",
                "application/x-font-woff2",
                "font/x-woff2",
            ]
        case "jpg", "jpeg":
            [
                "image/jpg",
                "image/pjpeg",
            ]
        case "png":
            ["image/x-png"]
        case "gif":
            ["image/x-gif"]
        default:
            []
        }
    }

    private func declaredTypeConflictsWithXMLExtension(_ declared: String) -> Bool {
        if declared.hasPrefix("image/") || declared.hasPrefix("font/") {
            return true
        }
        return [
            "application/x-font-truetype",
            "application/font-truetype",
            "application/x-font-ttf",
            "application/x-font-otf",
            "application/font-opentype",
            "application/x-font-opentype",
            "application/vnd.ms-opentype",
            "application/font-sfnt",
            "application/font-woff",
            "application/x-font-woff",
            "application/font-woff2",
            "application/x-font-woff2",
            "application/x-woff",
        ].contains(declared)
    }

    private func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }

    private func isPNG(_ data: Data) -> Bool {
        data.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    private func isGIF(_ data: Data) -> Bool {
        data.starts(with: Data("GIF87a".utf8))
            || data.starts(with: Data("GIF89a".utf8))
    }

    private func isTrueType(_ data: Data) -> Bool {
        data.starts(with: Data([0x00, 0x01, 0x00, 0x00]))
            || data.starts(with: Data("true".utf8))
    }

    private func isOpenType(_ data: Data) -> Bool {
        data.starts(with: Data("OTTO".utf8))
    }

    private func hasKnownBinaryMagic(_ data: Data) -> Bool {
        isJPEG(data) || isPNG(data) || isGIF(data) || isTrueType(data) || isOpenType(data)
    }

    private func resolve(_ href: String, relativeTo directory: String) -> String? {
        let pathPart = href.split(separator: "#", maxSplits: 1)
            .first
            .map(String.init) ?? href
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        let combined = directory.isEmpty ? decoded : "\(directory)/\(decoded)"
        let components = combined.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        var normalized: [Substring] = []
        for component in components {
            if component == "." || component.isEmpty {
                continue
            }
            if component == ".." {
                guard !normalized.isEmpty else { return nil }
                normalized.removeLast()
            } else {
                normalized.append(component)
            }
        }
        return normalized.joined(separator: "/")
    }

    private func isRemote(_ value: String) -> Bool {
        guard let scheme = URLComponents(string: value)?.scheme?.lowercased()
        else {
            return value.lowercased().hasPrefix("//")
        }
        return ["http", "https", "ftp", "file", "data", "javascript"]
            .contains(scheme)
    }

    private func mediaTypeExpectation(for path: String) -> MediaTypeExpectation? {
        switch (path as NSString).pathExtension.lowercased() {
        case "xhtml", "html", "htm":
            expectation("application/xhtml+xml")
        case "css":
            expectation("text/css")
        case "ncx":
            expectation("application/x-dtbncx+xml")
        case "svg":
            expectation("image/svg+xml")
        case "jpg", "jpeg":
            expectation("image/jpeg")
        case "png":
            expectation("image/png")
        case "gif":
            expectation("image/gif")
        case "otf":
            expectation(
                "font/otf",
                compatible: [
                    "application/font-sfnt",
                    "application/vnd.ms-opentype",
                    "application/x-font-opentype",
                ]
            )
        case "ttf":
            expectation(
                "font/ttf",
                compatible: [
                    "application/font-sfnt",
                    "application/x-font-ttf",
                ]
            )
        case "woff":
            expectation(
                "font/woff",
                compatible: [
                    "application/font-woff",
                    "application/x-font-woff",
                ]
            )
        case "woff2":
            expectation("font/woff2")
        case "js":
            expectation(
                "application/javascript",
                compatible: Array(scriptMediaTypes)
            )
        default: nil
        }
    }

    private static let unsafeXMLCodes: Set<DiagnosticCode> = [
        .xmlByteLimit,
        .xmlExternalEntity,
        .xmlStructureLimit,
        .xmlTextLimit,
        .xmlTimeout,
        .xmlCancelled,
    ]

    private static let xmlExtensions: Set<String> = [
        "xhtml", "html", "htm", "ncx",
    ]

    private var scriptMediaTypes: Set<String> {
        [
            "application/ecmascript",
            "application/javascript",
            "text/javascript",
        ]
    }

    private func normalizedMediaType(_ value: String) -> String {
        let baseType = value.split(separator: ";", maxSplits: 1).first
            .map(String.init) ?? value
        return baseType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func expectation(
        _ preferred: String,
        compatible: [String] = []
    ) -> MediaTypeExpectation {
        MediaTypeExpectation(
            preferred: preferred,
            compatible: Set(compatible).union([preferred])
        )
    }

    private func archiveFinding(for failure: SanitizedFailure) -> HealthFinding {
        let code: FindingCode
        switch failure.code {
        case .archiveUnsafePath: code = .archiveUnsafePath
        case .archiveDuplicatePath: code = .archiveDuplicatePath
        case .archiveEncrypted: code = .archiveEncrypted
        case .archiveUnsupportedEntry: code = .archiveUnsupportedEntry
        default: code = .archiveLimitExceeded
        }
        return finding(code, .critical, .forbidden)
    }

    private func xmlFinding(
        _ failure: SanitizedFailure,
        fallback: FindingCode,
        location: String
    ) -> HealthFinding {
        if Self.unsafeXMLCodes.contains(failure.code) {
            return finding(
                .xmlUnsafe,
                .critical,
                .forbidden,
                location: location
            )
        }
        return finding(
            fallback,
            .error,
            .manualReview,
            location: location
        )
    }

    private func deduplicated(
        _ findings: [HealthFinding]
    ) -> [HealthFinding] {
        var keys = Set<String>()
        return findings.filter {
            keys.insert(
                "\($0.code.rawValue)|\($0.location ?? "")|\($0.messageKey)"
            ).inserted
        }
    }

    private func report(_ findings: [HealthFinding]) -> AuditReport {
        AuditReport(id: UUID(), findings: findings, inspectedAt: Date())
    }

    private func unexpectedAuditFailure() -> SanitizedFailure {
        SanitizedFailure(
            family: .audit,
            code: .unexpectedAudit,
            message: "The EPUB structural audit stopped unexpectedly.",
            recoveryAction: .reviewBook,
            evidence: DiagnosticEvidence(
                phase: .structuralAudit,
                retryDisposition: .reviewBook
            )
        )
    }

    private func finding(
        _ code: FindingCode,
        _ severity: FindingSeverity,
        _ repairability: Repairability,
        location: String? = nil,
        evidence: [String: String] = [:]
    ) -> HealthFinding {
        HealthFinding(
            id: UUID(),
            code: code,
            severity: severity,
            location: location,
            messageKey: code.rawValue.lowercased(),
            repairability: repairability,
            evidence: evidence
        )
    }
}

private struct MediaTypeExpectation {
    let preferred: String
    let compatible: Set<String>
}

private struct ParsedMarkup {
    let document: XMLDocumentProjection
    let normalizedXML: HealthFinding?
}

private enum MediaTypeDecision: Equatable {
    case automatic
    case manual
    case unsafe
}

private enum ContentVerdict {
    case confirms
    case contradicts
    case unknown
    case unsafe
}
