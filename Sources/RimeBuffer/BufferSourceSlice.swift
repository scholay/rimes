import Foundation

/// Exact process-local source ownership. The range is relative to one live
/// block's UTF-16 text, not a substring search or a translated output index.
struct BufferSourceSlice: Equatable {
    let blockID: UUID
    let range: NSRange
    let text: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.blockID == rhs.blockID && lhs.range == rhs.range
            && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }

    /// Capture a global range from the exact ordered source rail. Neither a
    /// surrogate pair nor an extended grapheme cluster may be cut in half.
    static func capture(range: NSRange,
                        in blocks: [BufferModel.Block]) -> [Self]? {
        guard let end = checkedEnd(range), range.length > 0 else { return nil }
        var offset = 0
        var result: [Self] = []
        for block in blocks {
            let length = block.text.utf16.count
            let (blockEnd, overflow) = offset.addingReportingOverflow(length)
            guard !overflow else { return nil }
            let lower = max(range.location, offset)
            let upper = min(end, blockEnd)
            if lower < upper {
                let local = NSRange(location: lower - offset, length: upper - lower)
                guard let fragment = exactText(in: block.text, range: local) else {
                    return nil
                }
                result.append(Self(blockID: block.id, range: local, text: fragment))
            }
            offset = blockEnd
        }
        guard end <= offset, !result.isEmpty,
              matches(result, in: blocks) else { return nil }
        return result
    }

    /// Validate the complete set before a source mutation. Order, identity,
    /// exact text, nonoverlap and current translation provenance all matter.
    /// Gaps are permitted so several separately owned ranges can be consumed
    /// in one transaction; a translation unit must separately retain its own
    /// contiguous source-boundary identity.
    static func matches(_ slices: [Self],
                        in blocks: [BufferModel.Block]) -> Bool {
        guard !slices.isEmpty, validNonoverlappingRanges(slices) else { return false }
        var positions: [UUID: Int] = [:]
        for (index, block) in blocks.enumerated() {
            guard positions.updateValue(index, forKey: block.id) == nil else {
                return false
            }
        }
        var previousPosition = -1
        var previousEnd = 0
        for slice in slices {
            guard let position = positions[slice.blockID],
                  position >= previousPosition else { return false }
            let block = blocks[position]
            guard block.pluginMetadata?.incomplete != true,
                  TranslationSourcePolicy.accepts([block]),
                  let current = exactText(in: block.text, range: slice.range),
                  current.utf16.elementsEqual(slice.text.utf16),
                  position != previousPosition || slice.range.location >= previousEnd else {
                return false
            }
            previousPosition = position
            previousEnd = slice.range.location + slice.range.length
        }
        return true
    }

    /// Rebase untouched ownership after an exact source consumption. An
    /// overlap is not recoverable by finding equal text elsewhere: callers
    /// must remove the consumed unit before rebasing remaining units/jobs.
    static func rebasing(_ slices: [Self],
                         afterConsuming consumed: [Self]) -> [Self]? {
        guard validNonoverlappingRanges(slices),
              validNonoverlappingRanges(consumed) else { return nil }
        let grouped = Dictionary(grouping: consumed, by: \.blockID)
        var result: [Self] = []
        result.reserveCapacity(slices.count)
        for slice in slices {
            guard let end = checkedEnd(slice.range) else { return nil }
            var shift = 0
            for removal in grouped[slice.blockID] ?? [] {
                guard let removalEnd = checkedEnd(removal.range) else { return nil }
                if removal.range.location < end && slice.range.location < removalEnd {
                    return nil
                }
                if removalEnd <= slice.range.location {
                    let (nextShift, overflow) = shift.addingReportingOverflow(removal.range.length)
                    guard !overflow else { return nil }
                    shift = nextShift
                }
            }
            guard shift <= slice.range.location else { return nil }
            result.append(Self(blockID: slice.blockID,
                               range: NSRange(location: slice.range.location - shift,
                                              length: slice.range.length),
                               text: slice.text))
        }
        return result
    }

    private static func validNonoverlappingRanges(_ slices: [Self]) -> Bool {
        let grouped = Dictionary(grouping: slices, by: \.blockID)
        for group in grouped.values {
            var previousEnd = 0
            for slice in group.sorted(by: { $0.range.location < $1.range.location }) {
                guard let end = checkedEnd(slice.range), slice.range.length > 0,
                      slice.range.length == slice.text.utf16.count,
                      slice.range.location >= previousEnd else { return false }
                previousEnd = end
            }
        }
        return true
    }

    private static func checkedEnd(_ range: NSRange) -> Int? {
        guard range.location >= 0, range.location != NSNotFound,
              range.length >= 0 else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return overflow ? nil : end
    }

    private static func exactText(in text: String, range: NSRange) -> String? {
        guard let end = checkedEnd(range), range.length > 0,
              end <= text.utf16.count else { return nil }
        let value = text as NSString
        guard value.rangeOfComposedCharacterSequences(for: range) == range else {
            return nil
        }
        return value.substring(with: range)
    }
}
