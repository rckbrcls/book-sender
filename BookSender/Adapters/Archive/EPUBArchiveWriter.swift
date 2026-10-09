import Foundation
import ZIPFoundation

struct EPUBArchiveWriter: EPUBArchiveWriting {
    func write(
        source: StagedFileReference,
        plan: PreparationPlan,
        workspace: WorkspaceReference,
        limits: SafetyLimits
    ) async throws -> StagedFileReference {
        try Task.checkCancellation()
        guard plan.decision == .writeEPUBWorkingCopy else {
            throw failure(.repairInvalidPlan)
        }
        guard plan.actions.allSatisfy({ supports($0) }) else {
            throw failure(.repairUnsupportedAction)
        }

        let deadline = ContinuousClock.now.advanced(by: limits.operationTimeout)
        let reader = ZIPFoundationEPUBArchive(source: source)
        let descriptors = try await reader.preflight(source, limits: limits)
        try validateArchivePreconditions(plan, descriptors: descriptors)
        let fileManager = FileManager.default
        let partialURL = workspace.rootURL
            .appending(component: "prepared.partial.epub")
        guard !fileManager.fileExists(atPath: partialURL.path) else {
            throw failure(.repairOutputCreate)
        }

        do {
            let input = try Archive(url: source.url, accessMode: .read)
            let edited = try editedDocuments(
                plan,
                descriptors: descriptors,
                input: input,
                limits: limits,
                deadline: deadline
            )
            let output = try Archive(url: partialURL, accessMode: .create)
            try add(
                Data("application/epub+zip".utf8),
                at: "mimetype",
                compression: .none,
                to: output
            )
            if let packagePath = restoredPackagePath(in: plan) {
                try add(
                    containerXML(packagePath: packagePath),
                    at: "META-INF/container.xml",
                    compression: .deflate,
                    to: output
                )
            }
            try guardDeadline(deadline)

            let restoresContainer = restoredPackagePath(in: plan) != nil
            for (index, descriptor) in descriptors.enumerated() {
                try Task.checkCancellation()
                try guardDeadline(deadline)
                guard !descriptor.isDirectory,
                      descriptor.path != "mimetype",
                      !(restoresContainer
                        && descriptor.path == "META-INF/container.xml")
                else {
                    continue
                }

                if let replacement = edited[descriptor.path] {
                    let compression: CompressionMethod =
                        descriptor.compressionMethod == 0 ? .none : .deflate
                    try add(
                        replacement,
                        at: descriptor.path,
                        compression: compression,
                        to: output
                    )
                    continue
                }

                guard let entry = input[descriptor.path],
                      descriptor.uncompressedSize <= limits.maximumEntryBytes
                else {
                    throw failure(.repairEntryMissing)
                }

                let temporary = workspace.rootURL
                    .appending(component: "entry-\(index).partial")
                guard fileManager.createFile(
                    atPath: temporary.path,
                    contents: nil
                ) else {
                    throw failure(.repairEntryCreate)
                }
                defer { try? fileManager.removeItem(at: temporary) }

                let writer = try FileHandle(forWritingTo: temporary)
                do {
                    _ = try input.extract(entry, bufferSize: 64 * 1_024) { chunk in
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        try self.guardDeadline(deadline)
                        try writer.write(contentsOf: chunk)
                    }
                    try writer.synchronize()
                    try writer.close()
                } catch {
                    try? writer.close()
                    throw error
                }

                let itemReader = try FileHandle(forReadingFrom: temporary)
                defer { try? itemReader.close() }
                let compression: CompressionMethod = descriptor.compressionMethod == 0
                    ? .none
                    : .deflate
                try output.addEntry(
                    with: descriptor.path,
                    type: .file,
                    uncompressedSize: descriptor.uncompressedSize,
                    compressionMethod: compression,
                    provider: { position, size in
                        try Task.checkCancellation()
                        try itemReader.seek(toOffset: UInt64(position))
                        return try itemReader.read(upToCount: size) ?? Data()
                    }
                )
            }
            return StagedFileReference(identifier: UUID(), url: partialURL)
        } catch is CancellationError {
            try? fileManager.removeItem(at: partialURL)
            throw CancellationError()
        } catch let sanitized as SanitizedFailure {
            try? fileManager.removeItem(at: partialURL)
            throw sanitized
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw failure(.repairWrite)
        }
    }

    private func supports(_ action: RepairAction) -> Bool {
        switch action {
        case .rebuildMimetype, .restoreContainer, .correctMediaType,
             .repairReference, .normalizeXML, .removeDanglingSpineItem:
            true
        case .normalizePath:
            false
        }
    }

    private func validateArchivePreconditions(
        _ plan: PreparationPlan,
        descriptors: [ArchiveEntryDescriptor]
    ) throws {
        guard let packagePath = restoredPackagePath(in: plan) else { return }
        let paths = Set(descriptors.map(\.path))
        let packages = plan.actions.compactMap { action -> String? in
            if case .restoreContainer(let path) = action { return path }
            return nil
        }
        let opfPaths = paths.filter { $0.lowercased().hasSuffix(".opf") }
        guard packages.allSatisfy({ $0 == packagePath }),
              paths.contains(packagePath),
              opfPaths.count == 1,
              opfPaths.first == packagePath
        else {
            throw failure(.repairPrecondition)
        }
    }

    private func editedDocuments(
        _ plan: PreparationPlan,
        descriptors: [ArchiveEntryDescriptor],
        input: Archive,
        limits: SafetyLimits,
        deadline: ContinuousClock.Instant
    ) throws -> [String: Data] {
        let grouped = try documentEdits(in: plan)
        guard !grouped.isEmpty else { return [:] }

        var edited: [String: Data] = [:]
        let rewriter = XMLDocumentRewriter()
        for (path, edits) in grouped {
            try Task.checkCancellation()
            try guardDeadline(deadline)
            guard let descriptor = descriptors.first(where: { $0.path == path }),
                  !descriptor.isDirectory
            else {
                throw failure(.repairPrecondition)
            }
            guard descriptor.uncompressedSize <= limits.maximumEntryBytes else {
                throw failure(.repairEntryMissing)
            }
            guard descriptor.uncompressedSize >= 0,
                  descriptor.uncompressedSize <= Int64(limits.maximumXMLBytes)
            else {
                throw failure(.repairXML)
            }
            let data = try readBounded(
                path: path,
                from: input,
                maximumBytes: limits.maximumXMLBytes,
                deadline: deadline
            )
            do {
                edited[path] = try rewriter.rewrite(
                    data,
                    edits: edits,
                    maximumBytes: limits.maximumXMLBytes
                )
            } catch let editError as XMLEditError {
                switch editError {
                case .precondition:
                    throw failure(.repairPrecondition)
                case .oversize, .undecodable:
                    throw failure(.repairXML)
                }
            }
        }
        return edited
    }

    private func documentEdits(
        in plan: PreparationPlan
    ) throws -> [String: DocumentEdits] {
        var grouped: [String: DocumentEdits] = [:]
        for action in plan.actions {
            switch action {
            case .rebuildMimetype, .restoreContainer:
                continue
            case .normalizePath:
                throw failure(.repairUnsupportedAction)
            case .correctMediaType(let package, let href, let from, let to):
                var edits = grouped[package] ?? DocumentEdits()
                edits.mediaTypes.append((href: href, from: from, to: to))
                grouped[package] = edits
            case .repairReference(let document, let from, let to):
                var edits = grouped[document] ?? DocumentEdits()
                edits.references.append((from: from, to: to))
                grouped[document] = edits
            case .normalizeXML(let path):
                var edits = grouped[path] ?? DocumentEdits()
                edits.stripsXMLPrefix = true
                grouped[path] = edits
            case .removeDanglingSpineItem(let package, let idref):
                var edits = grouped[package] ?? DocumentEdits()
                edits.spineIDs.append(idref)
                grouped[package] = edits
            }
        }
        return grouped
    }

    private func readBounded(
        path: String,
        from archive: Archive,
        maximumBytes: Int,
        deadline: ContinuousClock.Instant
    ) throws -> Data {
        guard maximumBytes >= 0 else {
            throw failure(.repairXML)
        }
        guard let entry = archive[path] else {
            throw failure(.repairEntryMissing)
        }
        var result = Data()
        result.reserveCapacity(min(maximumBytes, 64 * 1_024))
        _ = try archive.extract(entry, bufferSize: 64 * 1_024) { chunk in
            if Task.isCancelled {
                throw CancellationError()
            }
            try self.guardDeadline(deadline)
            guard chunk.count <= maximumBytes,
                  result.count <= maximumBytes - chunk.count
            else {
                throw self.failure(.repairXML)
            }
            result.append(chunk)
        }
        return result
    }

    private func restoredPackagePath(in plan: PreparationPlan) -> String? {
        plan.actions.compactMap {
            if case .restoreContainer(let packagePath) = $0 {
                return packagePath
            }
            return nil
        }.first
    }

    private func containerXML(packagePath: String) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="\(escapedXMLAttribute(packagePath))" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8
        )
    }

    private func escapedXMLAttribute(_ value: String) -> String {
        escapedXMLAttribute(value, quote: "\"")
    }

    private func escapedXMLAttribute(
        _ value: String,
        quote: Character
    ) -> String {
        var escaped = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quote == "'" {
            escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
        }
        return escaped
    }

    private func add(
        _ data: Data,
        at path: String,
        compression: CompressionMethod,
        to archive: Archive
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compression,
            provider: { position, size in
                try Task.checkCancellation()
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }

    private func guardDeadline(_ deadline: ContinuousClock.Instant) throws {
        guard ContinuousClock.now < deadline else {
            throw failure(.repairTimeout)
        }
    }

    private func failure(_ code: DiagnosticCode) -> SanitizedFailure {
        SanitizedFailure(
            family: .repair,
            code: code,
            message: "A safe working copy could not be created.",
            recoveryAction: .reviewBook
        )
    }
}

private struct DocumentEdits {
    var stripsXMLPrefix = false
    var mediaTypes: [(href: String, from: String, to: String)] = []
    var references: [(from: String, to: String)] = []
    var spineIDs: [String] = []

    var hasTextEdits: Bool {
        !mediaTypes.isEmpty || !references.isEmpty || !spineIDs.isEmpty
    }
}

private enum XMLEditError: Error {
    case precondition
    case oversize
    case undecodable
}

private struct XMLDocumentRewriter {
    func rewrite(
        _ data: Data,
        edits: DocumentEdits,
        maximumBytes: Int
    ) throws -> Data {
        let source = try edits.stripsXMLPrefix
            ? strippingXMLPrefix(data)
            : data
        guard source.count <= maximumBytes else {
            throw XMLEditError.oversize
        }
        guard edits.hasTextEdits else { return source }
        guard let document = String(data: source, encoding: .utf8) else {
            throw XMLEditError.undecodable
        }

        let tags = try startTags(in: document)
        var textEdits: [TextEdit] = []
        for change in edits.mediaTypes {
            let tag = try uniqueTag(tags, localName: "item") {
                $0.attributes["href"]?.decoded == change.href
                    && $0.attributes["media-type"]?.decoded == change.from
            }
            guard let mediaType = tag.attributes["media-type"] else {
                throw XMLEditError.precondition
            }
            textEdits.append(
                TextEdit(
                    range: mediaType.range,
                    replacement: escapedXMLAttribute(
                        change.to,
                        quote: mediaType.quote
                    )
                )
            )
        }
        for change in edits.references {
            let tag = try uniqueTag(tags, localName: "item") {
                $0.attributes["href"]?.decoded == change.from
            }
            guard let href = tag.attributes["href"] else {
                throw XMLEditError.precondition
            }
            textEdits.append(
                TextEdit(
                    range: href.range,
                    replacement: escapedXMLAttribute(change.to, quote: href.quote)
                )
            )
        }
        for idref in edits.spineIDs {
            let tag = try uniqueTag(tags, localName: "itemref") {
                $0.attributes["idref"]?.decoded == idref
            }
            textEdits.append(
                TextEdit(
                    range: try elementRange(of: tag, in: document),
                    replacement: ""
                )
            )
        }

        let rewritten = try apply(textEdits, to: document)
        let output = Data(rewritten.utf8)
        guard output.count <= maximumBytes else {
            throw XMLEditError.oversize
        }
        return output
    }

    private func strippingXMLPrefix(_ data: Data) throws -> Data {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let declaration = Data("<?xml".utf8)
        var index = 0
        var removed = false
        while index < data.count {
            if index + bom.count <= data.count,
               data[index..<(index + bom.count)].elementsEqual(bom) {
                index += bom.count
                removed = true
                continue
            }
            if isLeadingWhitespace(data[index]) {
                index += 1
                removed = true
                continue
            }
            break
        }
        guard removed, data.dropFirst(index).starts(with: declaration) else {
            throw XMLEditError.precondition
        }
        return Data(data.dropFirst(index))
    }

    private func isLeadingWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func startTags(in document: String) throws -> [XMLStartTag] {
        var tags: [XMLStartTag] = []
        var index = document.startIndex
        while index < document.endIndex {
            guard let open = document[index...].firstIndex(of: "<") else { break }
            let next = document.index(after: open)
            guard next < document.endIndex else {
                throw XMLEditError.precondition
            }
            let marker = document[next]
            if marker == "!" || marker == "?" {
                index = try skipSpecial(document, from: open)
                continue
            }
            if marker == "/" {
                index = try skipUntil(document, from: open, marker: ">")
                continue
            }
            let tag = try parseStartTag(document, from: open)
            tags.append(tag)
            index = tag.range.upperBound
        }
        return tags
    }

    private func uniqueTag(
        _ tags: [XMLStartTag],
        localName: String,
        where matches: (XMLStartTag) -> Bool
    ) throws -> XMLStartTag {
        let found = tags.filter {
            !$0.hasDuplicateAttribute && $0.localName == localName && matches($0)
        }
        guard found.count == 1, let tag = found.first else {
            throw XMLEditError.precondition
        }
        return tag
    }

    private func elementRange(
        of tag: XMLStartTag,
        in document: String
    ) throws -> Range<String.Index> {
        if tag.isEmpty { return tag.range }
        var depth = 1
        var index = tag.range.upperBound
        while index < document.endIndex, depth > 0 {
            guard let open = document[index...].firstIndex(of: "<") else { break }
            let next = document.index(after: open)
            guard next < document.endIndex else {
                throw XMLEditError.precondition
            }
            let marker = document[next]
            if marker == "!" || marker == "?" {
                index = try skipSpecial(document, from: open)
                continue
            }
            if marker == "/" {
                let endTag = try endTag(document, from: open)
                if endTag.localName == tag.localName {
                    depth -= 1
                    if depth == 0 {
                        return tag.range.lowerBound..<endTag.end
                    }
                }
                index = endTag.end
                continue
            }
            let nested = try parseStartTag(document, from: open)
            if nested.localName == tag.localName, !nested.isEmpty {
                depth += 1
            }
            index = nested.range.upperBound
        }
        throw XMLEditError.precondition
    }

    private func parseStartTag(
        _ document: String,
        from open: String.Index
    ) throws -> XMLStartTag {
        var index = document.index(after: open)
        let nameStart = index
        guard index < document.endIndex, isNameStart(document[index]) else {
            throw XMLEditError.precondition
        }
        index = document.index(after: index)
        while index < document.endIndex, isName(document[index]) {
            index = document.index(after: index)
        }
        let rawName = String(document[nameStart..<index])
        var attributes: [String: XMLAttributeValue] = [:]
        var duplicate = false

        while index < document.endIndex {
            index = skipWhitespace(document, from: index)
            guard index < document.endIndex else {
                throw XMLEditError.precondition
            }
            let character = document[index]
            if character == ">" {
                let end = document.index(after: index)
                return XMLStartTag(
                    localName: localName(rawName),
                    range: open..<end,
                    isEmpty: false,
                    attributes: attributes,
                    hasDuplicateAttribute: duplicate
                )
            }
            if character == "/" {
                let afterSlash = document.index(after: index)
                index = skipWhitespace(document, from: afterSlash)
                guard index < document.endIndex, document[index] == ">" else {
                    throw XMLEditError.precondition
                }
                let end = document.index(after: index)
                return XMLStartTag(
                    localName: localName(rawName),
                    range: open..<end,
                    isEmpty: true,
                    attributes: attributes,
                    hasDuplicateAttribute: duplicate
                )
            }

            let attribute = try parseAttribute(document, from: index)
            let key = localName(attribute.name)
            if attributes[key] != nil {
                duplicate = true
            }
            attributes[key] = attribute.value
            index = attribute.next
        }
        throw XMLEditError.precondition
    }

    private func parseAttribute(
        _ document: String,
        from start: String.Index
    ) throws -> (name: String, value: XMLAttributeValue, next: String.Index) {
        var index = start
        guard index < document.endIndex, isNameStart(document[index]) else {
            throw XMLEditError.precondition
        }
        let nameStart = index
        index = document.index(after: index)
        while index < document.endIndex, isName(document[index]) {
            index = document.index(after: index)
        }
        let name = String(document[nameStart..<index])
        index = skipWhitespace(document, from: index)
        guard index < document.endIndex, document[index] == "=" else {
            throw XMLEditError.precondition
        }
        index = skipWhitespace(document, from: document.index(after: index))
        guard index < document.endIndex else {
            throw XMLEditError.precondition
        }
        let quote = document[index]
        guard quote == "\"" || quote == "'" else {
            throw XMLEditError.precondition
        }
        let valueStart = document.index(after: index)
        guard let valueEnd = document[valueStart...].firstIndex(of: quote) else {
            throw XMLEditError.precondition
        }
        let raw = String(document[valueStart..<valueEnd])
        let value = XMLAttributeValue(
            range: valueStart..<valueEnd,
            decoded: decodeXMLAttribute(raw),
            quote: quote
        )
        return (name, value, document.index(after: valueEnd))
    }

    private func endTag(
        _ document: String,
        from open: String.Index
    ) throws -> (localName: String, end: String.Index) {
        var index = document.index(after: open)
        guard index < document.endIndex, document[index] == "/" else {
            throw XMLEditError.precondition
        }
        index = document.index(after: index)
        let nameStart = index
        guard index < document.endIndex, isNameStart(document[index]) else {
            throw XMLEditError.precondition
        }
        index = document.index(after: index)
        while index < document.endIndex, isName(document[index]) {
            index = document.index(after: index)
        }
        let name = localName(String(document[nameStart..<index]))
        index = skipWhitespace(document, from: index)
        guard index < document.endIndex, document[index] == ">" else {
            throw XMLEditError.precondition
        }
        return (name, document.index(after: index))
    }

    private func apply(_ edits: [TextEdit], to document: String) throws -> String {
        let ordered = edits.sorted { $0.range.lowerBound > $1.range.lowerBound }
        var result = document
        var previous = document.endIndex
        for edit in ordered {
            guard edit.range.upperBound <= previous else {
                throw XMLEditError.precondition
            }
            result.replaceSubrange(edit.range, with: edit.replacement)
            previous = edit.range.lowerBound
        }
        return result
    }

    private func skipSpecial(
        _ document: String,
        from open: String.Index
    ) throws -> String.Index {
        let next = document.index(after: open)
        if document[next...].hasPrefix("!--") {
            return try skipUntil(document, from: next, marker: "-->")
        }
        if document[next...].hasPrefix("![CDATA[") {
            return try skipUntil(document, from: next, marker: "]]>")
        }
        if document[next] == "?" {
            return try skipUntil(document, from: next, marker: "?>")
        }
        return try skipUntil(document, from: open, marker: ">")
    }

    private func skipUntil(
        _ document: String,
        from index: String.Index,
        marker: String
    ) throws -> String.Index {
        guard let found = document[index...].range(of: marker) else {
            throw XMLEditError.precondition
        }
        return found.upperBound
    }

    private func skipWhitespace(
        _ document: String,
        from index: String.Index
    ) -> String.Index {
        var index = index
        while index < document.endIndex, isXMLWhitespace(document[index]) {
            index = document.index(after: index)
        }
        return index
    }

    private func isXMLWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
    }

    private func isNameStart(_ character: Character) -> Bool {
        character == "_" || character == ":" || character.isLetter
    }

    private func isName(_ character: Character) -> Bool {
        isNameStart(character) || character.isNumber
            || character == "-" || character == "."
    }

    private func localName(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return name }
        let remainder = name[name.index(after: colon)...]
        return remainder.isEmpty ? name : String(remainder)
    }

    private func decodeXMLAttribute(_ raw: String) -> String? {
        var result = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] != "&" {
                result.append(raw[index])
                index = raw.index(after: index)
                continue
            }
            guard let semi = raw[index...].firstIndex(of: ";"), semi > index else {
                return nil
            }
            let token = raw[raw.index(after: index)..<semi]
            switch token {
            case "amp": result.append("&")
            case "quot": result.append("\"")
            case "apos": result.append("'")
            case "lt": result.append("<")
            case "gt": result.append(">")
            default:
                guard let scalar = numericScalar(token) else { return nil }
                result.append(Character(scalar))
            }
            index = raw.index(after: semi)
        }
        return result
    }

    private func numericScalar(_ token: String.SubSequence) -> Unicode.Scalar? {
        if token.hasPrefix("#x") || token.hasPrefix("#X") {
            let digits = token.dropFirst(2)
            guard !digits.isEmpty, let value = UInt32(digits, radix: 16) else {
                return nil
            }
            return Unicode.Scalar(value)
        }
        guard token.hasPrefix("#") else { return nil }
        let digits = token.dropFirst()
        guard !digits.isEmpty, let value = UInt32(digits) else { return nil }
        return Unicode.Scalar(value)
    }

    private func escapedXMLAttribute(
        _ value: String,
        quote: Character
    ) -> String {
        var escaped = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quote == "'" {
            escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
        }
        return escaped
    }
}

private struct XMLStartTag {
    let localName: String
    let range: Range<String.Index>
    let isEmpty: Bool
    let attributes: [String: XMLAttributeValue]
    let hasDuplicateAttribute: Bool
}

private struct XMLAttributeValue {
    let range: Range<String.Index>
    let decoded: String?
    let quote: Character
}

private struct TextEdit {
    let range: Range<String.Index>
    let replacement: String
}
