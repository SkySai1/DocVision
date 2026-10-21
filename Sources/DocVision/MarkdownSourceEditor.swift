import AppKit
import SwiftUI

struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var highlightsMetadata: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        scrollView.documentView = textView
        applyMetadataHighlights(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let oldSelection = textView.selectedRange()
            textView.string = text
            let safeLocation = min(oldSelection.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
        }
        applyMetadataHighlights(to: textView)
    }

    private func applyMetadataHighlights(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let source = textView.string as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: fullRange)
        if highlightsMetadata {
            var location = 0
            while location < source.length {
                let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
                let line = source.substring(with: lineRange)
                if MarkdownPresentation.isMetadataLine(line) {
                    storage.addAttribute(
                        .backgroundColor,
                        value: NSColor.systemYellow.withAlphaComponent(0.25),
                        range: lineRange
                    )
                }
                location = NSMaxRange(lineRange)
            }
        }
        storage.endEditing()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownSourceEditor

        init(parent: MarkdownSourceEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.applyMetadataHighlights(to: textView)
        }
    }
}
