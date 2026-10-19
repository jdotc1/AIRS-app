import AppKit
import SwiftUI

/// NSTextField delivers raw edits without SwiftUI String canonical-equivalence coalescing.
struct ExactKeyField: NSViewRepresentable {
    @Binding var input: ExactKeyInput
    var placeholder = "Exact child key"
    var initiallyFocused = false
    var submit: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil
    let edited: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = InitialFocusTextField(string: input.value)
        field.focusOnAttach = initiallyFocused
        field.placeholderString = placeholder
        field.isEditable = true
        field.isSelectable = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.owner = self
        if !field.stringValue.utf8.elementsEqual(input.value.utf8) {
            field.stringValue = input.value
        }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil
    }
    final class InitialFocusTextField: NSTextField {
        var focusOnAttach = false
        private var didFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard focusOnAttach, !didFocus, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didFocus, let window = self.window else { return }
                self.didFocus = true
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var owner: ExactKeyField
        init(_ owner: ExactKeyField) { self.owner = owner }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let submit = owner.submit {
                submit(); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), let cancel = owner.cancel {
                cancel(); return true
            }
            return false
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            owner.input = ExactKeyInput(value: field.stringValue)
            owner.edited()
        }
    }
}
