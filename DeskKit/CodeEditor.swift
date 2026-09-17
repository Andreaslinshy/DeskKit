import AppKit
import SwiftUI

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let documentID: String
    let editable: Bool
    let language: String
    let wrapsLines: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CodeScrollView {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 10_000_000, height: 10_000_000))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        container.widthTracksTextView = false; container.lineFragmentPadding = 0
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), textContainer: container)
        editor.isRichText = false; editor.isEditable = editable; editor.isSelectable = true
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .controlAccentColor
        editor.allowsUndo = true; editor.usesFindPanel = true
        editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false; editor.isAutomaticDataDetectionEnabled = false
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        paragraph.tabStops = []; paragraph.defaultTabInterval = 15.6
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: editor.font!, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        editor.delegate = context.coordinator
        let scroll = CodeScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = editor
        scroll.findBarPosition = .aboveContent
        let ruler = CodeLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = editor; ruler.ruleThickness = 44; ruler.setAccessibilityElement(false)
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        context.coordinator.scroll = scroll
        return scroll
    }
    func updateNSView(_ scroll: CodeScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        let changedDocument = coordinator.documentID != documentID
        let enteringEdit = editable && !editor.isEditable
        coordinator.applying = true
        if changedDocument || editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.textStorage?.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                               .paragraphStyle: editor.defaultParagraphStyle ?? NSParagraphStyle.default], range: NSRange(location: 0, length: (text as NSString).length))
            editor.setSelectedRange(changedDocument ? NSRange(location: 0, length: 0) : NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            if changedDocument || !editable { editor.undoManager?.removeAllActions() }
            coordinator.restyle()
            // Refresh native search matches when switching files or restoring a saved draft.
            // The applying guard keeps this notification from writing back into the draft.
            editor.didChangeText()
        }
        editor.isEditable = editable
        scroll.setLineWrapping(wrapsLines)
        editor.setAccessibilityLabel("\(language) · \(editable ? "编辑中" : "只读")")
        coordinator.documentID = documentID; coordinator.applying = false
        if enteringEdit {
            editor.undoManager?.removeAllActions()
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.isEditable else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }
    static func dismantleNSView(_ view: CodeScrollView, coordinator: Coordinator) { coordinator.highlightWork?.cancel() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var scroll: CodeScrollView?
        var documentID = ""
        var applying = false
        var highlightWork: DispatchWorkItem?
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !applying, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            (scroll?.verticalRulerView as? CodeLineRuler)?.rebuild()
            scroll?.resizeDocument()
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.restyle() }
            highlightWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
        func restyle() {
            guard let editor = scroll?.documentView as? NSTextView, !editor.hasMarkedText() else { return }
            CodeSyntax.highlight(editor, language: parent.language)
            (scroll?.verticalRulerView as? CodeLineRuler)?.rebuild()
            scroll?.resizeDocument()
        }
    }
}

final class CodeScrollView: NSScrollView {
    private var wrapsLines = false
    private var resizingDocument = false
    override func layout() { super.layout(); resizeDocument() }
    func setLineWrapping(_ enabled: Bool) {
        guard enabled != wrapsLines,
              let editor = documentView as? NSTextView, let layout = editor.layoutManager,
              let container = editor.textContainer else { return }
        // Keep the current top character in view when the same text gains or loses visual lines.
        layout.ensureLayout(for: container)
        let origin = contentView.bounds.origin
        let point = NSPoint(x: max(0, origin.x - editor.textContainerInset.width),
                            y: max(0, origin.y - editor.textContainerInset.height))
        let glyph = layout.glyphIndex(for: point, in: container)
        let anchor = glyph < layout.numberOfGlyphs ? layout.characterIndexForGlyph(at: glyph) : nil
        wrapsLines = enabled
        hasHorizontalScroller = !enabled
        editor.isHorizontallyResizable = !enabled
        resizeDocument()
        var destination = NSPoint(x: enabled ? 0 : origin.x, y: origin.y)
        if let anchor, origin.y > 0 {
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: anchor), effectiveRange: nil)
            destination.y = rect.minY + editor.textContainerInset.height
        }
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: destination, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
        verticalRulerView?.needsDisplay = true
    }
    func resizeDocument() {
        guard !resizingDocument, contentView.bounds.width > 0,
              let editor = documentView as? NSTextView, let layout = editor.layoutManager,
              let container = editor.textContainer else { return }
        resizingDocument = true
        defer { resizingDocument = false }
        // Constrain the text container, not the source string: wrapping never inserts newlines.
        let viewport = contentView.bounds.size
        let width = wrapsLines ? max(1, viewport.width - editor.textContainerInset.width * 2) : 10_000_000
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: 10_000_000)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = max(used.maxY, layout.extraLineFragmentRect.maxY)
        let size = NSSize(width: wrapsLines ? viewport.width : max(viewport.width, ceil(used.maxX + editor.textContainerInset.width * 2)),
                          height: max(viewport.height, ceil(height + editor.textContainerInset.height * 2)))
        if editor.frame.size != size { editor.setFrameSize(size) }
        verticalRulerView?.needsDisplay = true
    }
}

final class CodeLineRuler: NSRulerView {
    private var starts = [0]
    override var isFlipped: Bool { true }
    func rebuild() {
        guard let editor = clientView as? NSTextView else { return }
        starts = [0]
        for (index, unit) in editor.string.utf16.enumerated() where unit == 10 { starts.append(index + 1) }
        let width = max(44, CGFloat(String(starts.count).count) * 7 + 20)
        if ruleThickness != width { ruleThickness = width }
        needsDisplay = true
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill(); NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        guard let editor = clientView as? NSTextView, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let viewport = editor.visibleRect.offsetBy(dx: -editor.textContainerInset.width, dy: -editor.textContainerInset.height)
        let glyphs = layout.glyphRange(forBoundingRect: NSRect(x: 0, y: viewport.minY, width: 10_000_000, height: viewport.height), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < characters.location { low = middle + 1 } else { high = middle }
        }
        let length = (editor.string as NSString).length
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for index in max(0, low - 1)..<starts.count {
            let start = starts[index]
            if start > NSMaxRange(characters) && start < length { break }
            let lineRect = start < length ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil) : layout.extraLineFragmentRect
            let point = convert(NSPoint(x: 0, y: lineRect.minY + editor.textContainerInset.height), from: editor)
            guard point.y > -30 && point.y < bounds.height + 30 else { continue }
            let label = String(index + 1) as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 9, y: point.y + 2), withAttributes: attributes)
        }
    }
}

private enum CodeSyntax {
    static let javascript = try! NSRegularExpression(pattern: #"(?<comment>//[^\r\n]*|/\*[\s\S]*?(?:\*/|$))|(?<key>"(?:\\.|[^"\\])*"(?=\s*:))|(?<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|(?<keyword>\b(?:async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|from|function|if|import|in|instanceof|let|new|of|return|static|super|switch|this|throw|try|typeof|var|void|while|yield)\b)|(?<number>\b(?:true|false|null|undefined|NaN|Infinity|0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)|(?<call>\b[A-Za-z_$][\w$]*(?=\s*\())"#)
    static let json = try! NSRegularExpression(pattern: #"(?<key>"(?:\\.|[^"\\])*"(?=\s*:))|(?<string>"(?:\\.|[^"\\])*")|(?<number>\b(?:true|false|null|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)"#)
    static func highlight(_ editor: NSTextView, language: String) {
        guard let layout = editor.layoutManager else { return }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        let colors: [(String, NSColor)] = [("comment", .secondaryLabelColor), ("key", .systemBlue), ("string", .systemGreen), ("keyword", .systemPurple), ("number", .systemOrange), ("call", .systemTeal)]
        let regex = language == "JSON" ? json : javascript
        let applicableColors = language == "JSON" ? colors.filter { ["key", "string", "number"].contains($0.0) } : colors
        regex.enumerateMatches(in: editor.string, range: range) { match, _, _ in
            guard let match else { return }
            for (name, color) in applicableColors {
                let token = match.range(withName: name)
                if token.location != NSNotFound { layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token); break }
            }
        }
    }
}
