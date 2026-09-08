import Foundation

/// Pure source-ownership regression checks. No translation provider, input
/// client, live user defaults, or installed process is used here.
func runBufferSourceSliceSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: buffer source slices \(message)")
        return false
    }

    let direct = BufferModel()
    let owner = DirectInputRunOwner.testing(701)
    guard let directID = direct.appendDirectInputFragment("Hello", owner: owner),
          let original = BufferSourceSlice.capture(
            range: NSRange(location: 0, length: 5), in: direct.blocks
          ) else { return fail("direct source capture") }
    _ = direct.appendDirectInputFragment(" new", owner: owner)
    guard direct.blocks.first?.id == directID,
          direct.blocks.first?.text == "Hello new" else {
        return fail("same-ID source growth fixture")
    }
    let tail = BufferSourceSlice(blockID: directID,
                                 range: NSRange(location: 5, length: 4),
                                 text: " new")
    guard let rebasedTail = BufferSourceSlice.rebasing([tail], afterConsuming: original),
          rebasedTail.first?.range == NSRange(location: 0, length: 4),
          direct.consumeTranslatedSource(original),
          direct.blocks.first?.id == directID,
          direct.stagedText == " new",
          BufferSourceSlice.matches(rebasedTail, in: direct.blocks),
          !direct.consumeTranslatedSource(original) else {
        return fail("same-ID suffix retention / exactly-once consumption")
    }
    _ = direct.appendDirectInputFragment("er", owner: owner)
    guard direct.stagedText == " newer",
          direct.blocks.first?.id == directID,
          direct.deleteBackwardInDirectInput(owner: owner),
          direct.stagedText == " newe" else {
        return fail("preserved direct tail remains editable")
    }
    let closedRun = BufferModel()
    _ = closedRun.appendDirectInputFragment("one two three four five", owner: owner)
    guard closedRun.blocks.count == 2 else { return fail("closed direct phrase fixture") }
    let closedID = closedRun.blocks[0].id
    let lastID = closedRun.blocks[1].id
    let lastText = closedRun.blocks[1].text
    guard closedRun.consumeTranslatedSource([
        BufferSourceSlice(blockID: lastID,
                          range: NSRange(location: 0, length: lastText.utf16.count),
                          text: lastText),
    ]) else { return fail("closed direct tail consumption") }
    _ = closedRun.appendDirectInputFragment("next", owner: owner)
    guard closedRun.blocks.count == 2, closedRun.blocks[0].id == closedID,
          closedRun.blocks[0].text == "one two three four ",
          closedRun.blocks[1].id != closedID else {
        return fail("consuming direct tail must not reopen an older phrase")
    }

    let unicode = BufferModel()
    unicode.append("👨‍👩‍👧‍👦e\u{301}中文")
    let familyLength = "👨‍👩‍👧‍👦".utf16.count
    guard let family = BufferSourceSlice.capture(
            range: NSRange(location: 0, length: familyLength), in: unicode.blocks
          ),
          BufferSourceSlice.capture(range: NSRange(location: 0, length: 1),
                                    in: unicode.blocks) == nil,
          BufferSourceSlice.capture(range: NSRange(location: familyLength, length: 1),
                                    in: unicode.blocks) == nil,
          unicode.consumeTranslatedSource(family),
          unicode.stagedText == "e\u{301}中文" else {
        return fail("UTF-16 and grapheme-safe ranges")
    }
    let canonical = BufferModel.Block(text: "a\u{315}\u{300}")
    let reordered = BufferSourceSlice(blockID: canonical.id,
                                      range: NSRange(location: 0, length: 3),
                                      text: "a\u{300}\u{315}")
    guard !BufferSourceSlice.matches([reordered], in: [canonical]) else {
        return fail("byte-distinct canonical equivalents are stale")
    }

    let atomic = BufferModel()
    atomic.append("abcd")
    atomic.append("efgh")
    let atomicIDs = atomic.blocks.map(\.id)
    let validFirst = BufferSourceSlice(blockID: atomicIDs[0],
                                       range: NSRange(location: 0, length: 4), text: "abcd")
    let invalidLast = BufferSourceSlice(blockID: atomicIDs[1],
                                        range: NSRange(location: 0, length: 4), text: "wrong")
    let atomicChangeCount = atomic.changeCount
    var atomicNotifications = 0
    atomic.onChange = { atomicNotifications += 1 }
    guard !atomic.consumeTranslatedSource([validFirst, invalidLast]),
          atomic.stagedText == "abcdefgh",
          atomic.blocks.map(\.id) == atomicIDs,
          atomic.changeCount == atomicChangeCount,
          atomicNotifications == 0,
          !atomic.consumeTranslatedSource([validFirst, validFirst]),
          BufferSourceSlice.rebasing([validFirst], afterConsuming: [validFirst]) == nil else {
        return fail("all-or-nothing validation / overlap rejection")
    }
    for range in [NSRange(location: NSNotFound, length: 1),
                  NSRange(location: -1, length: 1),
                  NSRange(location: Int.max - 1, length: 10),
                  NSRange(location: 0, length: 0),
                  NSRange(location: 7, length: 2)] {
        guard BufferSourceSlice.capture(range: range, in: atomic.blocks) == nil else {
            return fail("invalid global range accepted")
        }
    }

    let middle = BufferModel()
    middle.append("abcdefgh")
    let middleID = middle.blocks[0].id
    let middleCuts = [
        BufferSourceSlice(blockID: middleID, range: NSRange(location: 1, length: 2), text: "bc"),
        BufferSourceSlice(blockID: middleID, range: NSRange(location: 5, length: 2), text: "fg"),
    ]
    guard middle.consumeTranslatedSource(middleCuts), middle.stagedText == "adeh",
          middle.blocks[0].id == middleID else {
        return fail("descending noncontiguous range removal")
    }

    let repeated = BufferModel()
    repeated.append("go. go. tail")
    guard let first = BufferSourceSlice.capture(range: NSRange(location: 0, length: 4),
                                                in: repeated.blocks),
          let second = BufferSourceSlice.capture(range: NSRange(location: 4, length: 4),
                                                 in: repeated.blocks),
          let secondAfter = BufferSourceSlice.rebasing(second, afterConsuming: first),
          secondAfter.first?.range.location == 0,
          repeated.consumeTranslatedSource(first),
          repeated.stagedText == "go. tail",
          BufferSourceSlice.matches(secondAfter, in: repeated.blocks),
          repeated.consumeTranslatedSource(secondAfter),
          repeated.stagedText == "tail" else {
        return fail("repeated source text uses positions, never search")
    }

    let multi = BufferModel()
    multi.append("one", origin: .remotePeer(deviceID: "source-slice-smoke"))
    multi.append("two")
    multi.append("three")
    let survivor = multi.blocks[1]
    _ = multi.setInsertionPoint(2)
    guard let across = BufferSourceSlice.capture(range: NSRange(location: 0, length: 8),
                                                 in: multi.blocks),
          across.map(\.text).joined() == "onetwoth",
          across.count == 3 else { return fail("cross-block capture") }
    let removals = [
        BufferSourceSlice(blockID: multi.blocks[0].id,
                          range: NSRange(location: 0, length: 3), text: "one"),
        BufferSourceSlice(blockID: multi.blocks[2].id,
                          range: NSRange(location: 0, length: 5), text: "three"),
    ]
    guard !BufferSourceSlice.matches(Array(removals.reversed()), in: multi.blocks) else {
        return fail("source order validation")
    }
    var multiNotifications = 0
    multi.onChange = { multiNotifications += 1 }
    guard multi.consumeTranslatedSource(removals),
          multi.blocks.count == 1, multi.blocks[0].id == survivor.id,
          multi.blocks[0].createdAt == survivor.createdAt,
          multi.blocks[0].origin == survivor.origin,
          multi.insertionIndex == 1, multiNotifications == 1 else {
        return fail("atomic notification, identity/provenance and caret preservation")
    }

    let external = BufferModel()
    external.stageExternal("bound", origin: .plugin(id: "slice-smoke"))
    let unsafe = BufferSourceSlice(blockID: external.blocks[0].id,
                                   range: NSRange(location: 0, length: 5), text: "bound")
    guard !external.consumeTranslatedSource([unsafe]), external.stagedText == "bound" else {
        return fail("target-bound provenance rejection")
    }
    let incomplete = BufferModel()
    incomplete.stageExternal(
        "draft", origin: .plugin(id: "slice-smoke"),
        pluginMetadata: BufferModel.PluginMetadata(
            pluginId: "slice-smoke", actionId: "action", requestId: "request",
            contextId: "context", focusToken: nil, runtimeIdentity: "runtime",
            incomplete: true, reviewedAsPlainText: true
        )
    )
    guard BufferSourceSlice.capture(range: NSRange(location: 0, length: 5),
                                    in: incomplete.blocks) == nil else {
        return fail("incomplete reviewed source cannot be consumed")
    }
    let reviewed = BufferModel()
    reviewed.stageExternal("reviewed suffix", origin: .plugin(id: "slice-smoke"),
                           locallyReviewedAsPlainText: true)
    guard let reviewedPrefix = BufferSourceSlice.capture(
            range: NSRange(location: 0, length: 8), in: reviewed.blocks
          ), reviewed.consumeTranslatedSource(reviewedPrefix),
          reviewed.stagedText == " suffix",
          reviewed.blocks[0].locallyReviewedAsPlainText,
          reviewed.blocks[0].origin == .plugin(id: "slice-smoke") else {
        return fail("reviewed provenance survives partial consumption")
    }
    guard let pending = BufferSourceSlice.capture(
            range: NSRange(location: 0, length: 7), in: reviewed.blocks
          ) else { return fail("privacy fixture") }
    reviewed.discardForPrivacy()
    guard !reviewed.consumeTranslatedSource(pending), reviewed.blocks.isEmpty else {
        return fail("privacy discard invalidates source identity")
    }
    print("buffer source slices smoke passed")
    return true
}
