//
//  ClickyInkParser.swift
//  leanring-buddy
//
//  Nonisolated Sendable parser for ClickyInk Live Note Markdown directives,
//  inline status badges, interactive ask/question/link pills, and standard Markdown blocks.
//

import Foundation

public nonisolated enum ClickyInkBadgeKind: String, CaseIterable, Sendable, Equatable, Hashable {
    case new
    case needs
    case done
    case pick
    case now
    case gone

    public var displayTitle: String {
        switch self {
        case .new: return "new"
        case .needs: return "needs"
        case .done: return "done"
        case .pick: return "pick"
        case .now: return "now"
        case .gone: return "gone"
        }
    }
}

public nonisolated enum ClickyInkInlineNode: Sendable, Equatable, Hashable {
    case text(String)
    case badge(ClickyInkBadgeKind)
    case ask(label: String, prompt: String)
    case question(label: String, prompt: String)
    case link(title: String, url: String)
}

public nonisolated struct ClickyInkTodoItem: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let isChecked: Bool
    public let inlines: [ClickyInkInlineNode]
    public let plainText: String

    public init(
        id: String,
        isChecked: Bool,
        inlines: [ClickyInkInlineNode],
        plainText: String
    ) {
        self.id = id
        self.isChecked = isChecked
        self.inlines = inlines
        self.plainText = plainText
    }
}

public nonisolated struct ClickyInkReceiptRow: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let label: String
    public let amount: String
    public let isTotal: Bool

    public init(id: String, label: String, amount: String, isTotal: Bool = false) {
        self.id = id
        self.label = label
        self.amount = amount
        self.isTotal = isTotal
    }
}

public nonisolated struct ClickyInkChartBar: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let label: String
    public let value: Double
    public let displayValue: String

    public init(id: String, label: String, value: Double, displayValue: String) {
        self.id = id
        self.label = label
        self.value = value
        self.displayValue = displayValue
    }
}

public nonisolated enum ClickyInkContainerKind: String, Sendable, Equatable, Hashable {
    case sticky
    case ticket
    case receipt
    case chart
    case todo
    case status
    case progress
}

public nonisolated enum ClickyInkBlock: Identifiable, Sendable, Equatable {
    case heading(id: String, level: Int, inlines: [ClickyInkInlineNode])
    case paragraph(id: String, inlines: [ClickyInkInlineNode])
    case blockquote(id: String, inlines: [ClickyInkInlineNode])
    case codeBlock(id: String, language: String?, code: String)
    case unorderedList(id: String, items: [[ClickyInkInlineNode]])
    case orderedList(id: String, items: [[ClickyInkInlineNode]])
    case checklist(id: String, items: [ClickyInkTodoItem])
    case table(id: String, headers: [[ClickyInkInlineNode]], rows: [[[ClickyInkInlineNode]]])
    case thematicBreak(id: String)
    case sticky(id: String, title: String?, accentName: String?, bodyBlocks: [ClickyInkBlock])
    case ticket(id: String, title: String, statusText: String?, identifier: String?, metadata: [(key: String, value: String)], bodyInlines: [ClickyInkInlineNode])
    case receipt(id: String, title: String, rows: [ClickyInkReceiptRow], footerNote: String?)
    case chart(id: String, title: String, bars: [ClickyInkChartBar])
    case todo(id: String, title: String, items: [ClickyInkTodoItem])
    case status(id: String, title: String, stateLabel: String, detailInlines: [ClickyInkInlineNode])
    case progress(id: String, title: String, fraction: Double, valueLabel: String, caption: String?)

    public var id: String {
        switch self {
        case .heading(let blockID, _, _),
             .paragraph(let blockID, _),
             .blockquote(let blockID, _),
             .codeBlock(let blockID, _, _),
             .unorderedList(let blockID, _),
             .orderedList(let blockID, _),
             .checklist(let blockID, _),
             .table(let blockID, _, _),
             .thematicBreak(let blockID),
             .sticky(let blockID, _, _, _),
             .ticket(let blockID, _, _, _, _, _),
             .receipt(let blockID, _, _, _),
             .chart(let blockID, _, _),
             .todo(let blockID, _, _),
             .status(let blockID, _, _, _),
             .progress(let blockID, _, _, _, _):
            return blockID
        }
    }

    public static func == (lhs: ClickyInkBlock, rhs: ClickyInkBlock) -> Bool {
        switch (lhs, rhs) {
        case (.heading(let lhsID, let lhsLevel, let lhsInlines), .heading(let rhsID, let rhsLevel, let rhsInlines)):
            return lhsID == rhsID && lhsLevel == rhsLevel && lhsInlines == rhsInlines
        case (.paragraph(let lhsID, let lhsInlines), .paragraph(let rhsID, let rhsInlines)):
            return lhsID == rhsID && lhsInlines == rhsInlines
        case (.blockquote(let lhsID, let lhsInlines), .blockquote(let rhsID, let rhsInlines)):
            return lhsID == rhsID && lhsInlines == rhsInlines
        case (.codeBlock(let lhsID, let lhsLang, let lhsCode), .codeBlock(let rhsID, let rhsLang, let rhsCode)):
            return lhsID == rhsID && lhsLang == rhsLang && lhsCode == rhsCode
        case (.unorderedList(let lhsID, let lhsItems), .unorderedList(let rhsID, let rhsItems)):
            return lhsID == rhsID && lhsItems == rhsItems
        case (.orderedList(let lhsID, let lhsItems), .orderedList(let rhsID, let rhsItems)):
            return lhsID == rhsID && lhsItems == rhsItems
        case (.checklist(let lhsID, let lhsItems), .checklist(let rhsID, let rhsItems)):
            return lhsID == rhsID && lhsItems == rhsItems
        case (.table(let lhsID, let lhsHeaders, let lhsRows), .table(let rhsID, let rhsHeaders, let rhsRows)):
            return lhsID == rhsID && lhsHeaders == rhsHeaders && lhsRows == rhsRows
        case (.thematicBreak(let lhsID), .thematicBreak(let rhsID)):
            return lhsID == rhsID
        case (.sticky(let lhsID, let lhsTitle, let lhsAccent, let lhsBlocks), .sticky(let rhsID, let rhsTitle, let rhsAccent, let rhsBlocks)):
            return lhsID == rhsID && lhsTitle == rhsTitle && lhsAccent == rhsAccent && lhsBlocks == rhsBlocks
        case (.ticket(let lhsID, let lhsTitle, let lhsStatus, let lhsIdentifier, let lhsMeta, let lhsBody),
              .ticket(let rhsID, let rhsTitle, let rhsStatus, let rhsIdentifier, let rhsMeta, let rhsBody)):
            let metaEqual = lhsMeta.count == rhsMeta.count && zip(lhsMeta, rhsMeta).allSatisfy { leftPair, rightPair in
                leftPair.key == rightPair.key && leftPair.value == rightPair.value
            }
            return lhsID == rhsID && lhsTitle == rhsTitle && lhsStatus == rhsStatus && lhsIdentifier == rhsIdentifier && metaEqual && lhsBody == rhsBody
        case (.receipt(let lhsID, let lhsTitle, let lhsRows, let lhsFooter), .receipt(let rhsID, let rhsTitle, let rhsRows, let rhsFooter)):
            return lhsID == rhsID && lhsTitle == rhsTitle && lhsRows == rhsRows && lhsFooter == rhsFooter
        case (.chart(let lhsID, let lhsTitle, let lhsBars), .chart(let rhsID, let rhsTitle, let rhsBars)):
            return lhsID == rhsID && lhsTitle == rhsTitle && lhsBars == rhsBars
        case (.todo(let lhsID, let lhsTitle, let lhsItems), .todo(let rhsID, let rhsTitle, let rhsItems)):
            return lhsID == rhsID && lhsTitle == rhsTitle && lhsItems == rhsItems
        case (.status(let lhsID, let lhsTitle, let lhsState, let lhsDetail), .status(let rhsID, let rhsTitle, let rhsState, let rhsDetail)):
            return lhsID == rhsID && lhsTitle == rhsTitle && lhsState == rhsState && lhsDetail == rhsDetail
        case (.progress(let lhsID, let lhsTitle, let lhsFraction, let lhsLabel, let lhsCaption),
              .progress(let rhsID, let rhsTitle, let rhsFraction, let rhsLabel, let rhsCaption)):
            return lhsID == rhsID && lhsTitle == rhsTitle && lhsFraction == rhsFraction && lhsLabel == rhsLabel && lhsCaption == rhsCaption
        default:
            return false
        }
    }
}

public nonisolated struct ClickyInkDocument: Sendable, Equatable {
    public let blocks: [ClickyInkBlock]

    public init(blocks: [ClickyInkBlock]) {
        self.blocks = blocks
    }
}

public nonisolated struct ClickyInkParser: Sendable {
    public init() {}

    public func parse(_ markdown: String) -> ClickyInkDocument {
        Self.parse(markdown)
    }

    public static func parse(_ markdown: String) -> ClickyInkDocument {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")
        let blocks = parseBlocks(from: rawLines, idPrefix: "root")
        return ClickyInkDocument(blocks: blocks)
    }

    // MARK: - Block Parsing

    private static func parseBlocks(from lines: [String], idPrefix: String) -> [ClickyInkBlock] {
        var parsedBlocks: [ClickyInkBlock] = []
        var lineIndex = 0
        var blockCounter = 0

        func nextBlockID(_ tag: String) -> String {
            blockCounter += 1
            return "\(idPrefix)-\(tag)-\(blockCounter)"
        }

        while lineIndex < lines.count {
            let currentLine = lines[lineIndex]
            let trimmedLine = currentLine.trimmingCharacters(in: .whitespaces)

            if trimmedLine.isEmpty {
                lineIndex += 1
                continue
            }

            // 1. Fenced code block
            if trimmedLine.hasPrefix("```") {
                let languageRaw = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language = languageRaw.isEmpty ? nil : languageRaw
                lineIndex += 1
                var codeLines: [String] = []
                while lineIndex < lines.count {
                    let candidate = lines[lineIndex]
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        lineIndex += 1
                        break
                    }
                    codeLines.append(candidate)
                    lineIndex += 1
                }
                parsedBlocks.append(
                    .codeBlock(
                        id: nextBlockID("code"),
                        language: language,
                        code: codeLines.joined(separator: "\n")
                    )
                )
                continue
            }

            // 2. Container directive (:::sticky, :::ticket, :::receipt, :::chart, :::todo, :::status, :::progress)
            if let opener = parseContainerOpener(trimmedLine) {
                lineIndex += 1
                var innerLines: [String] = []
                var nestedDepth = 1
                while lineIndex < lines.count {
                    let candidate = lines[lineIndex]
                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if candidateTrimmed == ":::" {
                        nestedDepth -= 1
                        if nestedDepth == 0 {
                            lineIndex += 1
                            break
                        }
                        innerLines.append(candidate)
                    } else if parseContainerOpener(candidateTrimmed) != nil {
                        nestedDepth += 1
                        innerLines.append(candidate)
                    } else {
                        innerLines.append(candidate)
                    }
                    lineIndex += 1
                }

                let blockID = nextBlockID(opener.kind.rawValue)
                let directiveBlock = buildContainerBlock(
                    id: blockID,
                    kind: opener.kind,
                    headerTitle: opener.title,
                    attributes: opener.attributes,
                    innerLines: innerLines
                )
                parsedBlocks.append(directiveBlock)
                continue
            }

            // 3. Thematic break
            if isThematicBreak(trimmedLine) {
                parsedBlocks.append(.thematicBreak(id: nextBlockID("hr")))
                lineIndex += 1
                continue
            }

            // 4. ATX Heading
            if let heading = parseHeading(trimmedLine) {
                parsedBlocks.append(
                    .heading(
                        id: nextBlockID("h\(heading.level)"),
                        level: heading.level,
                        inlines: parseInlines(heading.text)
                    )
                )
                lineIndex += 1
                continue
            }

            // 5. Blockquote
            if trimmedLine.hasPrefix(">") {
                var quoteLines: [String] = []
                while lineIndex < lines.count {
                    let candidateTrimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                    guard candidateTrimmed.hasPrefix(">") else { break }
                    var stripped = String(candidateTrimmed.dropFirst())
                    if stripped.hasPrefix(" ") {
                        stripped = String(stripped.dropFirst())
                    }
                    quoteLines.append(stripped)
                    lineIndex += 1
                }
                let joined = quoteLines.joined(separator: "\n")
                parsedBlocks.append(
                    .blockquote(
                        id: nextBlockID("quote"),
                        inlines: parseInlines(joined)
                    )
                )
                continue
            }

            // 6. Markdown Table
            if trimmedLine.hasPrefix("|"),
               lineIndex + 1 < lines.count,
               isTableSeparatorRow(lines[lineIndex + 1].trimmingCharacters(in: .whitespaces)) {
                let headerCells = splitTableRow(trimmedLine).map { parseInlines($0) }
                lineIndex += 2 // skip header and separator
                var bodyRows: [[[ClickyInkInlineNode]]] = []
                while lineIndex < lines.count {
                    let rowTrimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                    guard rowTrimmed.hasPrefix("|") else { break }
                    bodyRows.append(splitTableRow(rowTrimmed).map { parseInlines($0) })
                    lineIndex += 1
                }
                parsedBlocks.append(
                    .table(id: nextBlockID("table"), headers: headerCells, rows: bodyRows)
                )
                continue
            }

            // 7. Checklist (- [ ] or - [x] or * [ ] or * [x])
            if parseChecklistLine(trimmedLine) != nil {
                var checklistItems: [ClickyInkTodoItem] = []
                let listID = nextBlockID("checklist")
                var itemNumber = 0
                while lineIndex < lines.count {
                    let candidateTrimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                    guard let parsedItem = parseChecklistLine(candidateTrimmed) else { break }
                    itemNumber += 1
                    checklistItems.append(
                        ClickyInkTodoItem(
                            id: "\(listID)-item-\(itemNumber)",
                            isChecked: parsedItem.isChecked,
                            inlines: parseInlines(parsedItem.text),
                            plainText: parsedItem.text
                        )
                    )
                    lineIndex += 1
                }
                parsedBlocks.append(.checklist(id: listID, items: checklistItems))
                continue
            }

            // 8. Unordered List
            if let firstBullet = parseUnorderedListLine(trimmedLine) {
                var bulletItems: [[ClickyInkInlineNode]] = [parseInlines(firstBullet)]
                lineIndex += 1
                while lineIndex < lines.count {
                    let candidateTrimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                    if parseChecklistLine(candidateTrimmed) != nil { break }
                    guard let bulletText = parseUnorderedListLine(candidateTrimmed) else { break }
                    bulletItems.append(parseInlines(bulletText))
                    lineIndex += 1
                }
                parsedBlocks.append(.unorderedList(id: nextBlockID("ul"), items: bulletItems))
                continue
            }

            // 9. Ordered List
            if let firstOrdered = parseOrderedListLine(trimmedLine) {
                var orderedItems: [[ClickyInkInlineNode]] = [parseInlines(firstOrdered)]
                lineIndex += 1
                while lineIndex < lines.count {
                    let candidateTrimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                    guard let itemText = parseOrderedListLine(candidateTrimmed) else { break }
                    orderedItems.append(parseInlines(itemText))
                    lineIndex += 1
                }
                parsedBlocks.append(.orderedList(id: nextBlockID("ol"), items: orderedItems))
                continue
            }

            // 10. Paragraph (collect contiguous non-empty, non-block lines)
            var paragraphLines: [String] = [trimmedLine]
            lineIndex += 1
            while lineIndex < lines.count {
                let nextTrimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || startsSpecialBlock(nextTrimmed, nextLine: lineIndex + 1 < lines.count ? lines[lineIndex + 1] : nil) {
                    break
                }
                paragraphLines.append(nextTrimmed)
                lineIndex += 1
            }
            let paragraphText = paragraphLines.joined(separator: " ")
            parsedBlocks.append(
                .paragraph(id: nextBlockID("p"), inlines: parseInlines(paragraphText))
            )
        }

        return parsedBlocks
    }

    private static func startsSpecialBlock(_ trimmedLine: String, nextLine: String?) -> Bool {
        if trimmedLine.hasPrefix("```")
            || parseContainerOpener(trimmedLine) != nil
            || trimmedLine == ":::"
            || isThematicBreak(trimmedLine)
            || parseHeading(trimmedLine) != nil
            || trimmedLine.hasPrefix(">")
            || parseChecklistLine(trimmedLine) != nil
            || parseUnorderedListLine(trimmedLine) != nil
            || parseOrderedListLine(trimmedLine) != nil {
            return true
        }
        if trimmedLine.hasPrefix("|"),
           let nextLine,
           isTableSeparatorRow(nextLine.trimmingCharacters(in: .whitespaces)) {
            return true
        }
        return false
    }

    // MARK: - Container Directive Parsing

    private struct ContainerOpener {
        let kind: ClickyInkContainerKind
        let title: String?
        let attributes: [String: String]
    }

    private static func parseContainerOpener(_ trimmedLine: String) -> ContainerOpener? {
        guard trimmedLine.hasPrefix(":::") else { return nil }
        let remainder = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        // Extract kind name (letters)
        var kindEndIndex = remainder.startIndex
        while kindEndIndex < remainder.endIndex, remainder[kindEndIndex].isLetter {
            kindEndIndex = remainder.index(after: kindEndIndex)
        }
        let kindToken = String(remainder[..<kindEndIndex]).lowercased()
        guard let kind = ClickyInkContainerKind(rawValue: kindToken) else {
            return nil
        }

        var rest = String(remainder[kindEndIndex...]).trimmingCharacters(in: .whitespaces)
        var titleText: String?
        var attributes: [String: String] = [:]

        // Optional [Title]
        if rest.hasPrefix("["), let closeBracket = rest.firstIndex(of: "]") {
            let bracketStart = rest.index(after: rest.startIndex)
            let captured = String(rest[bracketStart..<closeBracket]).trimmingCharacters(in: .whitespaces)
            if !captured.isEmpty {
                titleText = captured
            }
            rest = String(rest[rest.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
        }

        // Optional {key=value ...} or {key="value" ...}
        if rest.hasPrefix("{"), let closeBrace = rest.firstIndex(of: "}") {
            let braceStart = rest.index(after: rest.startIndex)
            let attributeString = String(rest[braceStart..<closeBrace])
            attributes = parseAttributes(attributeString)
            rest = String(rest[rest.index(after: closeBrace)...]).trimmingCharacters(in: .whitespaces)
        }

        if titleText == nil {
            if let attrTitle = attributes["title"], !attrTitle.isEmpty {
                titleText = attrTitle
            } else if !rest.isEmpty {
                titleText = rest
            }
        }

        return ContainerOpener(kind: kind, title: titleText, attributes: attributes)
    }

    private static func parseAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = raw.startIndex

        while index < raw.endIndex {
            while index < raw.endIndex, raw[index].isWhitespace || raw[index] == "," {
                index = raw.index(after: index)
            }
            guard index < raw.endIndex else { break }

            let keyStart = index
            while index < raw.endIndex, raw[index] != "=" && !raw[index].isWhitespace {
                index = raw.index(after: index)
            }
            let key = String(raw[keyStart..<index]).trimmingCharacters(in: .whitespaces).lowercased()
            guard index < raw.endIndex, raw[index] == "=" else {
                if !key.isEmpty {
                    result[key] = "true"
                }
                continue
            }
            index = raw.index(after: index) // skip '='
            guard index < raw.endIndex else { break }

            let value: String
            if raw[index] == "\"" || raw[index] == "'" {
                let quoteChar = raw[index]
                index = raw.index(after: index)
                let valStart = index
                while index < raw.endIndex, raw[index] != quoteChar {
                    index = raw.index(after: index)
                }
                value = String(raw[valStart..<index])
                if index < raw.endIndex {
                    index = raw.index(after: index)
                }
            } else {
                let valStart = index
                while index < raw.endIndex, !raw[index].isWhitespace {
                    index = raw.index(after: index)
                }
                value = String(raw[valStart..<index])
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private static func buildContainerBlock(
        id: String,
        kind: ClickyInkContainerKind,
        headerTitle: String?,
        attributes: [String: String],
        innerLines: [String]
    ) -> ClickyInkBlock {
        switch kind {
        case .sticky:
            let accentName = attributes["color"] ?? attributes["tone"]
            let bodyBlocks = parseBlocks(from: innerLines, idPrefix: id)
            return .sticky(id: id, title: headerTitle, accentName: accentName, bodyBlocks: bodyBlocks)

        case .ticket:
            var title = headerTitle ?? attributes["title"] ?? "Ticket"
            var statusText = attributes["status"]
            var identifier = attributes["id"] ?? attributes["key"]
            var metadata: [(key: String, value: String)] = []
            var bodyLines: [String] = []

            for line in innerLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let pair = splitKeyValueLine(trimmed) {
                    let lowerKey = pair.key.lowercased()
                    if lowerKey == "title" {
                        title = pair.value
                    } else if lowerKey == "status" {
                        statusText = pair.value
                    } else if lowerKey == "id" || lowerKey == "ticket" || lowerKey == "key" {
                        identifier = pair.value
                    } else {
                        metadata.append((key: pair.key, value: pair.value))
                    }
                } else {
                    bodyLines.append(trimmed)
                }
            }

            return .ticket(
                id: id,
                title: title,
                statusText: statusText,
                identifier: identifier,
                metadata: metadata,
                bodyInlines: parseInlines(bodyLines.joined(separator: " "))
            )

        case .receipt:
            var title = headerTitle ?? "Receipt"
            var rows: [ClickyInkReceiptRow] = []
            var footerLines: [String] = []
            var rowCounter = 0

            for line in innerLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if trimmed.hasPrefix("---") || trimmed.hasPrefix("===") {
                    continue
                }
                if let pair = splitReceiptLine(trimmed) {
                    let lowerLabel = pair.label.lowercased()
                    if lowerLabel == "title" {
                        title = pair.amount
                    } else {
                        rowCounter += 1
                        let isTotal = lowerLabel == "total" || lowerLabel == "grand total" || lowerLabel == "amount due"
                        rows.append(
                            ClickyInkReceiptRow(
                                id: "\(id)-row-\(rowCounter)",
                                label: pair.label,
                                amount: pair.amount,
                                isTotal: isTotal
                            )
                        )
                    }
                } else {
                    footerLines.append(trimmed)
                }
            }

            let footer = footerLines.isEmpty ? nil : footerLines.joined(separator: " ")
            return .receipt(id: id, title: title, rows: rows, footerNote: footer)

        case .chart:
            let title = headerTitle ?? attributes["title"] ?? "Breakdown"
            var bars: [ClickyInkChartBar] = []
            var barCounter = 0

            for line in innerLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let parsedBar = parseChartBarLine(trimmed) {
                    barCounter += 1
                    bars.append(
                        ClickyInkChartBar(
                            id: "\(id)-bar-\(barCounter)",
                            label: parsedBar.label,
                            value: parsedBar.value,
                            displayValue: parsedBar.displayValue
                        )
                    )
                }
            }
            return .chart(id: id, title: title, bars: bars)

        case .todo:
            let title = headerTitle ?? attributes["title"] ?? "To-Do"
            var items: [ClickyInkTodoItem] = []
            var itemCounter = 0

            for line in innerLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                itemCounter += 1
                if let parsedCheck = parseChecklistLine(trimmed) {
                    items.append(
                        ClickyInkTodoItem(
                            id: "\(id)-todo-\(itemCounter)",
                            isChecked: parsedCheck.isChecked,
                            inlines: parseInlines(parsedCheck.text),
                            plainText: parsedCheck.text
                        )
                    )
                } else if let bullet = parseUnorderedListLine(trimmed) {
                    items.append(
                        ClickyInkTodoItem(
                            id: "\(id)-todo-\(itemCounter)",
                            isChecked: false,
                            inlines: parseInlines(bullet),
                            plainText: bullet
                        )
                    )
                } else {
                    items.append(
                        ClickyInkTodoItem(
                            id: "\(id)-todo-\(itemCounter)",
                            isChecked: false,
                            inlines: parseInlines(trimmed),
                            plainText: trimmed
                        )
                    )
                }
            }
            return .todo(id: id, title: title, items: items)

        case .status:
            var title = headerTitle ?? attributes["title"] ?? "Status"
            var stateLabel = attributes["state"] ?? attributes["status"] ?? "Active"
            var detailLines: [String] = []

            for line in innerLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let pair = splitKeyValueLine(trimmed) {
                    let lower = pair.key.lowercased()
                    if lower == "title" || lower == "label" {
                        title = pair.value
                    } else if lower == "state" || lower == "status" {
                        stateLabel = pair.value
                    } else {
                        detailLines.append("\(pair.key): \(pair.value)")
                    }
                } else {
                    detailLines.append(trimmed)
                }
            }

            return .status(
                id: id,
                title: title,
                stateLabel: stateLabel,
                detailInlines: parseInlines(detailLines.joined(separator: " "))
            )

        case .progress:
            var title = headerTitle ?? attributes["title"] ?? "Progress"
            var fraction = parseFraction(from: attributes["value"] ?? attributes["progress"] ?? "")
            var valueLabel = attributes["label"]
            var captionLines: [String] = []

            for line in innerLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let pair = splitKeyValueLine(trimmed) {
                    let lower = pair.key.lowercased()
                    if lower == "title" {
                        title = pair.value
                    } else if lower == "value" || lower == "progress" || lower == "percent" || lower == "completion" {
                        if let parsed = parseFraction(from: pair.value) {
                            fraction = parsed
                        }
                        if valueLabel == nil {
                            valueLabel = pair.value
                        }
                    } else if lower == "caption" || lower == "detail" || lower == "note" {
                        captionLines.append(pair.value)
                    } else {
                        captionLines.append("\(pair.key): \(pair.value)")
                    }
                } else if fraction == nil, let parsed = parseFraction(from: trimmed) {
                    fraction = parsed
                    if valueLabel == nil {
                        valueLabel = trimmed
                    }
                } else {
                    captionLines.append(trimmed)
                }
            }

            let resolvedFraction = min(1.0, max(0.0, fraction ?? 0.0))
            let resolvedValueLabel = valueLabel ?? "\(Int((resolvedFraction * 100.0).rounded()))%"
            let caption = captionLines.isEmpty ? nil : captionLines.joined(separator: " ")

            return .progress(
                id: id,
                title: title,
                fraction: resolvedFraction,
                valueLabel: resolvedValueLabel,
                caption: caption
            )
        }
    }

    // MARK: - Inline Parsing

    public static func parseInlines(_ input: String) -> [ClickyInkInlineNode] {
        guard !input.isEmpty else { return [] }

        var nodes: [ClickyInkInlineNode] = []
        var currentText = ""
        var index = input.startIndex

        func flushText() {
            if !currentText.isEmpty {
                nodes.append(.text(currentText))
                currentText = ""
            }
        }

        while index < input.endIndex {
            // Check inline directives: ::ask[...], ::question[...], ::link[...]
            if input[index...].hasPrefix("::") {
                if let directiveMatch = parseInlineDirective(in: input, from: index) {
                    flushText()
                    nodes.append(directiveMatch.node)
                    index = directiveMatch.nextIndex
                    continue
                }
            }

            // Check inline badges: {new}, {needs}, {done}, {pick}, {now}, {gone}
            if input[index] == "{" {
                if let closeBrace = input[index...].firstIndex(of: "}") {
                    let tokenStart = input.index(after: index)
                    let token = String(input[tokenStart..<closeBrace]).trimmingCharacters(in: .whitespaces).lowercased()
                    if let badgeKind = ClickyInkBadgeKind(rawValue: token) {
                        flushText()
                        nodes.append(.badge(badgeKind))
                        index = input.index(after: closeBrace)
                        continue
                    }
                }
            }

            currentText.append(input[index])
            index = input.index(after: index)
        }

        flushText()
        return nodes
    }

    private static func parseInlineDirective(
        in input: String,
        from startIndex: String.Index
    ) -> (node: ClickyInkInlineNode, nextIndex: String.Index)? {
        let slice = input[startIndex...]
        let directiveKind: String
        let prefixLength: Int

        if slice.hasPrefix("::ask[") {
            directiveKind = "ask"
            prefixLength = 6
        } else if slice.hasPrefix("::question[") {
            directiveKind = "question"
            prefixLength = 11
        } else if slice.hasPrefix("::link[") {
            directiveKind = "link"
            prefixLength = 7
        } else {
            return nil
        }

        let labelStart = input.index(startIndex, offsetBy: prefixLength)
        guard let labelEnd = input[labelStart...].firstIndex(of: "]") else {
            return nil
        }

        let labelText = String(input[labelStart..<labelEnd]).trimmingCharacters(in: .whitespaces)
        var cursor = input.index(after: labelEnd)
        var payload: String?

        // Optional (url or prompt)
        if cursor < input.endIndex, input[cursor] == "(" {
            let parenStart = input.index(after: cursor)
            if let parenEnd = input[parenStart...].firstIndex(of: ")") {
                payload = String(input[parenStart..<parenEnd]).trimmingCharacters(in: .whitespaces)
                cursor = input.index(after: parenEnd)
            }
        } else if cursor < input.endIndex, input[cursor] == "{" {
            // Optional {prompt="..." or url="..."}
            let braceStart = input.index(after: cursor)
            if let braceEnd = input[braceStart...].firstIndex(of: "}") {
                let attrRaw = String(input[braceStart..<braceEnd])
                let attrs = parseAttributes(attrRaw)
                payload = attrs["prompt"] ?? attrs["url"] ?? attrs["href"] ?? attrs["action"]
                cursor = input.index(after: braceEnd)
            }
        }

        switch directiveKind {
        case "ask":
            let prompt = (payload?.isEmpty == false) ? payload! : labelText
            return (.ask(label: labelText, prompt: prompt), cursor)
        case "question":
            let prompt = (payload?.isEmpty == false) ? payload! : labelText
            return (.question(label: labelText, prompt: prompt), cursor)
        case "link":
            let url = (payload?.isEmpty == false) ? payload! : labelText
            return (.link(title: labelText, url: url), cursor)
        default:
            return nil
        }
    }

    // MARK: - Line Helpers

    private static func isThematicBreak(_ trimmedLine: String) -> Bool {
        let compact = trimmedLine.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { character in character == "-" }
            || compact.allSatisfy { character in character == "*" }
            || compact.allSatisfy { character in character == "_" }
    }

    private static func parseHeading(_ trimmedLine: String) -> (level: Int, text: String)? {
        var level = 0
        var index = trimmedLine.startIndex
        while index < trimmedLine.endIndex, trimmedLine[index] == "#", level < 6 {
            level += 1
            index = trimmedLine.index(after: index)
        }
        guard level > 0, index < trimmedLine.endIndex, trimmedLine[index] == " " else {
            return nil
        }
        let text = String(trimmedLine[index...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func parseChecklistLine(_ trimmedLine: String) -> (isChecked: Bool, text: String)? {
        let prefixes = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "]
        for prefix in prefixes {
            if trimmedLine.hasPrefix(prefix) {
                let isChecked = prefix.contains("x") || prefix.contains("X")
                let text = String(trimmedLine.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return (isChecked, text)
            }
        }
        if trimmedLine == "- [ ]" || trimmedLine == "* [ ]" {
            return (false, "")
        }
        if trimmedLine == "- [x]" || trimmedLine == "- [X]" || trimmedLine == "* [x]" || trimmedLine == "* [X]" {
            return (true, "")
        }
        return nil
    }

    private static func parseUnorderedListLine(_ trimmedLine: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if trimmedLine.hasPrefix(prefix) {
                return String(trimmedLine.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func parseOrderedListLine(_ trimmedLine: String) -> String? {
        var digitCount = 0
        var index = trimmedLine.startIndex
        while index < trimmedLine.endIndex, trimmedLine[index].isNumber {
            digitCount += 1
            index = trimmedLine.index(after: index)
        }
        guard digitCount > 0, index < trimmedLine.endIndex, trimmedLine[index] == "." else {
            return nil
        }
        let afterDot = trimmedLine.index(after: index)
        guard afterDot < trimmedLine.endIndex, trimmedLine[afterDot] == " " else {
            return nil
        }
        return String(trimmedLine[trimmedLine.index(after: afterDot)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isTableSeparatorRow(_ trimmedLine: String) -> Bool {
        guard trimmedLine.hasPrefix("|") else { return false }
        let cells = splitTableRow(trimmedLine)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.replacingOccurrences(of: " ", with: "")
            return !compact.isEmpty && compact.allSatisfy { ch in ch == "-" || ch == ":" }
        }
    }

    private static func splitTableRow(_ trimmedLine: String) -> [String] {
        var working = trimmedLine
        if working.hasPrefix("|") {
            working = String(working.dropFirst())
        }
        if working.hasSuffix("|") {
            working = String(working.dropLast())
        }
        return working.components(separatedBy: "|").map { cell in
            cell.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func splitKeyValueLine(_ line: String) -> (key: String, value: String)? {
        let stripped = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        guard let colonIndex = stripped.firstIndex(of: ":") else { return nil }
        let key = String(stripped[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let value = String(stripped[stripped.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty, key.count <= 32 else { return nil }
        return (key, value)
    }

    private static func splitReceiptLine(_ line: String) -> (label: String, amount: String)? {
        let stripped = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        if let pipeIndex = stripped.firstIndex(of: "|") {
            let label = String(stripped[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
            let amount = String(stripped[stripped.index(after: pipeIndex)...]).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty && !amount.isEmpty {
                return (label, amount)
            }
        }
        if let colonIndex = stripped.firstIndex(of: ":") {
            let label = String(stripped[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let amount = String(stripped[stripped.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty && !amount.isEmpty {
                return (label, amount)
            }
        }
        return nil
    }

    private static func parseChartBarLine(_ line: String) -> (label: String, value: Double, displayValue: String)? {
        let stripped = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        let labelPart: String
        let valuePart: String

        if let pipeIndex = stripped.firstIndex(of: "|") {
            labelPart = String(stripped[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
            valuePart = String(stripped[stripped.index(after: pipeIndex)...]).trimmingCharacters(in: .whitespaces)
        } else if let colonIndex = stripped.firstIndex(of: ":") {
            labelPart = String(stripped[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            valuePart = String(stripped[stripped.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        guard !labelPart.isEmpty, !valuePart.isEmpty else { return nil }
        let numericString = valuePart.filter { character in
            character.isNumber || character == "." || character == "-"
        }
        guard let numericValue = Double(numericString) else { return nil }
        return (labelPart, numericValue, valuePart)
    }

    private static func parseFraction(from rawText: String) -> Double? {
        let trimmed = rawText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("%") {
            let numberPart = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            if let percent = Double(numberPart) {
                return percent / 100.0
            }
        }

        if let slashIndex = trimmed.firstIndex(of: "/") {
            let numeratorPart = String(trimmed[..<slashIndex]).trimmingCharacters(in: .whitespaces)
            let denominatorPart = String(trimmed[trimmed.index(after: slashIndex)...]).trimmingCharacters(in: .whitespaces)
            if let numerator = Double(numeratorPart),
               let denominator = Double(denominatorPart),
               denominator > 0 {
                return numerator / denominator
            }
        }

        if let rawValue = Double(trimmed) {
            return rawValue > 1.0 ? rawValue / 100.0 : rawValue
        }

        return nil
    }
}
