import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Sign in with a recovery phrase, the last step of setup.
struct SignInView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The phrase controls the whole account and is only needed once, to register a posting key,
    // so it stays in memory until Import or quitting and is never saved anywhere.
    @State private var text = ""
    @State private var oversized = false
    @State private var pastedClipboard: Int?
    @State private var editing = false

    private static let maxBytes = 1024

    private var session: PostingSession { state.session }
    private var words: [Substring] { text.split(whereSeparator: \.isWhitespace) }
    private var validLength: Bool { [12, 24].contains(words.count) }
    private var feedback: String? {
        if oversized || (!editing && !words.isEmpty && !validLength) { return "Enter 12 or 24 words." }
        return text.isEmpty ? session.recoveryError : nil
    }

    var body: some View {
        Group {
            if session.busy {
                importing
            } else {
                form
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(FatlineStyle.ink)
        .tint(FatlineStyle.action)
        .background(FatlineStyle.paper)
        .fatlineStepBar()
        .navigationBarBackButtonHidden(session.busy)
        .onChange(of: text) { previous, current in
            // An over-long previous value is the rollback below, not an edit.
            guard previous.utf8.count <= Self.maxBytes else { return }
            oversized = current.utf8.count > Self.maxBytes
            if oversized {
                text = previous
            } else if current.isEmpty {
                clearPastedPhrase()
            }
        }
        .onDisappear(perform: clearPastedPhrase)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            clearPastedPhrase()
        }
        .onChange(of: feedback) { _, message in
            if let message { AppSupport.announce(message) }
        }
    }

    private var importing: some View {
        let label = Text("Importing…")
            .font(FatlineStyle.bodyStrong)
            .accessibilityIdentifier("recovery-importing")
        return VStack(spacing: 4) {
            Group {
                if reduceMotion {
                    label
                } else {
                    label.phaseAnimator([false, true]) { view, dimmed in
                        view.opacity(dimmed ? 0.60 : 1)
                    } animation: { _ in
                        .easeInOut(duration: 1.1)
                    }
                }
            }
            Text("May take a minute")
                .font(FatlineStyle.body)
                .foregroundStyle(FatlineStyle.secondary)
        }
    }

    private var form: some View {
        // Scrolls only when a long error won't fit, so it can't run under the buttons.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FatlineStepHeader(
                    title: "Import your account",
                    instruction: "Enter your Farcaster recovery phrase, not another wallet’s."
                )
                phraseField
                    .padding(.top, 20)
                feedbackLine
                    .padding(.top, 8)
            }
            .padding(.horizontal, FatlineStyle.screenGutter)
            .padding(.top, FatlineStyle.screenTop)
            .frame(maxWidth: FatlineStyle.columnMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .fatlineBottomAction { actions }
    }

    private var phraseField: some View {
        // A fixed height, so a long phrase scrolls inside the box and nothing around it moves.
        RecoveryPhraseEntry(text: $text, editing: $editing, pastedClipboard: $pastedClipboard, submit: importPhrase)
            .frame(height: RecoveryPhraseEntry.height)
            .background(FatlineStyle.quiet, in: .rect(cornerRadius: 18))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("12 or 24 words")
                        .font(FatlineStyle.body)
                        .foregroundStyle(FatlineStyle.secondary)
                        .padding(RecoveryPhraseEntry.inset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    /// Always takes at least one line, so a short message doesn't move anything.
    private var feedbackLine: some View {
        Text(feedback ?? " ")
            .font(FatlineStyle.meta)
            .foregroundStyle(FatlineStyle.danger)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(feedback == nil)
            .accessibilityIdentifier("recovery-error")
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if session.account?.registration != nil {
                Button("Retry Connection") {
                    clearField()
                    Task { await session.completeRegistration() }
                }
                .buttonStyle(.plain)
                .font(FatlineStyle.body)
                .foregroundStyle(FatlineStyle.action)
            }
            Button(action: importPhrase) {
                Text("Import").frame(maxWidth: .infinity)
            }
            .buttonStyle(FatlinePrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(!validLength)
        }
    }

    private func clearField() {
        text = ""
        oversized = false
    }

    /// The change count says whether anything was copied since the paste, without reading the
    /// clipboard, which macOS can ask permission for.
    private func clearPastedPhrase() {
        if NSPasteboard.general.changeCount == pastedClipboard { NSPasteboard.general.clearContents() }
        pastedClipboard = nil
    }

    private func importPhrase() {
        guard validLength else { return }
        let phrase = words.joined(separator: " ")
        clearPastedPhrase()
        clearField()
        session.importPhrase(phrase)
    }
}

/// A box that wraps and shows only bullets. A `SecureField` stays on one line.
private struct RecoveryPhraseEntry: NSViewRepresentable {
    static let height: CGFloat = 122
    static let inset: CGFloat = 14

    @Binding var text: String
    @Binding var editing: Bool
    @Binding var pastedClipboard: Int?
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let field = Field()
        field.delegate = context.coordinator
        field.willPaste = { [weak coordinator = context.coordinator] in
            coordinator?.entry.pastedClipboard = NSPasteboard.general.changeCount
        }
        field.focusChanged = { [weak coordinator = context.coordinator] focused in
            // AppKit can change focus during a SwiftUI update. Wait until it ends.
            Task { @MainActor in coordinator?.entry.editing = focused }
        }
        field.drawsBackground = false
        field.insertionPointColor = NSColor(FatlineStyle.action)
        field.textContainerInset = NSSize(width: Self.inset, height: Self.inset)
        field.textContainer?.lineFragmentPadding = 0
        field.textContainer?.widthTracksTextView = true
        field.autoresizingMask = .width
        field.isHorizontallyResizable = false
        field.isVerticallyResizable = true
        // As tall as the box, so a click anywhere on the fill reaches it.
        field.minSize = NSSize(width: 0, height: Self.height)
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

        field.isRichText = false
        field.importsGraphics = false
        field.allowsUndo = false
        field.isAutomaticSpellingCorrectionEnabled = false
        field.isContinuousSpellCheckingEnabled = false
        field.isGrammarCheckingEnabled = false
        field.isAutomaticTextCompletionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.smartInsertDeleteEnabled = false
        field.inlinePredictionType = .no
        field.writingToolsBehavior = .none
        field.setAccessibilityLabel("Farcaster recovery phrase")
        field.setAccessibilitySubrole(.secureTextField)
        field.setAccessibilityHelp("12 or 24 words")
        field.setAccessibilityIdentifier("recovery-phrase-entry")

        // Resigning key covers switching apps too.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(field, selector: #selector(Field.syncSecureInput), name: name, object: nil)
        }

        let scroller = NSScrollView()
        scroller.documentView = field
        scroller.drawsBackground = false
        scroller.borderType = .noBorder
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        return scroller
    }

    func updateNSView(_ scroller: NSScrollView, context: Context) {
        context.coordinator.entry = self
        (scroller.documentView as? Field)?.show(text)
    }

    /// Holds only bullets, so the phrase stays in `text` and out of the text system.
    final class Field: NSTextView {
        var focusChanged: ((Bool) -> Void)?
        var willPaste: (() -> Void)?
        private var hasFocus = false
        private var securingInput = false

        private static let attributes: [NSAttributedString.Key: Any] = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = FatlineStyle.bodyLineSpacing
            return [
                .font: NSFont(name: "Inter-Regular", size: FatlineStyle.bodySize) ?? .systemFont(ofSize: FatlineStyle.bodySize),
                .foregroundColor: NSColor(FatlineStyle.ink),
                .paragraphStyle: style,
            ]
        }()

        /// One bullet per UTF-16 unit, so edit ranges match the phrase. Spaces stay so lines break between words.
        func show(_ phrase: String) {
            let units: [UInt16] = phrase.utf16.map {
                Unicode.Scalar($0)?.properties.isWhitespace == true ? 0x20 : 0x2022
            }
            let mask = String(decoding: units, as: UTF16.self)
            guard mask != string else { return }
            textStorage?.setAttributedString(NSAttributedString(string: mask, attributes: Self.attributes))
        }

        override func paste(_ sender: Any?) {
            willPaste?()
            super.paste(sender)
        }

        override func pasteAsPlainText(_ sender: Any?) {
            willPaste?()
            super.pasteAsPlainText(sender)
        }

        /// VoiceOver hears how many words there are, and never the bullets.
        override func accessibilityValue() -> String? {
            "\(string.split(separator: " ").count) masked words"
        }

        /// A secure field keeps other apps from reading its keystrokes, so this has to as well.
        @objc func syncSecureInput() {
            let wanted = hasFocus && window?.isKeyWindow == true
            guard wanted != securingInput else { return }
            securingInput = wanted
            if wanted { EnableSecureEventInput() } else { DisableSecureEventInput() }
        }

        private func setFocus(_ focused: Bool) {
            hasFocus = focused
            syncSecureInput()
            focusChanged?(focused)
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { setFocus(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { setFocus(false) }
            return resigned
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                setFocus(false)
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }

        /// Dead keys and input methods show text before it's committed, so they're off, as in a secure field.
        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var entry: RecoveryPhraseEntry

        init(_ entry: RecoveryPhraseEntry) { self.entry = entry }

        func textView(
            _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
        ) -> Bool {
            let current = entry.text as NSString
            guard let field = textView as? Field, let replacementString, NSMaxRange(range) <= current.length else {
                return false
            }
            // The view must never receive the real text, so apply the edit here and show its mask.
            let updated = current.replacingCharacters(in: range, with: replacementString)
            field.show(updated)
            let caret = NSRange(location: range.location + (replacementString as NSString).length, length: 0)
            field.setSelectedRange(caret)
            field.scrollRangeToVisible(caret)
            entry.text = updated
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // The default button doesn't get Return while this has focus.
                entry.submit()
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
            default:
                return false
            }
            return true
        }
    }
}
