/// Local, advisory syllable boundaries for consciousness-stream input.
///
/// These hints never decode Chinese and must never replace the complete raw
/// value sent to the model. They only give the same global request a few
/// compact, full-coverage readings of an otherwise unseparated `a`...`z`
/// stream. User-entered spaces are hard short-sentence boundaries. Chord-
/// inserted spaces are supplied as sidecar offsets and become fixed syllable
/// boundaries instead; candidates preserve both and never form a syllable
/// across either one. Unknown spans stay visible in brackets so no input is
/// discarded.
///
/// Expected properties (not fixed golden output):
/// - `xiufuyigewenti` strongly favors `xiu'fu'yi'ge'wen'ti`.
/// - `fangan` retains the genuine `fang'an` / `fan'gan` ambiguity.
/// - `wozaicodexlixiuyigebug` keeps every byte and marks non-pinyin-looking
///   spans, while preserving useful surrounding syllables.
enum StreamInputPinyinHints {
    struct Segment: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case syllable
            case unrecognized
            case boundary
            case syllableBoundary
        }

        let spelling: String
        let kind: Kind
    }

    struct Candidate: Equatable, Sendable {
        let segments: [Segment]

        /// A small prompt-friendly representation. Apostrophes are syllable
        /// boundaries, ` | ` is a user-entered Space boundary, and brackets mean
        /// "unrecognized, preserve verbatim".
        var compact: String {
            var clauses = [""]
            for segment in segments {
                switch segment.kind {
                case .syllable:
                    if clauses[clauses.count - 1].isEmpty {
                        clauses[clauses.count - 1] = segment.spelling
                    } else {
                        clauses[clauses.count - 1] += "'\(segment.spelling)"
                    }
                case .unrecognized:
                    let marked = "[\(segment.spelling)]"
                    if clauses[clauses.count - 1].isEmpty {
                        clauses[clauses.count - 1] = marked
                    } else {
                        clauses[clauses.count - 1] += "'\(marked)"
                    }
                case .boundary:
                    clauses.append("")
                case .syllableBoundary:
                    // The next recognized or unknown segment naturally adds
                    // an apostrophe to the current clause. Keep the raw Space
                    // in `segments` without presenting it as a hard ` | `.
                    break
                }
            }
            return clauses.joined(separator: " | ")
        }
    }

    /// Returns at most three probability-neutral structural candidates. The
    /// caller should still ask the model to interpret the complete raw input
    /// globally; candidate order is only a deterministic local preference.
    static func candidates(for raw: String,
                           automaticSyllableSpaceOffsets: Set<Int> = [],
                           maximumCount: Int = 3) -> [Candidate] {
        let limit = min(max(maximumCount, 0), 3)
        guard limit > 0, !raw.isEmpty else { return [] }

        let bytes = Array(raw.utf8)
        guard bytes.allSatisfy({
            (0x61...0x7a).contains($0) || $0 == 0x20
        }) else {
            return []
        }

        // Runtime work remains bounded even if an unexpectedly large value is
        // passed in. The caller still sends the complete raw value, so omitting
        // advisory hints is safer than duplicating a huge unknown span.
        guard bytes.count <= maximumAnalyzedBytes else {
            return []
        }

        var beams = Array(repeating: [Path](), count: bytes.count + 1)
        beams[0] = [Path()]

        for position in bytes.indices {
            guard !beams[position].isEmpty else { continue }
            if bytes[position] == 0x20 {
                for path in beams[position] {
                    var next = path
                    if automaticSyllableSpaceOffsets.contains(position) {
                        next.appendSyllableBoundary(at: position)
                    } else {
                        next.appendBoundary(at: position)
                    }
                    insert(next, into: &beams[position + 1])
                }
                continue
            }
            for path in beams[position] {
                if let spellings = syllablesByFirstByte[bytes[position]] {
                    for spelling in spellings
                    where matches(spelling, at: position, in: bytes) {
                        var next = path
                        next.appendSyllable(from: position,
                                            to: position + spelling.count)
                        insert(next,
                               into: &beams[position + spelling.count])
                    }
                }

                var unknown = path
                unknown.appendUnrecognizedByte(at: position)
                insert(unknown, into: &beams[position + 1])
            }
        }

        let ranked = beams[bytes.count].sorted(by: comesBefore)
        guard let bestScore = ranked.first?.score else { return [] }
        let scoreWindow = min(240, max(110, bytes.count * 16))
        let eligible = ranked.filter { $0.score >= bestScore - scoreWindow }
        var result: [Candidate] = []
        var compactSeen = Set<String>()

        // First offer a conservative rendering of the best unknown islands.
        // For example, incidental `o`/`de` matches between two unknown edges
        // should not split an English-looking span into misleading pinyin.
        if let best = eligible.first {
            let conservative = materialize(
                coalescingSuspiciousUnknownIslands(best.materializedSegments()),
                from: bytes
            )
            compactSeen.insert(conservative.compact)
            result.append(conservative)
            if result.count == limit { return result }

            // With unknown material, only retain alternatives that preserve
            // the best path's recognition coverage. This avoids presenting
            // arbitrary partial matches inside the same Latin-looking span.
            for path in eligible where best.unrecognizedByteCount == 0
                    || (path.unrecognizedByteCount == best.unrecognizedByteCount
                        && path.unrecognizedSegmentCount
                            == best.unrecognizedSegmentCount) {
                let candidate = materialize(path.materializedSegments(),
                                            from: bytes)
                guard compactSeen.insert(candidate.compact).inserted else { continue }
                result.append(candidate)
                if result.count == limit { return result }
            }
        }
        return result
    }

    static func compactHints(for raw: String,
                             automaticSyllableSpaceOffsets: Set<Int> = [],
                             maximumCount: Int = 3) -> [String] {
        candidates(
            for: raw,
            automaticSyllableSpaceOffsets: automaticSyllableSpaceOffsets,
            maximumCount: maximumCount
        ).map(\.compact)
    }

    /// Produces one compact value that can be embedded as advisory metadata in
    /// the existing full-context prompt. It intentionally contains no Chinese
    /// guess and is never suitable as a separately inferred region.
    static func compactPromptValue(for raw: String,
                                   automaticSyllableSpaceOffsets: Set<Int> = [],
                                   maximumCount: Int = 3) -> String? {
        let hints = compactHints(
            for: raw,
            automaticSyllableSpaceOffsets: automaticSyllableSpaceOffsets,
            maximumCount: maximumCount
        )
        guard !hints.isEmpty else { return nil }
        return hints.enumerated().map { index, hint in
            "\(index + 1):\(hint)"
        }.joined(separator: ";")
    }

    private struct RangeSegment: Equatable {
        var lowerBound: Int
        var upperBound: Int
        let recognized: Bool
        let boundary: Bool
        let syllableBoundary: Bool

        init(lowerBound: Int,
             upperBound: Int,
             recognized: Bool,
             boundary: Bool = false,
             syllableBoundary: Bool = false) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
            self.recognized = recognized
            self.boundary = boundary
            self.syllableBoundary = syllableBoundary
        }

        var isBoundary: Bool { boundary || syllableBoundary }
    }

    /// Immutable predecessor nodes let beam paths share their histories. A
    /// transition allocates one tiny node instead of copying every preceding
    /// segment, keeping long ambiguous input close to linear in practice.
    private final class Trail {
        let segment: RangeSegment
        let previous: Trail?
        let count: Int
        let signature: UInt64

        init(segment: RangeSegment, previous: Trail?) {
            self.segment = segment
            self.previous = previous
            count = (previous?.count ?? 0) + 1

            var value = previous?.signature ?? 14_695_981_039_346_656_037
            value ^= UInt64(segment.lowerBound)
            value &*= 1_099_511_628_211
            value ^= UInt64(segment.upperBound)
            value &*= 1_099_511_628_211
            value ^= segment.recognized ? 1 : 0
            value &*= 1_099_511_628_211
            value ^= segment.boundary ? 2 : 0
            value &*= 1_099_511_628_211
            value ^= segment.syllableBoundary ? 4 : 0
            value &*= 1_099_511_628_211
            signature = value
        }
    }

    private struct Path {
        var tail: Trail?
        var score = 0
        var unrecognizedByteCount = 0
        var unrecognizedSegmentCount = 0

        var segmentCount: Int { tail?.count ?? 0 }
        var signature: UInt64 { tail?.signature ?? 0 }

        mutating func appendSyllable(from lowerBound: Int, to upperBound: Int) {
            let length = upperBound - lowerBound
            tail = Trail(
                segment: RangeSegment(lowerBound: lowerBound,
                                      upperBound: upperBound,
                                      recognized: true),
                previous: tail
            )
            // Reward coverage, but charge per syllable. This favors natural
            // longer syllables without erasing equal-cost ambiguities such as
            // fang'an and fan'gan.
            score += length * 60 - 40
            if length == 1 { score -= 30 }
        }

        mutating func appendUnrecognizedByte(at position: Int) {
            unrecognizedByteCount += 1
            score -= 50
            if let previousTail = tail,
               !previousTail.segment.recognized,
               !previousTail.segment.isBoundary,
               previousTail.segment.upperBound == position {
                tail = Trail(
                    segment: RangeSegment(
                        lowerBound: previousTail.segment.lowerBound,
                        upperBound: position + 1,
                        recognized: false
                    ),
                    previous: previousTail.previous
                )
            } else {
                // A substantial start cost groups unknown text instead of
                // cherry-picking incidental syllables from an English span.
                score -= 240
                unrecognizedSegmentCount += 1
                tail = Trail(
                    segment: RangeSegment(lowerBound: position,
                                          upperBound: position + 1,
                                          recognized: false),
                    previous: tail
                )
            }
        }

        mutating func appendBoundary(at position: Int) {
            tail = Trail(
                segment: RangeSegment(lowerBound: position,
                                      upperBound: position + 1,
                                      recognized: false,
                                      boundary: true),
                previous: tail
            )
        }

        mutating func appendSyllableBoundary(at position: Int) {
            tail = Trail(
                segment: RangeSegment(lowerBound: position,
                                      upperBound: position + 1,
                                      recognized: false,
                                      syllableBoundary: true),
                previous: tail
            )
        }

        func materializedSegments() -> [RangeSegment] {
            var reversed: [RangeSegment] = []
            reversed.reserveCapacity(segmentCount)
            var cursor = tail
            while let node = cursor {
                reversed.append(node.segment)
                cursor = node.previous
            }
            return reversed.reversed()
        }
    }

    private static let beamWidth = 24
    // Bound adversarial input even though predecessor sharing keeps normal
    // beam expansion cheap. Longer input still returns one lossless full-span
    // unknown candidate.
    private static let maximumAnalyzedBytes = 512

    private static func insert(_ path: Path, into beam: inout [Path]) {
        // Every transition has a unique boundary/kind history: the syllable
        // inventory is deduplicated and an unknown span has one canonical
        // extension path. No O(pathLength) duplicate comparison is needed.
        beam.append(path)
        beam.sort(by: comesBefore)
        if beam.count > beamWidth {
            beam.removeLast(beam.count - beamWidth)
        }
    }

    private static func comesBefore(_ lhs: Path, _ rhs: Path) -> Bool {
        isPreferred(lhs, over: rhs)
    }

    private static func isPreferred(_ lhs: Path, over rhs: Path) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.unrecognizedByteCount != rhs.unrecognizedByteCount {
            return lhs.unrecognizedByteCount < rhs.unrecognizedByteCount
        }
        if lhs.unrecognizedSegmentCount != rhs.unrecognizedSegmentCount {
            return lhs.unrecognizedSegmentCount < rhs.unrecognizedSegmentCount
        }
        if lhs.segmentCount != rhs.segmentCount {
            return lhs.segmentCount < rhs.segmentCount
        }

        if let left = lhs.tail?.segment, let right = rhs.tail?.segment {
            if left.isBoundary != right.isBoundary {
                return !left.isBoundary && right.isBoundary
            }
            if left.recognized != right.recognized {
                return left.recognized && !right.recognized
            }
            let leftLength = left.upperBound - left.lowerBound
            let rightLength = right.upperBound - right.lowerBound
            if leftLength != rightLength { return leftLength > rightLength }
        }
        return lhs.signature < rhs.signature
    }

    private static func materialize(_ ranges: [RangeSegment],
                                    from bytes: [UInt8]) -> Candidate {
        Candidate(segments: ranges.map { range in
            Segment(
                spelling: String(decoding: bytes[range.lowerBound..<range.upperBound],
                                 as: UTF8.self),
                kind: range.boundary
                    ? .boundary
                    : (range.syllableBoundary
                        ? .syllableBoundary
                        : (range.recognized ? .syllable : .unrecognized))
            )
        })
    }

    /// Joins tiny accidental pinyin matches surrounded by unknown material.
    /// This is only hint presentation: ranges remain complete, ordered, and
    /// byte-for-byte lossless, and the model still receives the original raw.
    private static func coalescingSuspiciousUnknownIslands(
        _ source: [RangeSegment]
    ) -> [RangeSegment] {
        var ranges = source
        var index = 0
        while index < ranges.count {
            guard !ranges[index].recognized, !ranges[index].isBoundary else {
                index += 1
                continue
            }
            var closingUnknown = index + 1
            while closingUnknown < ranges.count,
                  ranges[closingUnknown].recognized {
                closingUnknown += 1
            }
            if closingUnknown < ranges.count,
               !ranges[closingUnknown].isBoundary {
                let spanLength = ranges[closingUnknown].upperBound
                    - ranges[index].lowerBound
                let recognizedBridgeCount = closingUnknown - index - 1
                if spanLength <= 12, recognizedBridgeCount <= 3 {
                    ranges.replaceSubrange(index...closingUnknown, with: [
                        RangeSegment(lowerBound: ranges[index].lowerBound,
                                     upperBound: ranges[closingUnknown].upperBound,
                                     recognized: false),
                    ])
                    continue
                }
            }
            index += 1
        }

        // A single impossible trailing letter often belongs to a short Latin
        // token whose prefix happens to be a legal syllable (for example a
        // three-letter code/word). Keep that token intact as an unknown hint.
        if ranges.count >= 2,
           let unknown = ranges.last,
           !unknown.recognized,
           !unknown.isBoundary,
           unknown.upperBound - unknown.lowerBound == 1 {
            let previousIndex = ranges.count - 2
            let previous = ranges[previousIndex]
            let combinedLength = unknown.upperBound - previous.lowerBound
            if previous.recognized, combinedLength <= 4 {
                ranges.replaceSubrange(previousIndex..., with: [
                    RangeSegment(lowerBound: previous.lowerBound,
                                 upperBound: unknown.upperBound,
                                 recognized: false),
                ])
            }
        }
        return ranges
    }

    private static func matches(_ spelling: [UInt8],
                                at position: Int,
                                in bytes: [UInt8]) -> Bool {
        guard position + spelling.count <= bytes.count else { return false }
        return bytes[position..<(position + spelling.count)]
            .elementsEqual(spelling)
    }

    /// Tone-free Hanyu Pinyin spellings accepted by the hint layer. Rare
    /// interjection-only single consonants are deliberately omitted because
    /// they make arbitrary English text look falsely well segmented.
    private static let syllablesByFirstByte: [UInt8: [[UInt8]]] = {
        let inventory = """
        a ai an ang ao
        ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
        ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
        da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
        e ei en eng er
        fa fan fang fei fen feng fo fou fu
        ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
        ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
        ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
        ka kai kan kang kao ke ken keng kong kou ku kua kuai kuan kuang kui kun kuo
        la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lue lun luo lv lve
        ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
        na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nue nuo nv nve
        o ou
        pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
        qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
        ran rang rao re ren reng ri rong rou ru ruan rui run ruo
        sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
        ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
        wa wai wan wang wei wen weng wo wu
        xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
        ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
        za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
        """
        var grouped: [UInt8: [[UInt8]]] = [:]
        for token in inventory.split(whereSeparator: {
            $0 == " " || $0 == "\n" || $0 == "\t"
        }) {
            let bytes = Array(token.utf8)
            guard let first = bytes.first else { continue }
            grouped[first, default: []].append(bytes)
        }
        for key in Array(grouped.keys) {
            grouped[key]?.sort { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.lexicographicallyPrecedes(rhs)
            }
        }
        return grouped
    }()
}
