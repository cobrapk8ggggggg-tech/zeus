import Foundation
private let _maxRenderedLineLength = 2000
func sanitizeForDisplay(_ text: String) -> String {
    guard !text.isEmpty else { return text }

    var out = String()
    out.reserveCapacity(text.count)
    var i = text.unicodeScalars.startIndex
    let end = text.unicodeScalars.endIndex
    let scalars = text.unicodeScalars

    while i < end {
        let s = scalars[i]
        let v = s.value

        // ANSI escape: ESC (0x1B) followed by either '[' (CSI) or ']' (OSC)
        // or a single-char sequence. Swallow the whole thing.
        if v == 0x1B {
            let next = scalars.index(after: i)
            if next < end {
                let n = scalars[next].value
                if n == 0x5B { // '[' — CSI: ESC [ ... final-byte (0x40..0x7E)
                    var j = scalars.index(after: next)
                    while j < end {
                        let c = scalars[j].value
                        j = scalars.index(after: j)
                        if c >= 0x40 && c <= 0x7E { break }
                    }
                    i = j
                    continue
                } else if n == 0x5D { // ']' — OSC: ESC ] ... BEL or ESC \
                    var j = scalars.index(after: next)
                    while j < end {
                        let c = scalars[j].value
                        if c == 0x07 { // BEL
                            j = scalars.index(after: j)
                            break
                        }
                        if c == 0x1B { // ESC — check for ST (ESC \)
                            let k = scalars.index(after: j)
                            if k < end && scalars[k].value == 0x5C {
                                j = scalars.index(after: k)
                                break
                            }
                        }
                        j = scalars.index(after: j)
                    }
                    i = j
                    continue
                } else {
                    // Two-char escape (e.g. ESC M, ESC =) — drop both.
                    i = scalars.index(after: next)
                    continue
                }
            }
            // Lone trailing ESC — drop.
            i = next
            continue
        }

        // Keep \n (0x0A) and \t (0x09); drop/replace other C0 and DEL.
        if (v < 0x20 && v != 0x0A && v != 0x09) || v == 0x7F {
            // Silently drop \r to avoid double line breaks from CRLF.
            if v != 0x0D {
                out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
            }
            i = scalars.index(after: i)
            continue
        }

        // C1 control block (0x80..0x9F) — rare but CoreText fallback-heavy.
        if v >= 0x80 && v <= 0x9F {
            out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
            i = scalars.index(after: i)
            continue
        }

        out.unicodeScalars.append(s)
        i = scalars.index(after: i)
    }

    // Hard-wrap any line longer than the cap. We measure in UTF-16 code
    // units (what CoreText ultimately consumes) to stay cheap and safe
    // against grapheme-cluster walks on huge strings.
    var needsWrap = false
    var run = 0
    for u in out.utf16 {
        if u == 0x0A {
            run = 0
        } else {
            run += 1
            if run > _maxRenderedLineLength { needsWrap = true; break }
        }
    }
    guard needsWrap else { return out }

    var wrapped = String()
    wrapped.reserveCapacity(out.count)
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.utf16.count <= _maxRenderedLineLength {
            wrapped.append(contentsOf: line)
        } else {
            // Break on grapheme boundaries so we don't split a cluster.
            var col = 0
            for ch in line {
                let w = ch.utf16.count
                if col + w > _maxRenderedLineLength {
                    wrapped.append("\n")
                    col = 0
                }
                wrapped.append(ch)
                col += w
            }
        }
        wrapped.append("\n")
    }
    if !out.hasSuffix("\n") { wrapped.removeLast() }
    return wrapped
}
