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
