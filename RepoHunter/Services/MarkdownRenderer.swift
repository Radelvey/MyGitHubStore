import Foundation

/// Small dependency-free Markdown → HTML converter covering what READMEs and release notes use:
/// headings, fenced code, lists (nested by indent), task lists, block quotes, tables, rules,
/// emphasis, inline code, links, images, autolinks and raw HTML blocks (rendered with JS disabled).
enum MarkdownRenderer {

    static func html(from markdown: String, isDark: Bool, baseURL: URL? = nil) -> String {
        let body = renderBlocks(markdown.replacingOccurrences(of: "\r\n", with: "\n"))
        let base = baseURL.map { "<base href=\"\(escape($0.absoluteString))\">" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8">\(base)
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>\(css(isDark: isDark))</style></head>
        <body><article>\(body)</article></body></html>
        """
    }

    // MARK: Blocks

    private static func renderBlocks(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out = ""
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            out += "<p>\(inline(joined))</p>\n"
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out += "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            // Blank
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Raw HTML block (comments dropped)
            if trimmed.hasPrefix("<!--") {
                flushParagraph()
                while i < lines.count, !lines[i].contains("-->") { i += 1 }
                i += 1
                continue
            }
            if isHTMLBlockStart(trimmed) {
                flushParagraph()
                var html: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    html.append(lines[i]); i += 1
                }
                out += sanitizeHTML(html.joined(separator: "\n")) + "\n"
                continue
            }

            // ATX heading
            if let h = heading(trimmed) {
                flushParagraph()
                out += "<h\(h.level)>\(inline(h.text))</h\(h.level)>\n"
                i += 1
                continue
            }

            // Setext heading
            if !paragraph.isEmpty, isSetextUnderline(trimmed) {
                let level = trimmed.hasPrefix("=") ? 1 : 2
                let text = paragraph.joined(separator: " ")
                paragraph.removeAll()
                out += "<h\(level)>\(inline(text))</h\(level)>\n"
                i += 1
                continue
            }

            // Horizontal rule
            if isRule(trimmed) { flushParagraph(); out += "<hr>\n"; i += 1; continue }

            // Table
            if trimmed.contains("|"), i + 1 < lines.count, isTableDivider(lines[i + 1]) {
                flushParagraph()
                let header = splitRow(trimmed)
                let aligns = splitRow(lines[i + 1]).map(alignment)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitRow(lines[i])); i += 1
                }
                out += table(header: header, rows: rows, aligns: aligns)
                continue
            }

            // Block quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var l = lines[i].trimmingCharacters(in: .whitespaces)
                    l.removeFirst()
                    if l.hasPrefix(" ") { l.removeFirst() }
                    quote.append(l); i += 1
                }
                out += "<blockquote>\(renderBlocks(quote.joined(separator: "\n")))</blockquote>\n"
                continue
            }

            // Lists
            if listMarker(line) != nil {
                flushParagraph()
                var block: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line continues the list only if the next non-blank line is a list item / indented.
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        if j < lines.count, listMarker(lines[j]) != nil || lines[j].hasPrefix("  ") {
                            block.append(""); i += 1; continue
                        }
                        break
                    }
                    if listMarker(l) == nil, !l.hasPrefix(" "), !l.hasPrefix("\t") { break }
                    block.append(l); i += 1
                }
                out += renderList(block)
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return out
    }

    // MARK: Lists

    private struct Marker { let indent: Int; let ordered: Bool; let contentStart: Int }

    private static func listMarker(_ line: String) -> Marker? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            indent += line[idx] == "\t" ? 4 : 1
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return nil }
        let rest = line[idx...]
        if let c = rest.first, "-*+".contains(c), rest.dropFirst().first == " " {
            return Marker(indent: indent, ordered: false, contentStart: line.distance(from: line.startIndex, to: idx) + 2)
        }
        var digits = 0
        for ch in rest {
            if ch.isNumber { digits += 1 } else { break }
        }
        if digits > 0, digits <= 9 {
            let after = rest.dropFirst(digits)
            if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
                return Marker(indent: indent, ordered: true, contentStart: line.distance(from: line.startIndex, to: idx) + digits + 2)
            }
        }
        return nil
    }

    private static func renderList(_ lines: [String]) -> String {
        guard let firstIdx = lines.firstIndex(where: { listMarker($0) != nil }),
              let first = listMarker(lines[firstIdx]) else { return "" }
        let baseIndent = first.indent
        let tag = first.ordered ? "ol" : "ul"

        var items: [[String]] = []
        for line in lines[firstIdx...] {
            if let m = listMarker(line), m.indent <= baseIndent {
                items.append([line])
            } else if !items.isEmpty {
                items[items.count - 1].append(line)
            }
        }

        var html = "<\(tag)>\n"
        for item in items {
            guard let head = item.first, let m = listMarker(head) else { continue }
            var text = String(head.dropFirst(min(m.contentStart, head.count)))
            var checkbox = ""
            if text.hasPrefix("[ ] ") { checkbox = "<input type=\"checkbox\" disabled> "; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { checkbox = "<input type=\"checkbox\" checked disabled> "; text.removeFirst(4) }

            var nested: [String] = []
            var continuation: [String] = [text]
            var inNested = false
            for l in item.dropFirst() {
                if let nm = listMarker(l), nm.indent > baseIndent { inNested = true; nested.append(l) }
                else if inNested { nested.append(l) }
                else { continuation.append(l.trimmingCharacters(in: .whitespaces)) }
            }
            html += "<li>\(checkbox)\(inline(continuation.joined(separator: "\n")))"
            if !nested.isEmpty { html += "\n" + renderList(nested) }
            html += "</li>\n"
        }
        html += "</\(tag)>\n"
        return html
    }

    // MARK: Helpers

    private static func heading(_ s: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in s { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level), s.count > level, s[s.index(s.startIndex, offsetBy: level)] == " " else { return nil }
        var text = String(s.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isSetextUnderline(_ s: String) -> Bool {
        guard s.count >= 2 else { return false }
        return s.allSatisfy { $0 == "=" } || s.allSatisfy { $0 == "-" }
    }

    private static func isRule(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let f = compact.first, "-*_".contains(f) else { return false }
        return compact.allSatisfy { $0 == f }
    }

    private static func isHTMLBlockStart(_ s: String) -> Bool {
        let tags = ["<p", "<div", "<img", "<a ", "<a>", "<h1", "<h2", "<h3", "<h4", "<h5", "<h6", "<table", "<details",
                    "<summary", "<picture", "<br", "<center", "<ul", "<ol", "<hr", "<video", "<kbd", "<sup", "<sub", "<span"]
        let lower = s.lowercased()
        return tags.contains { lower.hasPrefix($0) }
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.contains(":") else { return false }
        return t.allSatisfy { "|-: ".contains($0) } && splitRow(t).allSatisfy { !$0.isEmpty }
    }

    private static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func alignment(_ cell: String) -> String {
        let l = cell.hasPrefix(":"), r = cell.hasSuffix(":")
        if l && r { return "center" }
        if r { return "right" }
        if l { return "left" }
        return ""
    }

    private static func table(header: [String], rows: [[String]], aligns: [String]) -> String {
        func style(_ i: Int) -> String {
            guard i < aligns.count, !aligns[i].isEmpty else { return "" }
            return " style=\"text-align:\(aligns[i])\""
        }
        var h = "<table><thead><tr>"
        for (i, c) in header.enumerated() { h += "<th\(style(i))>\(inline(c))</th>" }
        h += "</tr></thead><tbody>"
        for row in rows {
            h += "<tr>"
            for i in 0..<header.count { h += "<td\(style(i))>\(inline(i < row.count ? row[i] : ""))</td>" }
            h += "</tr>"
        }
        return h + "</tbody></table>\n"
    }

    // MARK: Inline

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func inline(_ raw: String) -> String {
        // 1. Pull out code spans and inline HTML so they are not touched by later rules.
        var stash: [String] = []
        func park(_ html: String) -> String {
            stash.append(html)
            return "\u{1}\(stash.count - 1)\u{2}"
        }

        var s = raw
        s = replace(#"(`+)(.+?)\1"#, in: s) { m in park("<code>\(escape(m[2]))</code>") }
        s = replace(#"</?[a-zA-Z][a-zA-Z0-9]*(?:\s[^>\n]*)?/?>"#, in: s) { m in park(sanitizeHTML(m[0])) }

        s = escape(s)

        // 2. Images then links.
        s = replace(#"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#, in: s) { m in
            park("<img src=\"\(safeURL(m[2]))\" alt=\"\(m[1])\">")
        }
        s = replace(#"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#, in: s) { m in
            "<a href=\"\(safeURL(m[2]))\">\(m[1])</a>"
        }
        // Autolinks <https://…> were escaped to &lt;…&gt;
        s = replace(#"&lt;(https?://[^\s&]+)&gt;"#, in: s) { m in "<a href=\"\(safeURL(m[1]))\">\(m[1])</a>" }
        // Bare URLs
        s = replace(#"(?<![\"'=>\w])(https?://[^\s<\)]+[^\s<\).,;:!?])"#, in: s) { m in
            "<a href=\"\(safeURL(m[1]))\">\(m[1])</a>"
        }

        // 3. Emphasis
        s = replace(#"\*\*\*(.+?)\*\*\*"#, in: s) { "<strong><em>\($0[1])</em></strong>" }
        s = replace(#"\*\*(.+?)\*\*"#, in: s) { "<strong>\($0[1])</strong>" }
        s = replace(#"(?<![\w])__(.+?)__(?![\w])"#, in: s) { "<strong>\($0[1])</strong>" }
        s = replace(#"\*(?!\s)(.+?)(?<!\s)\*"#, in: s) { "<em>\($0[1])</em>" }
        s = replace(#"(?<![\w])_(?!\s)(.+?)(?<!\s)_(?![\w])"#, in: s) { "<em>\($0[1])</em>" }
        s = replace(#"~~(.+?)~~"#, in: s) { "<del>\($0[1])</del>" }

        // 4. Hard breaks
        s = s.replacingOccurrences(of: "  \n", with: "<br>\n")

        // 5. Restore parked fragments (may be nested once).
        for _ in 0..<2 {
            s = replace("\u{1}(\\d+)\u{2}", in: s) { m in
                if let idx = Int(m[1]), idx < stash.count { return stash[idx] }
                return ""
            }
        }
        return s
    }

    /// Only allow http(s), mailto, anchors and relative paths in URLs.
    private static func safeURL(_ url: String) -> String {
        let u = url.trimmingCharacters(in: .whitespaces)
        let lower = u.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:text") || lower.hasPrefix("vbscript:") { return "#" }
        return u
    }

    /// Strips scripts/handlers/iframes from raw HTML. The web view also has JavaScript disabled.
    static func sanitizeHTML(_ html: String) -> String {
        var s = html
        s = replace(#"(?is)<(script|style|iframe|object|embed|form|link|meta)\b.*?(</\1>|$)"#, in: s) { _ in "" }
        s = replace(#"(?i)\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, in: s) { _ in "" }
        s = replace(#"(?i)(href|src)\s*=\s*("|')\s*javascript:[^"']*("|')"#, in: s) { _ in "" }
        return s
    }

    // MARK: Regex utility

    /// Replaces every match; `m` holds [whole, group1, group2, …].
    private static func replace(_ pattern: String, in input: String, _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        for match in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: Stylesheet

    private static func css(isDark: Bool) -> String {
        let fg = isDark ? "#e6edf3" : "#1f2328"
        let muted = isDark ? "#9198a1" : "#59636e"
        let border = isDark ? "#3d444d" : "#d1d9e0"
        let codeBG = isDark ? "#151b23" : "#f6f8fa"
        let link = isDark ? "#4493f8" : "#0969da"
        return """
        :root{color-scheme:\(isDark ? "dark" : "light")}
        html,body{margin:0;background:transparent;color:\(fg)}
        body{font:14px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif;word-wrap:break-word}
        article{padding:4px 2px 24px}
        h1,h2,h3,h4,h5,h6{margin:1.4em 0 .6em;font-weight:600;line-height:1.25}
        h1{font-size:1.9em;padding-bottom:.3em;border-bottom:1px solid \(border)}
        h2{font-size:1.5em;padding-bottom:.3em;border-bottom:1px solid \(border)}
        h3{font-size:1.25em} h4{font-size:1em} h5,h6{font-size:.9em;color:\(muted)}
        a{color:\(link);text-decoration:none} a:hover{text-decoration:underline}
        p,ul,ol,pre,blockquote,table{margin:0 0 14px}
        ul,ol{padding-left:2em} li{margin:.25em 0} li>ul,li>ol{margin:.25em 0 0}
        img{max-width:100%;height:auto;vertical-align:middle}
        code{font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace;background:\(codeBG);padding:.15em .4em;border-radius:6px}
        pre{background:\(codeBG);padding:14px;border-radius:8px;overflow:auto;border:1px solid \(border)}
        pre code{background:none;padding:0;font-size:12px;line-height:1.5}
        blockquote{margin-left:0;padding:0 1em;color:\(muted);border-left:.25em solid \(border)}
        hr{border:0;border-top:1px solid \(border);margin:24px 0}
        table{border-collapse:collapse;display:block;overflow:auto}
        th,td{border:1px solid \(border);padding:6px 13px} th{background:\(codeBG);font-weight:600}
        kbd{font:11px ui-monospace,Menlo,monospace;border:1px solid \(border);border-radius:5px;padding:2px 5px;background:\(codeBG)}
        details{margin-bottom:14px} summary{cursor:pointer}
        """
    }
}
