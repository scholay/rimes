import Foundation

/// One candidate on the current page, already stringified out of the C bridge.
struct RimeCandidateModel {
    let text: String
    let comment: String
    let label: String
}

/// A native snapshot of the current-page Rime context — the in-process
/// replacement for the old state.json payload. Fed directly to the candidate
/// window / buffer.
struct RimeContextModel {
    var active = false
    var preedit = ""
    var input = ""
    var cursorPos = 0
    /// Caret within `input`. `cursorPos` indexes the formatted preedit, which
    /// differs from raw input whenever preedit_format rewrites codes.
    var inputCaretPos: Int?
    var selStart = 0
    var selEnd = 0
    var pageSize = 0
    var pageNo = 0
    var isLastPage = false
    var highlightedIndex = 0
    var candidates: [RimeCandidateModel] = []
}

/// Engine status. `schemaId` is load-bearing: it drives chord gating (chord
/// release-replay runs only for my_combo).
struct RimeStatusModel {
    var schemaId = ""
    var schemaName = ""
    var asciiMode = false
    var fullShape = false
    var simplified = false
    var traditional = false
    var asciiPunct = false
    var composing = false
    var disabled = false
}
