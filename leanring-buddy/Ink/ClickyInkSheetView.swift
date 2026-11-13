//
//  ClickyInkSheetView.swift
//  leanring-buddy
//
//  Renders ClickyInk Live Note Markdown into rich interactive SwiftUI cards:
//  sticky notes, tickets, receipts, bar charts, checklists, status & progress cards,
//  inline status badges ({new}/{needs}/{done}/{pick}/{now}/{gone}), and clickable
//  ::ask / ::question / ::link action pills.
//

import AppKit
import Combine
import Foundation
import SwiftUI

public struct ClickyInkSheetView: View {
    public let markdown: String
    public let title: String?
    public let onAction: ((String) -> Void)?

    @State private var checkboxOverrides: [String: Bool] = [:]
    @State private var didCopyMarkdown: Bool = false

    public init(
        markdown: String,
        title: String? = nil,
        onAction: ((String) -> Void)? = nil
    ) {
        self.markdown = markdown
        self.title = title
        self.onAction = onAction
    }

    private var parsedDocument: ClickyInkDocument {
        ClickyInkParser.parse(markdown)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sheetHeader(title: title)
            }

            if parsedDocument.blocks.isEmpty {
                emptyNotePlaceholder
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    ForEach(parsedDocument.blocks) { block in
                        blockView(for: block)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header & Empty State

    private func sheetHeader(title: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "note.text")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            Button(action: copyMarkdownToPasteboard) {
                HStack(spacing: 4) {
                    Image(systemName: didCopyMarkdown ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(didCopyMarkdown ? "Copied" : "Copy")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(didCopyMarkdown ? DS.Colors.success : DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    Capsule()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.bottom, DS.Spacing.xs)
    }

    private var emptyNotePlaceholder: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
            Text("No live note content yet.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Block Renderer

    private func blockView(for block: ClickyInkBlock) -> AnyView {
        switch block {
        case .heading(_, let level, let inlines):
            return AnyView(headingView(level: level, inlines: inlines))

        case .paragraph(_, let inlines):
            return AnyView(inlineContentView(inlines: inlines, fontSize: 13, textColor: DS.Colors.textPrimary))

        case .blockquote(_, let inlines):
            return AnyView(blockquoteView(inlines: inlines))

        case .codeBlock(_, let language, let code):
            return AnyView(codeBlockView(language: language, code: code))

        case .unorderedList(_, let items):
            return AnyView(unorderedListView(items: items))

        case .orderedList(_, let items):
            return AnyView(orderedListView(items: items))

        case .checklist(_, let items):
            return AnyView(checklistItemsView(items: items))

        case .table(_, let headers, let rows):
            return AnyView(tableView(headers: headers, rows: rows))

        case .thematicBreak:
            return AnyView(
                Rectangle()
                    .fill(DS.Colors.borderSubtle)
                    .frame(height: 1)
                    .padding(.vertical, DS.Spacing.xs)
            )

        case .sticky(_, let stickyTitle, let accentName, let bodyBlocks):
            return AnyView(stickyCardView(title: stickyTitle, accentName: accentName, bodyBlocks: bodyBlocks))

        case .ticket(_, let ticketTitle, let statusText, let identifier, let metadata, let bodyInlines):
            return AnyView(
                ticketCardView(
                    title: ticketTitle,
                    statusText: statusText,
                    identifier: identifier,
                    metadata: metadata,
                    bodyInlines: bodyInlines
                )
            )

        case .receipt(_, let receiptTitle, let rows, let footerNote):
            return AnyView(receiptCardView(title: receiptTitle, rows: rows, footerNote: footerNote))

        case .chart(_, let chartTitle, let bars):
            return AnyView(chartCardView(title: chartTitle, bars: bars))

        case .todo(_, let todoTitle, let items):
            return AnyView(todoCardView(title: todoTitle, items: items))

        case .status(_, let statusTitle, let stateLabel, let detailInlines):
            return AnyView(statusCardView(title: statusTitle, stateLabel: stateLabel, detailInlines: detailInlines))

        case .progress(_, let progressTitle, let fraction, let valueLabel, let caption):
            return AnyView(
                progressCardView(
                    title: progressTitle,
                    fraction: fraction,
                    valueLabel: valueLabel,
                    caption: caption
                )
            )
        }
    }

    private func headingView(level: Int, inlines: [ClickyInkInlineNode]) -> some View {
        let fontSize: CGFloat
        switch level {
        case 1: fontSize = 19
        case 2: fontSize = 16
        case 3: fontSize = 14.5
        default: fontSize = 13.5
        }
        return inlineContentView(
            inlines: inlines,
            fontSize: fontSize,
            fontWeight: .semibold,
            textColor: DS.Colors.textPrimary
        )
        .padding(.top, level <= 2 ? 4 : 2)
    }

    private func blockquoteView(inlines: [ClickyInkInlineNode]) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            RoundedRectangle(cornerRadius: 2)
                .fill(DS.Colors.blue400.opacity(0.75))
                .frame(width: 3)

            inlineContentView(
                inlines: inlines,
                fontSize: 13,
                textColor: DS.Colors.textSecondary
            )
        }
        .padding(.vertical, 4)
        .padding(.horizontal, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                .fill(DS.Colors.surface1.opacity(0.65))
        )
    }

    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.codeText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(DS.Colors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func unorderedListView(items: [[ClickyInkInlineNode]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, itemInlines in
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Circle()
                        .fill(DS.Colors.blue400)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)

                    inlineContentView(inlines: itemInlines, fontSize: 13, textColor: DS.Colors.textPrimary)
                }
            }
        }
    }

    private func orderedListView(items: [[ClickyInkInlineNode]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, itemInlines in
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Text("\(itemIndex + 1).")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.accentText)
                        .frame(minWidth: 18, alignment: .trailing)

                    inlineContentView(inlines: itemInlines, fontSize: 13, textColor: DS.Colors.textPrimary)
                }
            }
        }
    }

    private func checklistItemsView(items: [ClickyInkTodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items) { todoItem in
                todoRow(todoItem)
            }
        }
    }

    private func todoRow(_ todoItem: ClickyInkTodoItem) -> some View {
        let isChecked = checkboxOverrides[todoItem.id] ?? todoItem.isChecked

        return HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Button(action: {
                withAnimation(.easeOut(duration: DS.Animation.fast)) {
                    checkboxOverrides[todoItem.id] = !isChecked
                }
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isChecked ? DS.Colors.success.opacity(0.22) : DS.Colors.surface2)
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isChecked ? DS.Colors.success : DS.Colors.borderStrong, lineWidth: 1.2)
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(DS.Colors.success)
                    }
                }
                .frame(width: 17, height: 17)
                .padding(.top, 1)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            inlineContentView(
                inlines: todoItem.inlines,
                fontSize: 13,
                textColor: isChecked ? DS.Colors.textTertiary : DS.Colors.textPrimary,
                strikethrough: isChecked
            )
        }
    }

    private func tableView(headers: [[ClickyInkInlineNode]], rows: [[[ClickyInkInlineNode]]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { columnIndex, cellInlines in
                        inlineContentView(
                            inlines: cellInlines,
                            fontSize: 12,
                            fontWeight: .semibold,
                            textColor: DS.Colors.textPrimary
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(minWidth: 110, alignment: .leading)
                        .background(DS.Colors.surface2)
                        if columnIndex < headers.count - 1 {
                            Rectangle()
                                .fill(DS.Colors.borderSubtle.opacity(0.6))
                                .frame(width: 1)
                        }
                    }
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowCells in
                    Rectangle()
                        .fill(DS.Colors.borderSubtle.opacity(0.6))
                        .frame(height: 1)

                    HStack(spacing: 0) {
                        ForEach(Array(rowCells.enumerated()), id: \.offset) { columnIndex, cellInlines in
                            inlineContentView(
                                inlines: cellInlines,
                                fontSize: 12,
                                textColor: DS.Colors.textSecondary
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(minWidth: 110, alignment: .leading)
                            .background(rowIndex.isMultiple(of: 2) ? DS.Colors.surface1 : DS.Colors.surface1.opacity(0.65))
                            if columnIndex < rowCells.count - 1 {
                                Rectangle()
                                    .fill(DS.Colors.borderSubtle.opacity(0.4))
                                    .frame(width: 1)
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
    }

    // MARK: - Rich Directive Cards

    private func stickyCardView(
        title: String?,
        accentName: String?,
        bodyBlocks: [ClickyInkBlock]
    ) -> some View {
        let tintColor = stickyAccentColor(named: accentName)

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tintColor)

                Text(title ?? "Sticky Note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tintColor)

                Spacer()
            }

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                ForEach(bodyBlocks) { innerBlock in
                    blockView(for: innerBlock)
                }
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(tintColor.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(tintColor.opacity(0.38), lineWidth: 1)
        )
    }

    private func stickyAccentColor(named accentName: String?) -> Color {
        switch accentName?.lowercased() {
        case "blue", "sky": return DS.Colors.blue400
        case "green", "mint", "emerald": return DS.Colors.success
        case "red", "rose", "pink": return DS.Colors.destructiveText
        default: return DS.Colors.warning
        }
    }

    private func ticketCardView(
        title: String,
        statusText: String?,
        identifier: String?,
        metadata: [(key: String, value: String)],
        bodyInlines: [ClickyInkInlineNode]
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "ticket.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.info)

                if let identifier, !identifier.isEmpty {
                    Text(identifier)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.surface3))
                }

                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)

                Spacer()

                if let statusText, !statusText.isEmpty {
                    ClickyInkStatusPill(label: statusText)
                }
            }

            if !metadata.isEmpty {
                ClickyInkFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(Array(metadata.enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 4) {
                            Text("\(pair.key):")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.textTertiary)
                            Text(pair.value)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                                .fill(DS.Colors.surface2)
                        )
                    }
                }
            }

            if !bodyInlines.isEmpty {
                inlineContentView(inlines: bodyInlines, fontSize: 12.5, textColor: DS.Colors.textSecondary)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func receiptCardView(
        title: String,
        rows: [ClickyInkReceiptRow],
        footerNote: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "receipt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.success)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()
            }

            ClickyInkDashedDivider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    if row.isTotal {
                        ClickyInkDashedDivider()
                            .padding(.vertical, 2)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(.system(
                                size: row.isTotal ? 13 : 12,
                                weight: row.isTotal ? .semibold : .regular
                            ))
                            .foregroundColor(row.isTotal ? DS.Colors.textPrimary : DS.Colors.textSecondary)

                        Spacer()

                        Text(row.amount)
                            .font(.system(
                                size: row.isTotal ? 13 : 12,
                                weight: row.isTotal ? .bold : .medium,
                                design: .monospaced
                            ))
                            .foregroundColor(row.isTotal ? DS.Colors.success : DS.Colors.textPrimary)
                    }
                }
            }

            if let footerNote, !footerNote.isEmpty {
                Text(footerNote)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 2)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func chartCardView(title: String, bars: [ClickyInkChartBar]) -> some View {
        let maxValue = max(bars.map { abs($0.value) }.max() ?? 1.0, 0.0001)

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.blue400)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(bars.enumerated()), id: \.element.id) { barIndex, bar in
                    let normalizedRatio = min(1.0, max(0.04, abs(bar.value) / maxValue))
                    let barColor = chartBarColor(at: barIndex)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(bar.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                            Spacer()
                            Text(bar.displayValue)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(DS.Colors.textPrimary)
                        }

                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(DS.Colors.surface2)
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [barColor.opacity(0.85), barColor],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(8, geometry.size.width * normalizedRatio))
                            }
                        }
                        .frame(height: 8)
                    }
                }
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func chartBarColor(at index: Int) -> Color {
        let palette: [Color] = [
            DS.Colors.blue400,
            DS.Colors.success,
            DS.Colors.info,
            DS.Colors.warning,
            Color(hex: "#A78BFA")
        ]
        return palette[index % palette.count]
    }

    private func todoCardView(title: String, items: [ClickyInkTodoItem]) -> some View {
        let completedCount = items.filter { item in
            checkboxOverrides[item.id] ?? item.isChecked
        }.count

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.success)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }

                Spacer()

                Text("\(completedCount)/\(items.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.surface2))
            }

            checklistItemsView(items: items)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func statusCardView(
        title: String,
        stateLabel: String,
        detailInlines: [ClickyInkInlineNode]
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                ClickyInkStatusPill(label: stateLabel)
            }

            if !detailInlines.isEmpty {
                inlineContentView(inlines: detailInlines, fontSize: 12.5, textColor: DS.Colors.textSecondary)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func progressCardView(
        title: String,
        fraction: Double,
        valueLabel: String,
        caption: String?
    ) -> some View {
        let clamped = min(1.0, max(0.0, fraction))

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Text(valueLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.accentText)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DS.Colors.surface2)
                        .overlay(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )

                    if clamped > 0 {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [DS.Colors.blue400, DS.Colors.blue600],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.45), Color.clear],
                                            startPoint: .top,
                                            endPoint: .center
                                        )
                                    )
                                    .padding(1.5)
                            )
                            .frame(width: max(12, geometry.size.width * clamped))
                    }
                }
            }
            .frame(height: 10)

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Inline Renderer

    @ViewBuilder
    private func inlineContentView(
        inlines: [ClickyInkInlineNode],
        fontSize: CGFloat,
        fontWeight: Font.Weight = .regular,
        textColor: Color,
        strikethrough: Bool = false
    ) -> some View {
        let containsInteractiveOrBadge = inlines.contains { node in
            if case .text = node { return false }
            return true
        }

        if !containsInteractiveOrBadge {
            let mergedText = inlines.compactMap { node -> String? in
                if case .text(let content) = node { return content }
                return nil
            }.joined()
            markdownTextView(
                mergedText,
                fontSize: fontSize,
                fontWeight: fontWeight,
                textColor: textColor,
                strikethrough: strikethrough
            )
        } else {
            ClickyInkFlowLayout(horizontalSpacing: 6, verticalSpacing: 5) {
                ForEach(Array(inlines.enumerated()), id: \.offset) { _, node in
                    switch node {
                    case .text(let rawText):
                        let trimmed = rawText.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            markdownTextView(
                                trimmed,
                                fontSize: fontSize,
                                fontWeight: fontWeight,
                                textColor: textColor,
                                strikethrough: strikethrough
                            )
                        }

                    case .badge(let badgeKind):
                        ClickyInkBadgePill(kind: badgeKind)

                    case .ask(let label, let prompt):
                        ClickyInkActionButton(
                            iconName: "sparkles",
                            label: label,
                            tintColor: DS.Colors.blue400,
                            onTap: {
                                onAction?(prompt)
                            }
                        )

                    case .question(let label, let prompt):
                        ClickyInkActionButton(
                            iconName: "questionmark.circle.fill",
                            label: label,
                            tintColor: DS.Colors.warning,
                            onTap: {
                                onAction?(prompt)
                            }
                        )

                    case .link(let linkTitle, let urlString):
                        ClickyInkLinkChip(title: linkTitle, urlString: urlString, onFallbackAction: onAction)
                    }
                }
            }
        }
    }

    private func markdownTextView(
        _ rawText: String,
        fontSize: CGFloat,
        fontWeight: Font.Weight,
        textColor: Color,
        strikethrough: Bool
    ) -> some View {
        let parsedAttributed = (try? AttributedString(
            markdown: rawText,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ))

        return Group {
            if let parsedAttributed {
                Text(parsedAttributed)
            } else {
                Text(rawText)
            }
        }
        .font(.system(size: fontSize, weight: fontWeight))
        .foregroundColor(textColor)
        .strikethrough(strikethrough, color: textColor)
        .tint(DS.Colors.accentText)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func copyMarkdownToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        withAnimation(.easeOut(duration: DS.Animation.fast)) {
            didCopyMarkdown = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                didCopyMarkdown = false
            }
        }
    }
}

// MARK: - Inline Pills & Interactive Directive Chips

private struct ClickyInkBadgePill: View {
    let kind: ClickyInkBadgeKind

    private var badgeColor: Color {
        switch kind {
        case .new: return DS.Colors.blue400
        case .needs: return DS.Colors.warning
        case .done: return DS.Colors.success
        case .pick: return Color(hex: "#A78BFA")
        case .now: return Color(hex: "#22D3EE")
        case .gone: return DS.Colors.textTertiary
        }
    }

    var body: some View {
        Text(kind.displayTitle.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(badgeColor)
            .strikethrough(kind == .gone, color: badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(badgeColor.opacity(0.16))
            )
            .overlay(
                Capsule()
                    .stroke(badgeColor.opacity(0.45), lineWidth: 0.9)
            )
    }
}

private struct ClickyInkStatusPill: View {
    let label: String

    private var pillColor: Color {
        let lower = label.lowercased()
        if lower.contains("done") || lower.contains("ready") || lower.contains("ok") || lower.contains("pass") || lower.contains("live") {
            return DS.Colors.success
        }
        if lower.contains("need") || lower.contains("wait") || lower.contains("warn") || lower.contains("pending") {
            return DS.Colors.warning
        }
        if lower.contains("fail") || lower.contains("error") || lower.contains("block") {
            return DS.Colors.destructiveText
        }
        return DS.Colors.blue400
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(pillColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(pillColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(pillColor.opacity(0.14)))
        .overlay(Capsule().stroke(pillColor.opacity(0.35), lineWidth: 0.9))
    }
}

private struct ClickyInkActionButton: View {
    let iconName: String
    let label: String
    let tintColor: Color
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isHovered ? .white : tintColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(
                Capsule()
                    .fill(isHovered ? tintColor.opacity(0.28) : tintColor.opacity(0.14))
            )
            .overlay(
                Capsule()
                    .stroke(tintColor.opacity(isHovered ? 0.75 : 0.42), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                isHovered = hovering
            }
        }
    }
}

private struct ClickyInkLinkChip: View {
    let title: String
    let urlString: String
    let onFallbackAction: ((String) -> Void)?

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: handleOpenLink) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .underline(isHovered)
                    .lineLimit(1)
            }
            .foregroundColor(isHovered ? DS.Colors.blue300 : DS.Colors.accentText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(DS.Colors.blue500.opacity(isHovered ? 0.20 : 0.10))
            )
            .overlay(
                Capsule()
                    .stroke(DS.Colors.blue400.opacity(0.35), lineWidth: 0.9)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) {
                isHovered = hovering
            }
        }
    }

    private func handleOpenLink() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsedURL = URL(string: trimmed),
           let scheme = parsedURL.scheme,
           !scheme.isEmpty {
            NSWorkspace.shared.open(parsedURL)
        } else if FileManager.default.fileExists(atPath: trimmed) {
            NSWorkspace.shared.open(URL(fileURLWithPath: trimmed))
        } else {
            onFallbackAction?(trimmed)
        }
    }
}

private struct ClickyInkDashedDivider: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
            }
            .stroke(
                DS.Colors.borderSubtle,
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        }
        .frame(height: 1)
    }
}

// MARK: - Wrapping Flow Layout

private struct ClickyInkFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 6) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let placement = computePlacement(maxWidth: maxWidth, subviews: subviews)
        return placement.totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = computePlacement(maxWidth: bounds.width, subviews: subviews)
        for (subviewIndex, subview) in subviews.enumerated() {
            guard subviewIndex < placement.frames.count else { continue }
            let frame = placement.frames[subviewIndex]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.origin.x, y: bounds.minY + frame.origin.y),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func computePlacement(maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], totalSize: CGSize) {
        var frames: [CGRect] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var measuredMaxWidth: CGFloat = 0

        let effectiveMaxWidth = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 10_000

        for subview in subviews {
            let idealSize = subview.sizeThatFits(ProposedViewSize(width: effectiveMaxWidth, height: nil))
            let itemWidth = min(idealSize.width, effectiveMaxWidth)
            let itemHeight = idealSize.height

            if cursorX > 0 && cursorX + itemWidth > effectiveMaxWidth {
                cursorX = 0
                cursorY += currentRowHeight + verticalSpacing
                currentRowHeight = 0
            }

            let frame = CGRect(x: cursorX, y: cursorY, width: itemWidth, height: itemHeight)
            frames.append(frame)

            cursorX += itemWidth + horizontalSpacing
            currentRowHeight = max(currentRowHeight, itemHeight)
            measuredMaxWidth = max(measuredMaxWidth, frame.maxX)
        }

        let totalHeight = frames.isEmpty ? 0 : (cursorY + currentRowHeight)
        return (frames, CGSize(width: maxWidth.isFinite ? maxWidth : measuredMaxWidth, height: totalHeight))
    }
}
