import Foundation

/// Draws a Mermaid flowchart as box-drawing ASCII art (SPEC §2.12, MODAL.md).
/// The editor shows it in place of a ```mermaid block while the caret is
/// elsewhere; the text itself stays Mermaid. Pure, tested.
///
/// Supported: `graph`/`flowchart` with LR, RL (drawn LR), TD, TB, BT (drawn
/// TD); nodes `A`, `A[x]`, `A(x)`, `A((x))`, `A{x}`, `A([x])`, `A["x"]`,
/// `<br>` line breaks; links `-->`, `---`, `-.->`, `==>`, `--o`, `--x`, with
/// `|label|` or `-- label -->`; chains (`A --> B --> C`) and `&` groups.
/// Ignored: subgraph/end, style, classDef, class, click, linkStyle, `%%`.
enum MermaidASCII {
    /// Guard against pathological input: the editor repaints on keystrokes.
    static let maxNodes = 80

    struct Node: Equatable {
        var id: String
        var label: [String]
        var rounded = false
    }

    struct Edge: Equatable {
        var from: String
        var to: String
        var label: String?
        var arrow = true
        var dotted = false
    }

    struct Graph: Equatable {
        var vertical = false
        var nodes: [Node] = []
        var edges: [Edge] = []
    }

    /// The art for a block's source (the lines between the fences), or nil
    /// when it is not a flowchart this can draw.
    static func render(_ source: String) -> String? { drawing(source)?.text }

    /// One box of a drawing, in character cells of its art.
    struct Box: Equatable {
        var id: String
        var rank: Int
        var x: Int, y: Int, width: Int, height: Int

        func contains(column: Int, row: Int) -> Bool {
            column >= x && column < x + width && row >= y && row < y + height
        }
    }

    struct Drawing: Equatable {
        var text: String
        var boxes: [Box]
        var vertical: Bool
        /// The saved box order (`%% clipb-order:`) the drawing honoured.
        var order: [String]

        func box(column: Int, row: Int) -> Box? { boxes.first { $0.contains(column: column, row: row) } }

        /// The order to save after dropping `id` at `cross` (a column in a
        /// top-down chart, a row left to right): its layer is re-sorted with
        /// the box at the drop point; other layers keep what they had.
        func order(moving id: String, to cross: Int) -> [String] {
            guard let moved = boxes.first(where: { $0.id == id }) else { return order }
            let crossStart = { (b: Box) in vertical ? b.x : b.y }
            let crossSize = { (b: Box) in vertical ? b.width : b.height }
            let others = boxes.filter { $0.rank == moved.rank && $0.id != id }.sorted { crossStart($0) < crossStart($1) }
            let at = others.filter { crossStart($0) + crossSize($0) / 2 < cross }.count
            var layer = others.map(\.id)
            layer.insert(id, at: at)
            let known = Set(boxes.map(\.id))
            return order.filter { known.contains($0) && !layer.contains($0) } + layer
        }
    }

    /// `%% clipb-order: A B C` — box order saved by dragging. Mermaid reads it
    /// as a comment, so the block stays portable.
    static let orderPrefix = "%% clipb-order:"

    static func savedOrder(in source: String) -> [String] {
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(orderPrefix) else { continue }
            return trimmed.dropFirst(orderPrefix.count).split(separator: " ").map(String.init)
        }
        return []
    }

    /// `source` with its saved order replaced by `order`: the comment line is
    /// rewritten in place, or added under the `graph` header.
    static func withOrder(_ order: [String], in source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        let existing = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(orderPrefix) }
        let indentOf = { (line: String) in String(line.prefix { $0 == " " || $0 == "\t" }) }
        if order.isEmpty {
            if let existing { lines.remove(at: existing) }
            return lines.joined(separator: "\n")
        }
        if let existing {
            lines[existing] = indentOf(lines[existing]) + orderPrefix + " " + order.joined(separator: " ")
            return lines.joined(separator: "\n")
        }
        let header = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%%") } ?? 0
        let sample = lines.indices.contains(header + 1) ? indentOf(lines[header + 1]) : ""
        lines.insert((sample.isEmpty ? "  " : sample) + orderPrefix + " " + order.joined(separator: " "), at: min(header + 1, lines.count))
        return lines.joined(separator: "\n")
    }

    /// The art and where its boxes are; `order` overrides the saved order
    /// (a drag in progress).
    static func drawing(_ source: String, order override: [String]? = nil) -> Drawing? {
        guard let graph = parse(source), !graph.nodes.isEmpty, graph.nodes.count <= maxNodes else { return nil }
        let order = override ?? savedOrder(in: source)
        var layout = Layout(graph, order: order)
        let text = layout.draw()
        return Drawing(text: text, boxes: layout.boxes(), vertical: graph.vertical, order: order)
    }

    // MARK: - Parsing

    static func parse(_ source: String) -> Graph? {
        var statements: [String] = []
        for line in source.components(separatedBy: .newlines) {
            statements.append(contentsOf: splitStatements(line))
        }
        statements = statements.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = statements.first else { return nil }
        let words = header.split(separator: " ").map(String.init)
        guard let kind = words.first?.lowercased(), kind == "graph" || kind == "flowchart" else { return nil }
        var graph = Graph()
        let direction = words.count > 1 ? words[1].uppercased() : "TD"
        graph.vertical = !(direction == "LR" || direction == "RL")
        var index: [String: Int] = [:]
        // A header can carry the first statement: `graph LR; A-->B` was split already.
        for statement in statements.dropFirst() {
            let first = statement.split(separator: " ").first.map { String($0).lowercased() } ?? ""
            if ["subgraph", "end", "style", "classdef", "class", "click", "linkstyle", "direction"].contains(first) { continue }
            guard parseStatement(statement, into: &graph, index: &index) else { return nil }
        }
        return graph
    }

    /// `;` ends a statement unless it sits inside a label.
    private static func splitStatements(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() }
            if !quoted {
                if "[({".contains(ch) { depth += 1 }
                if "])}".contains(ch) { depth = max(0, depth - 1) }
            }
            if ch == ";", depth == 0, !quoted {
                out.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        out.append(current)
        return out
    }

    private struct Scanner {
        let chars: [Character]
        var at = 0
        var done: Bool { at >= chars.count }
        var peek: Character? { done ? nil : chars[at] }

        mutating func skipSpaces() { while let c = peek, c == " " || c == "\t" { at += 1 } }

        func starts(with text: String) -> Bool {
            let t = Array(text)
            guard at + t.count <= chars.count else { return false }
            return Array(chars[at..<at + t.count]) == t
        }
    }

    private static func isIDChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "."
    }

    private static let closers: [Character: Character] = ["[": "]", "(": ")", "{": "}", ">": "]"]

    /// One node reference, defining its label when it has one.
    private static func parseNode(_ s: inout Scanner, graph: inout Graph, index: inout [String: Int]) -> String? {
        s.skipSpaces()
        var id = ""
        while let c = s.peek, isIDChar(c) || (c == "-" && !id.isEmpty && !s.starts(with: "--") && !s.starts(with: "-.")) {
            id.append(c)
            s.at += 1
        }
        guard !id.isEmpty else { return nil }
        var label: String?
        var rounded = false
        if let open = s.peek, closers[open] != nil {
            // The opening run, e.g. `((`, `([`, `[(`, `{{`, `[/`.
            var opening: [Character] = []
            while let c = s.peek, "[({>/\\".contains(c), opening.count < 3 {
                opening.append(c)
                s.at += 1
            }
            rounded = opening.first == "("
            var text = ""
            var quoted = false
            var depth = 0
            while let c = s.peek {
                if c == "\"" { quoted.toggle() }
                if !quoted {
                    if "[({".contains(c) { depth += 1 }
                    if "])}".contains(c) {
                        if depth == 0 { break }
                        depth -= 1
                    }
                }
                text.append(c)
                s.at += 1
            }
            // The closing run mirrors the opening one.
            while let c = s.peek, "])}/\\".contains(c) { s.at += 1 }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
            label = text
        }
        // `A:::className`
        if s.starts(with: ":::") {
            s.at += 3
            while let c = s.peek, isIDChar(c) || c == "-" { s.at += 1 }
        }
        let lines = label.map { text in
            text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let existing = index[id] {
            if let lines {
                graph.nodes[existing].label = lines
                graph.nodes[existing].rounded = rounded
            }
        } else {
            index[id] = graph.nodes.count
            graph.nodes.append(Node(id: id, label: lines ?? [id], rounded: rounded))
        }
        return id
    }

    /// One link operator, or nil when the next text is not one.
    private static func parseLink(_ s: inout Scanner) -> (label: String?, arrow: Bool, dotted: Bool)? {
        s.skipSpaces()
        let start = s.at
        if s.peek == "<" { s.at += 1 }
        var run = ""
        while let c = s.peek, c == "-" || c == "=" || c == "." {
            run.append(c)
            s.at += 1
        }
        guard run.count >= 2 || run == "-" && s.peek == "." else {
            s.at = start
            return nil
        }
        var label: String?
        var arrow = false
        if let c = s.peek, c == ">" || c == "o" || c == "x", !(s.at + 1 < s.chars.count && isIDChar(s.chars[s.at + 1]) && c != ">") {
            arrow = true
            s.at += 1
        } else if run == "--" || run == "==" || run == "-." {
            // `-- label -->`: the text runs to the closing operator.
            let rest = String(s.chars[s.at...])
            let pattern = #"^\s*(.+?)\s*(-{2,}>|-{3,}|={2,}>|={3,}|\.-+>|\.-+)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                label = (rest as NSString).substring(with: m.range(at: 1))
                let closing = (rest as NSString).substring(with: m.range(at: 2))
                arrow = closing.hasSuffix(">")
                s.at += (rest as NSString).substring(to: NSMaxRange(m.range)).count
            }
        }
        let dotted = run.contains(".")
        s.skipSpaces()
        if s.peek == "|" {
            s.at += 1
            var text = ""
            while let c = s.peek, c != "|" {
                text.append(c)
                s.at += 1
            }
            s.at += 1
            label = text.trimmingCharacters(in: .whitespaces)
        }
        if let l = label, l.hasPrefix("\""), l.hasSuffix("\""), l.count >= 2 { label = String(l.dropFirst().dropLast()) }
        return (label?.isEmpty == true ? nil : label, arrow, dotted)
    }

    private static func parseGroup(_ s: inout Scanner, graph: inout Graph, index: inout [String: Int]) -> [String]? {
        var ids: [String] = []
        repeat {
            if !ids.isEmpty { s.at += 1 }
            guard let id = parseNode(&s, graph: &graph, index: &index) else { return nil }
            ids.append(id)
            s.skipSpaces()
        } while s.peek == "&"
        return ids
    }

    private static func parseStatement(_ statement: String, into graph: inout Graph, index: inout [String: Int]) -> Bool {
        var s = Scanner(chars: Array(statement))
        guard var left = parseGroup(&s, graph: &graph, index: &index) else { return false }
        while true {
            s.skipSpaces()
            if s.done { return true }
            guard let link = parseLink(&s), let right = parseGroup(&s, graph: &graph, index: &index) else { return false }
            for a in left {
                for b in right {
                    graph.edges.append(Edge(from: a, to: b, label: link.label, arrow: link.arrow, dotted: link.dotted))
                }
            }
            left = right
        }
    }

    // MARK: - Layout

    /// Layered layout: ranks by longest path (back edges reversed), dummy
    /// nodes for edges that skip ranks, barycenter ordering, then boxes on a
    /// character grid with orthogonal links that merge into junctions.
    private struct Layout {
        struct Item {
            var node: Int?          // index into graph.nodes; nil for a dummy
            var rank = 0
            var order = 0
            var main = 0            // start along the flow
            var cross = 0           // start across it
            var mainSize = 0
            var crossSize = 1
            var crossCenter: Int { cross + crossSize / 2 }
        }

        struct Segment {
            var from: Int, to: Int  // items, adjacent ranks
            var edge: Int
            var last: Bool          // the segment that reaches the real target
            var first: Bool
        }

        let graph: Graph
        var items: [Item] = []
        var segments: [Segment] = []
        var reversed: Set<Int> = []
        var ranks: [[Int]] = []

        /// Saved box order: within a layer, these boxes keep this order.
        let pinned: [String]

        init(_ graph: Graph, order pinned: [String] = []) {
            self.graph = graph
            self.pinned = pinned
            for (i, node) in graph.nodes.enumerated() {
                let width = (node.label.map(\.count).max() ?? 0) + 4
                let height = node.label.count + 2
                items.append(Item(node: i, mainSize: graph.vertical ? height : width, crossSize: graph.vertical ? width : height))
            }
            rank()
            buildSegments()
            order()
        }

        private func nodeIndex(_ id: String) -> Int { graph.nodes.firstIndex { $0.id == id } ?? 0 }

        /// Depth-first: an edge back to a node still on the stack closes a
        /// cycle and is laid out reversed.
        private mutating func rank() {
            let n = graph.nodes.count
            var out = [[Int]](repeating: [], count: n)
            for (e, edge) in graph.edges.enumerated() { out[nodeIndex(edge.from)].append(e) }
            var state = [Int](repeating: 0, count: n)
            func visit(_ v: Int) {
                state[v] = 1
                for e in out[v] {
                    let w = nodeIndex(graph.edges[e].to)
                    if state[w] == 1 { reversed.insert(e) } else if state[w] == 0 { visit(w) }
                }
                state[v] = 2
            }
            for v in 0..<n where state[v] == 0 { visit(v) }
            // Longest path over the now acyclic edges.
            var rankOf = [Int](repeating: 0, count: n)
            var changed = true
            var guardCount = 0
            while changed, guardCount <= n {
                changed = false
                guardCount += 1
                for (e, _) in graph.edges.enumerated() {
                    let (a, b) = ends(e)
                    if a != b, rankOf[b] < rankOf[a] + 1 { rankOf[b] = rankOf[a] + 1; changed = true }
                }
            }
            for v in 0..<n { items[v].rank = rankOf[v] }
        }

        /// Layout direction of an edge: (upper rank item, lower rank item).
        func ends(_ e: Int) -> (Int, Int) {
            let a = nodeIndex(graph.edges[e].from), b = nodeIndex(graph.edges[e].to)
            return reversed.contains(e) ? (b, a) : (a, b)
        }

        private mutating func buildSegments() {
            for e in graph.edges.indices {
                let (a, b) = ends(e)
                guard a != b else { continue }
                var previous = a
                var r = items[a].rank + 1
                while r < items[b].rank {
                    items.append(Item(node: nil, rank: r, mainSize: 0, crossSize: 1))
                    let dummy = items.count - 1
                    segments.append(Segment(from: previous, to: dummy, edge: e, last: false, first: previous == a))
                    previous = dummy
                    r += 1
                }
                segments.append(Segment(from: previous, to: b, edge: e, last: true, first: previous == a))
            }
        }

        private mutating func order() {
            let count = (items.map(\.rank).max() ?? 0) + 1
            ranks = [[Int]](repeating: [], count: count)
            for i in items.indices { ranks[items[i].rank].append(i) }
            for r in ranks.indices { for (o, i) in ranks[r].enumerated() { items[i].order = o } }
            // Barycenter sweeps, down then up.
            for sweep in 0..<4 {
                let down = sweep % 2 == 0
                let sequence = down ? Array(1..<max(1, ranks.count)) : Array((0..<max(0, ranks.count - 1)).reversed())
                for r in sequence {
                    func score(_ i: Int) -> Double {
                        let neighbors = segments.compactMap { s -> Int? in
                            if down, s.to == i { return items[s.from].order }
                            if !down, s.from == i { return items[s.to].order }
                            return nil
                        }
                        return neighbors.isEmpty ? Double(items[i].order) : Double(neighbors.reduce(0, +)) / Double(neighbors.count)
                    }
                    let scored = ranks[r].map { ($0, score($0)) }
                    ranks[r] = scored.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map { $0.element.0 }
                    for (o, i) in ranks[r].enumerated() { items[i].order = o }
                }
            }
            applyPinnedOrder()
        }

        /// The boxes named in the saved order trade places among the slots
        /// they hold; new boxes and link bends keep the slots the sweeps gave
        /// them, so a box added later still lands somewhere sensible.
        private mutating func applyPinnedOrder() {
            guard !pinned.isEmpty else { return }
            var position: [String: Int] = [:]
            for (k, id) in pinned.enumerated() where position[id] == nil { position[id] = k }
            let snapshot = items, nodes = graph.nodes
            let key = { (i: Int) -> Int? in snapshot[i].node.flatMap { position[nodes[$0].id] } }
            for r in ranks.indices {
                let slots = ranks[r].indices.filter { key(ranks[r][$0]) != nil }
                let sorted = slots.map { ranks[r][$0] }.sorted { key($0)! < key($1)! }
                for (k, slot) in slots.enumerated() { ranks[r][slot] = sorted[k] }
                for (o, i) in ranks[r].enumerated() { items[i].order = o }
            }
        }

        /// Where each box was drawn; call after `draw()`.
        func boxes() -> [Box] {
            items.compactMap { item in
                guard let n = item.node else { return nil }
                let v = graph.vertical
                return Box(id: graph.nodes[n].id, rank: item.rank,
                           x: v ? item.cross : item.main, y: v ? item.main : item.cross,
                           width: v ? item.crossSize : item.mainSize, height: v ? item.mainSize : item.crossSize)
            }
        }

        /// Gaps along the flow: wide enough for the link labels that cross them.
        private func gap(after rank: Int) -> Int {
            let labels = segments.filter { $0.last && items[$0.from].rank == rank }
                .compactMap { graph.edges[$0.edge].label?.count }
            let longest = labels.max() ?? 0
            if graph.vertical { return longest > 0 ? 4 : 3 }
            // corner, " label ", then at least "─►".
            return max(6, longest > 0 ? longest + 7 : 6)
        }

        /// Any labelled link in the gap after this rank: the bend moves next
        /// to the source so the labels fit before the arrows.
        private func labelled(after rank: Int) -> Bool {
            segments.contains { $0.last && items[$0.from].rank == rank && graph.edges[$0.edge].label != nil }
        }

        private var crossGap: Int { graph.vertical ? 3 : 1 }

        private mutating func position() {
            // Along the flow: rank by rank.
            var main = 0
            for r in ranks.indices {
                let size = ranks[r].map { items[$0].mainSize }.max() ?? 0
                for i in ranks[r] {
                    items[i].main = main
                    if items[i].node == nil { items[i].mainSize = size }
                }
                main += size + gap(after: r)
            }
            // Across: centered on the neighbours, pushed apart in order.
            func place(_ r: Int, toward neighbors: (Int) -> [Int]) {
                var end = -crossGap
                for i in ranks[r] {
                    let near = neighbors(i)
                    var start = end + crossGap
                    if !near.isEmpty {
                        let center = near.map { items[$0].crossCenter }.reduce(0, +) / near.count
                        start = max(start, center - items[i].crossSize / 2)
                    }
                    items[i].cross = start
                    end = start + items[i].crossSize
                }
            }
            let preds = { (i: Int) in self.segments.filter { $0.to == i }.map(\.from) }
            let succs = { (i: Int) in self.segments.filter { $0.from == i }.map(\.to) }
            for r in ranks.indices { place(r, toward: r == 0 ? { _ in [] } : preds) }
            defer {
                // No blank band above or beside the drawing.
                let low = items.map(\.cross).min() ?? 0
                for i in items.indices { items[i].cross -= low }
            }
            for r in ranks.indices.reversed() where r < ranks.count - 1 {
                // Parents over the middle of their children, never past them.
                let before = ranks[r].map { items[$0].cross }
                place(r, toward: succs)
                for (k, i) in ranks[r].enumerated() where items[i].cross < before[k] { items[i].cross = before[k] }
                // Order stays: push the rest along.
                var end = Int.min / 2
                for i in ranks[r] {
                    items[i].cross = max(items[i].cross, end + crossGap)
                    end = items[i].cross + items[i].crossSize
                }
            }
        }

        // MARK: Drawing

        struct Canvas {
            var chars: [[Character]]
            var bits: [[UInt8]]
            var dotted: [[Bool]]
            static let left: UInt8 = 1, right: UInt8 = 2, up: UInt8 = 4, down: UInt8 = 8

            init(width: Int, height: Int) {
                chars = [[Character]](repeating: [Character](repeating: " ", count: width), count: height)
                bits = [[UInt8]](repeating: [UInt8](repeating: 0, count: width), count: height)
                dotted = [[Bool]](repeating: [Bool](repeating: false, count: width), count: height)
            }

            func inside(_ x: Int, _ y: Int) -> Bool { y >= 0 && y < chars.count && x >= 0 && x < chars[y].count }

            mutating func set(_ x: Int, _ y: Int, _ c: Character) {
                guard inside(x, y) else { return }
                chars[y][x] = c
                bits[y][x] = 0
            }

            mutating func line(_ a: (Int, Int), _ b: (Int, Int), dotted dot: Bool) {
                let (x1, y1) = a, (x2, y2) = b
                if y1 == y2 {
                    let lo = min(x1, x2), hi = max(x1, x2)
                    for x in lo...hi where inside(x, y1) && chars[y1][x] == " " || inside(x, y1) && bits[y1][x] != 0 {
                        if x > lo { bits[y1][x] |= Self.left }
                        if x < hi { bits[y1][x] |= Self.right }
                        if lo == hi { bits[y1][x] |= 0 }
                        if dot { dotted[y1][x] = true }
                    }
                } else {
                    let lo = min(y1, y2), hi = max(y1, y2)
                    for y in lo...hi where inside(x1, y) && (chars[y][x1] == " " || bits[y][x1] != 0) {
                        if y > lo { bits[y][x1] |= Self.up }
                        if y < hi { bits[y][x1] |= Self.down }
                        if dot { dotted[y][x1] = true }
                    }
                }
            }

            mutating func addBits(_ x: Int, _ y: Int, _ b: UInt8) {
                guard inside(x, y), chars[y][x] == " " || bits[y][x] != 0 else { return }
                bits[y][x] |= b
            }

            func text() -> String {
                var lines: [String] = []
                for y in chars.indices {
                    var line = ""
                    for x in chars[y].indices {
                        let b = bits[y][x]
                        line.append(b == 0 ? chars[y][x] : Self.glyph(b, dotted: dotted[y][x]))
                    }
                    lines.append(String(line.reversed().drop { $0 == " " }.reversed()))
                }
                while lines.last?.isEmpty == true { lines.removeLast() }
                return lines.joined(separator: "\n")
            }

            static func glyph(_ b: UInt8, dotted: Bool) -> Character {
                let l = b & left != 0, r = b & right != 0, u = b & up != 0, d = b & down != 0
                switch (l, r, u, d) {
                case (true, true, true, true): return "┼"
                case (true, true, false, true): return "┬"
                case (true, true, true, false): return "┴"
                case (false, true, true, true): return "├"
                case (true, false, true, true): return "┤"
                case (false, true, false, true): return "┌"
                case (true, false, false, true): return "┐"
                case (false, true, true, false): return "└"
                case (true, false, true, false): return "┘"
                case (_, _, false, false): return dotted ? "┄" : "─"
                default: return dotted ? "┆" : "│"
                }
            }
        }

        mutating func draw() -> String {
            position()
            let vertical = graph.vertical
            func xy(_ main: Int, _ cross: Int) -> (Int, Int) { vertical ? (cross, main) : (main, cross) }
            var width = 0, height = 0
            for item in items {
                let (x, y) = xy(item.main + item.mainSize, item.cross + item.crossSize)
                width = max(width, x + 1)
                height = max(height, y + 1)
            }
            // Room for labels beside vertical links.
            width += vertical ? (graph.edges.compactMap { $0.label?.count }.max() ?? 0) + 3 : 0
            var canvas = Canvas(width: width, height: height)

            // Boxes first: links never draw over them.
            for item in items {
                guard let n = item.node else { continue }
                let node = graph.nodes[n]
                let (x0, y0) = xy(item.main, item.cross)
                let w = vertical ? item.crossSize : item.mainSize
                let h = vertical ? item.mainSize : item.crossSize
                let (tl, tr, bl, br): (Character, Character, Character, Character) = node.rounded ? ("╭", "╮", "╰", "╯") : ("┌", "┐", "└", "┘")
                for x in x0..<x0 + w {
                    canvas.set(x, y0, "─")
                    canvas.set(x, y0 + h - 1, "─")
                }
                for y in y0..<y0 + h {
                    canvas.set(x0, y, "│")
                    canvas.set(x0 + w - 1, y, "│")
                }
                canvas.set(x0, y0, tl); canvas.set(x0 + w - 1, y0, tr)
                canvas.set(x0, y0 + h - 1, bl); canvas.set(x0 + w - 1, y0 + h - 1, br)
                for (k, text) in node.label.enumerated() {
                    let pad = (w - 4 - text.count) / 2
                    for (j, c) in text.enumerated() { canvas.set(x0 + 2 + pad + j, y0 + 1 + k, c) }
                }
            }

            // Links: out of the box, to the middle of the gap, across, in.
            var heads: [(Int, Int, Character)] = []
            var labels: [(Int, Int, String)] = []
            for segment in segments {
                let a = items[segment.from], b = items[segment.to]
                let edge = graph.edges[segment.edge]
                let isReversed = reversed.contains(segment.edge)
                let exit = a.main + a.mainSize
                let entry = b.main - 1
                let gapStart = a.main + (ranks[a.rank].map { items[$0].mainSize }.max() ?? a.mainSize)
                let mid = labelled(after: a.rank) ? gapStart + (vertical ? 1 : 2) : gapStart + max(1, (b.main - gapStart) / 2)
                let ca = a.crossCenter, cb = b.crossCenter
                let points = [(exit, ca), (mid, ca), (mid, cb), (entry, cb)].map { xy($0.0, $0.1) }
                for k in 0..<points.count - 1 { canvas.line(points[k], points[k + 1], dotted: edge.dotted) }
                // A dummy passes straight through its rank.
                if b.node == nil {
                    let through = [xy(entry, cb), xy(b.main + b.mainSize, cb)]
                    canvas.line(through[0], through[1], dotted: edge.dotted)
                }
                if a.node == nil {
                    canvas.addBits(points[0].0, points[0].1, vertical ? Canvas.up : Canvas.left)
                }
                if segment.first, a.node != nil, !(isReversed && edge.arrow) {
                    // The link leaves the box through its border: ├ or ┬.
                    let (bx, by) = xy(exit - 1, ca)
                    canvas.set(bx, by, vertical ? "┬" : "├")
                    canvas.addBits(points[0].0, points[0].1, vertical ? Canvas.up : Canvas.left)
                }
                if segment.last, b.node != nil {
                    canvas.addBits(points[3].0, points[3].1, vertical ? Canvas.down : Canvas.right)
                    if edge.arrow, !isReversed { heads.append((points[3].0, points[3].1, vertical ? "▼" : "►")) }
                    if let label = edge.label {
                        if vertical {
                            labels.append((points[3].0 + 2, points[3].1 - 1, label))
                        } else {
                            labels.append((mid + 2, cb, label))  // " label " from mid + 1
                        }
                    }
                }
                if segment.first, isReversed, edge.arrow {
                    heads.append((points[0].0, points[0].1, vertical ? "▲" : "◄"))
                }
            }
            for (x, y, c) in heads { canvas.set(x, y, c) }
            for (x, y, text) in labels {
                let padded = vertical ? text : " \(text) "
                for (j, c) in padded.enumerated() where canvas.inside(x + j - (vertical ? 0 : 1), y) {
                    canvas.set(x + j - (vertical ? 0 : 1), y, c)
                }
            }
            return canvas.text()
        }
    }
}
