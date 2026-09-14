import AppKit
import Foundation

/// Covers the two interaction defects behind "the Buffer sometimes cannot be
/// focused": a click that arrived before the new field's lease existed was
/// discarded, and a click made while capture was already held could revoke a
/// route that was still valid.
func runBufferCaptureRequestSmokeTest() -> Bool {
    print("== RIMES buffer capture request smoke ==")

    // A trusted field is present: bind to it. This is the ordinary case and
    // the only one that ever worked reliably.
    guard BufferCaptureRequestRules.decision(hasTrustedLease: true,
                                             holdsCaptureRoute: false,
                                             captureTokenIsLive: false)
            == .grant,
          BufferCaptureRequestRules.decision(hasTrustedLease: true,
                                             holdsCaptureRoute: true,
                                             captureTokenIsLive: true)
            == .grant else {
        return captureFail("a trusted lease must always grant")
    }

    // Clicking the rail again while capture is held must not tear the route
    // down. Validation can fail transiently — a frontmost-application probe
    // during an app switch is enough — and the old code revoked on any
    // failure, so a second click lost the Buffer the first one had won.
    guard BufferCaptureRequestRules.decision(hasTrustedLease: false,
                                             holdsCaptureRoute: true,
                                             captureTokenIsLive: true)
            == .keepExistingCapture else {
        return captureFail("a live route must survive a failed re-click")
    }

    // A route bound to a token that is genuinely gone is stale, not worth
    // keeping, and the click that found it should still be honoured later.
    guard BufferCaptureRequestRules.decision(hasTrustedLease: false,
                                             holdsCaptureRoute: true,
                                             captureTokenIsLive: false)
            == .revoke else {
        return captureFail("a dead route must be revoked")
    }

    // No field owns a lease yet. Switching applications and reaching straight
    // for the Buffer lands here every time, because IMK has not activated the
    // new field at that instant. The intent is kept rather than dropped.
    guard BufferCaptureRequestRules.decision(hasTrustedLease: false,
                                             holdsCaptureRoute: false,
                                             captureTokenIsLive: false)
            == .awaitTarget else {
        return captureFail("a click with no target must be remembered")
    }

    // Bounded, so a remembered click cannot hijack a field focused minutes
    // later, but long enough to cover an application switch.
    let requestedAt = Date(timeIntervalSince1970: 1_000_000)
    let pending = BufferPendingCaptureRequest(insertionIndex: 2,
                                              requestedAt: requestedAt)
    guard pending.isLive(at: requestedAt),
          pending.isLive(at: requestedAt.addingTimeInterval(5.9)),
          !pending.isLive(at: requestedAt.addingTimeInterval(6)),
          !pending.isLive(at: requestedAt.addingTimeInterval(600)),
          // A clock that moved backwards must expire it rather than extend it.
          !pending.isLive(at: requestedAt.addingTimeInterval(-1)) else {
        return captureFail("pending capture lifetime")
    }

    // An application switch activates *a* field in the new app — usually the
    // one focused last. A plain deferred click waits until the user clicks
    // into that application; a re-arm restores a route and is held to its
    // application by bundle instead.
    var plain = BufferPendingCaptureRequest(insertionIndex: 0,
                                            requestedAt: requestedAt)
    guard !plain.mayBind(toProcess: 42) else {
        return captureFail("an application switch alone must not complete a deferred click")
    }
    plain.hostPointerProcessIdentifier = 7
    guard !plain.mayBind(toProcess: 42), plain.mayBind(toProcess: 7) else {
        return captureFail("a deferred click binds only to the application clicked into")
    }
    let rearm = BufferPendingCaptureRequest(insertionIndex: 0,
                                            requestedAt: requestedAt,
                                            expectedBundleID: "com.example.host")
    guard rearm.mayBind(toProcess: 42),
          rearm.accepts(bundleID: "com.example.host"),
          !rearm.accepts(bundleID: "com.example.other") else {
        return captureFail("a re-arm is held to its application by bundle")
    }

    // Focus activation versus a capture the user just asked for. The
    // controller's own token is updated after the coordinator publishes the
    // lease, so a rail click lands between the two; the activation that
    // follows must not read its own token as a change and undo the grant.
    // Nineteen deferred clicks and two completions came from exactly that.
    var epochs = FocusEpochState()
    let first = epochs.activate()
    let second = epochs.activate()
    guard BufferFocusActivationRules.resetsCaptureRoute(
        previousToken: first,
        activatedToken: second,
        captureBoundToActivatedToken: false
    ) else {
        return captureFail("a genuinely new field must start in direct mode")
    }
    guard !BufferFocusActivationRules.resetsCaptureRoute(
        previousToken: first,
        activatedToken: second,
        captureBoundToActivatedToken: true
    ) else {
        return captureFail("capture bound to the incoming token must survive")
    }
    // Re-activating the same field changes nothing either way.
    guard !BufferFocusActivationRules.resetsCaptureRoute(
        previousToken: second,
        activatedToken: second,
        captureBoundToActivatedToken: false
    ),
    !BufferFocusActivationRules.resetsCaptureRoute(
        previousToken: nil,
        activatedToken: second,
        captureBoundToActivatedToken: true
    ) else {
        return captureFail("same-token activation must not reset")
    }
    // A first focus with no capture anywhere still starts direct.
    guard BufferFocusActivationRules.resetsCaptureRoute(
        previousToken: nil,
        activatedToken: first,
        captureBoundToActivatedToken: false
    ) else {
        return captureFail("a first focus must start in direct mode")
    }

    // Return ownership. A paste never passes through the input method, so a
    // captured field can hold a paragraph the Buffer knows nothing about with
    // nothing of its own staged. Claiming Return there ate the keystroke for
    // the length of the tap/hold decision and delivered nothing, which is
    // what stopped a pasted message from being sent.
    guard !BufferEnterOwnershipRules.ownsReturn(pendingBlockCount: 0,
                                                hasIncompleteBlocks: false) else {
        return captureFail("an empty buffer must hand Return to the host")
    }
    guard BufferEnterOwnershipRules.ownsReturn(pendingBlockCount: 1,
                                               hasIncompleteBlocks: false),
          BufferEnterOwnershipRules.ownsReturn(pendingBlockCount: 40,
                                               hasIncompleteBlocks: false) else {
        return captureFail("staged blocks must keep the delivery gesture")
    }
    // A plugin still generating owns the key even with nothing pending yet,
    // so an early Return cannot send a half-finished result.
    guard BufferEnterOwnershipRules.ownsReturn(pendingBlockCount: 0,
                                               hasIncompleteBlocks: true) else {
        return captureFail("an incomplete result must keep Return")
    }

    // Status placement: waiting text belongs at the trailing edge, not at the
    // far left of an empty box, and it must not scroll away behind a result.
    let view = BufferInlineView(frame: NSRect(x: 0, y: 0, width: 760, height: 78))
    view.renderTranslationForPreview(.init(sourceText: "等待中的原文",
                                           outputBlocks: [],
                                           phase: .waiting,
                                           message: "等待回复"))
    guard let empty = view.renderedStatusPlacement else {
        return captureFail("waiting status must render")
    }
    guard empty.texts.contains("等待回复"),
          empty.isTrailingOverlay,
          empty.leadingClearance > 300 else {
        return captureFail("empty-box status placement: \(empty)")
    }

    // With a result present the status covers only its own corner; the rest
    // of the result stays visible underneath.
    let block = TranslationOutputBlock(id: UUID(),
                                       text: "已经生成好的一段较长的译文内容",
                                       deliveryReady: true)
    view.renderTranslationForPreview(.init(sourceText: "原文",
                                           outputBlocks: [block],
                                           phase: .translating,
                                           message: "等待回复"))
    guard let filled = view.renderedStatusPlacement else {
        return captureFail("status must survive a populated box")
    }
    guard filled.texts.contains("等待回复"),
          filled.isTrailingOverlay,
          filled.leadingClearance > 0 else {
        return captureFail("populated-box status placement: \(filled)")
    }

    // Once a result is ready with nothing to report, the corner is released
    // rather than left holding a stale plate.
    view.renderTranslationForPreview(.init(sourceText: "原文",
                                           outputBlocks: [block],
                                           phase: .ready,
                                           message: nil))
    guard view.renderedStatusPlacement == nil else {
        return captureFail("a settled result must clear its status overlay")
    }

    print("buffer capture request smoke: OK")
    return true
}

private func captureFail(_ message: String) -> Bool {
    print("FAILED: \(message)")
    return false
}
