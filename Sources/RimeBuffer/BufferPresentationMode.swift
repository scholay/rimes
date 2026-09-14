import Foundation

/// How the workbench receives keystrokes.
///
/// macOS delivers a keystroke to the active input method or to the key window,
/// and to nothing else. RIMES is the active input method only when the user
/// has selected it, so a workbench that never takes focus can only be typed
/// into while RIMES is running the keyboard. That single OS rule — not a
/// design choice — is why a second mode has to exist at all.
///
/// The modes differ at exactly two boundaries: where text comes from, and
/// where it goes. Everything between them — the model, the blocks, the rail,
/// the plugins, delivery scheduling — is one implementation. Keeping it that
/// way is the point: two rails drawn from two code paths would drift the
/// moment either is restyled, and the drift would be invisible until someone
/// switched modes.
enum BufferPresentationMode: String, Equatable, CaseIterable {
    /// RIMES owns the keyboard. Keys arrive through IMK, the panel never takes
    /// focus, and finished text is inserted straight into the host field.
    case integratedRime
    /// Another input method owns the keyboard. The panel takes focus and a
    /// text field receives whatever that input method composes; finished text
    /// reaches the host through the pasteboard instead.
    case standaloneField

    static func resolve(currentSourceIsOwn: Bool) -> Self {
        currentSourceIsOwn ? .integratedRime : .standaloneField
    }

    /// The panel may take focus only in the mode that needs it. In borrowed
    /// mode taking focus would end the host's own editing session, which is
    /// the behaviour the integrated experience exists to avoid.
    var panelAcceptsKeyInput: Bool { self == .standaloneField }

    /// Whether finished text can be handed to the host through IMK. Only the
    /// active input method holds a client to insert into.
    var deliversThroughInputMethod: Bool { self == .integratedRime }

    /// The composing field is shown only where there is no host preedit to
    /// mirror — it is the one visible difference between the two modes.
    var showsComposingField: Bool { self == .standaloneField }
}

/// When the workbench must take the caret for itself.
///
/// The bug this exists to prevent was not a wrong answer but an unasked
/// question: focus was claimed only on a mode *transition*, and the ordinary
/// case has no transition — the user switches input method while the
/// workbench is closed, then opens it. The panel came up ordered-front but
/// never key, so the field was visible and could accept nothing.
enum BufferComposingFocusRules {
    static func shouldClaimFocus(mode: BufferPresentationMode,
                                 isVisible: Bool,
                                 musicSelected: Bool,
                                 sessionProtected: Bool,
                                 hiddenForSession: Bool,
                                 secureInput: Bool,
                                 alreadyFocused: Bool) -> Bool {
        guard mode.panelAcceptsKeyInput else { return false }
        guard isVisible, !musicSelected, !sessionProtected,
              !hiddenForSession, !secureInput else { return false }
        return !alreadyFocused
    }
}

/// Whether the rails should be folded away, leaving only the toolbar.
///
/// Without focus a standalone workbench is a text surface that cannot take
/// text — it looks ready and swallows everything. Folding to the toolbar
/// says so honestly and turns the toolbar into the way back in: clicking it
/// makes the panel key, which restores the rails.
///
/// It applies only where focus is a thing the workbench can hold. Under RIMES
/// the host keeps focus by design and the rails must stay visible, or opening
/// the workbench to read staged blocks would fold them away.
enum BufferRailFoldRules {
    /// `acceptsInput` is what "focus is on the Buffer" means in each mode:
    /// holding the capture lease under RIMES, holding the caret without it.
    /// Both answer the same question — will a keystroke land here — and the
    /// rails are folded whenever the answer is no.
    /// Staged blocks do not keep the rails open. Keeping them visible was a
    /// reasonable-sounding exception that in practice never let the fold
    /// happen at all — blocks are present almost always — so the workbench
    /// looked unchanged. Everything below the toolbar folds; the toolbar is
    /// how it comes back.
    /// `captureRebindPending` is the handover window. Clicking the toolbar
    /// under RIMES gives this process an input session, and macOS tears the
    /// host's down to hand it over — so capture drops a quarter-second after
    /// the very click that asked for it. Folding on that reading collapsed
    /// the workbench again right after the user opened it. The route is
    /// coming back; wait for it rather than reporting the gap.
    static func foldsToToolbar(acceptsInput: Bool,
                               musicSelected: Bool,
                               captureRebindPending: Bool = false) -> Bool {
        guard !musicSelected else { return false }
        guard !captureRebindPending else { return false }
        return !acceptsInput
    }
}

/// Guards the boundary the modes are supposed to respect.
///
/// The failure this exists to prevent is gradual: a `if mode == .standalone`
/// appearing inside block handling, then inside a plugin, until the two modes
/// are two products sharing a window. The mode is resolved once when the
/// panel opens and must not be readable below that line.
enum BufferPresentationModeBoundary {
    /// Files permitted to mention the mode at all. Everything else — the
    /// model, the rail, the plugins, delivery — must behave identically in
    /// both, because their behaviour is not what differs.
    static let owningFiles: Set<String> = [
        "BufferPresentationMode.swift",
        "BufferPresentationModeSmoke.swift",
        "BufferWindowController.swift",
    ]

    static func isPermitted(file: String) -> Bool {
        owningFiles.contains(file)
    }
}
