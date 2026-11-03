import Foundation

/// A free-form box-and-arrow drawing kept as plain box-drawing text inside a
/// ``` code block: the text is the drawing (what gets pasted elsewhere). The
/// editor keeps a `Diagram` while you edit and re-renders on each change;
/// `parse` reads ClipB's own art back. A block counts as a drawing only when
/// it round-trips exactly, so other ASCII in code blocks is never touched.
/// Pure (Foundation only), tested.
///
/// Rendering is canonical: it depends only on box geometry/text and on the
/// set of arrows, never on array order or ids, which is what lets `parse`
/// rebuild a model that renders to the very same text.
enum AsciiDiagram {
    struct Cell: Hashable { var x: Int; var y: Int }

    struct Rect: Equatable {
        var x: Int, y: Int, width: Int, height: Int
        func contains(_ c: Cell) -> Bool { c.x >= x && c.x < x + width && c.y >= y && c.y < y + height }
    }

    struct Box: Equatable {
        /// Stable in-memory id, not rendered.
        var id: Int
        /// Top-left border cell, >= 0.
        var x: Int, y: Int
        /// Including the border.
        var width: Int, height: Int
        /// Lines; may be [""].
        var text: [String]
        var rect: Rect { Rect(x: x, y: y, width: width, height: height) }
    }

    /// `from`/`to` are Box ids.
    struct Arrow: Equatable { var id: Int; var from: Int; var to: Int; var label: [String] }

    struct Diagram: Equatable { var boxes: [Box] = []; var arrows: [Arrow] = [] }

    struct Rendered {
        /// Lines joined by "\n", trailing spaces trimmed, no trailing empty lines.
        var text: String
        /// Arrow id -> every cell of its line, arrowhead included, from the source.
        var paths: [Int: [Cell]]
        /// Arrow id -> where its label was drawn.
        var labels: [Int: Rect]
        /// Arrows that found no route (not drawn).
        var unrouted: Set<Int>
    }

    static let minWidth = 7, minHeight = 3

    static func fitted(_ box: Box) -> Box {
        var b = box
        let longest = box.text.map(\.count).max() ?? 0
        b.width = max(box.width, minWidth, longest + 4)
        b.height = max(box.height, minHeight, box.text.count + 2)
        return b
    }

    /// A label as laid out: lines trimmed, empty lines dropped.
    static func normalizedLabel(_ label: [String]) -> [String] {
        label.flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Geometry helpers

    fileprivate enum Dir: Int, CaseIterable {
        case right = 0, down, left, up
        var dx: Int { [1, 0, -1, 0][rawValue] }
        var dy: Int { [0, 1, 0, -1][rawValue] }
        var opposite: Dir { Dir(rawValue: (rawValue + 2) % 4)! }
        var clockwise: Dir { Dir(rawValue: (rawValue + 1) % 4)! }
        var counterClockwise: Dir { Dir(rawValue: (rawValue + 3) % 4)! }
        var bit: UInt8 { 1 << UInt8(rawValue) }
        var horizontal: Bool { rawValue % 2 == 0 }
        var head: Character { ["▶", "▼", "◀", "▲"][rawValue] }
        /// The border glyph where a line leaves a box through the side facing this way.
        var exit: Character { ["├", "┬", "┤", "┴"][rawValue] }
        init?(bit: UInt8) {
            guard let d = Dir.allCases.first(where: { $0.bit == bit }) else { return nil }
            self = d
        }
        init?(head: Character) {
            guard let d = Dir.allCases.first(where: { $0.head == head }) else { return nil }
            self = d
        }
    }

    // Connection bits: right 1, down 2, left 4, up 8.
    fileprivate static func lineGlyph(_ bits: UInt8) -> Character {
        switch bits {
        case 5: return "─"
        case 10: return "│"
        case 15: return "┼"
        case 3: return "╭"
        case 6: return "╮"
        case 9: return "╰"
        case 12: return "╯"
        default: return "?"
        }
    }

    fileprivate static func lineBits(_ c: Character) -> UInt8? {
        switch c {
        case "─": return 5
        case "│": return 10
        case "┼": return 15
        case "╭": return 3
        case "╮": return 6
        case "╰": return 9
        case "╯": return 12
        default: return nil
        }
    }

    /// Chebyshev distance from a rect to a cell (0 inside).
    fileprivate static func distance(_ r: Rect, _ c: Cell) -> Int {
        let dx = max(0, r.x - c.x, c.x - (r.x + r.width - 1))
        let dy = max(0, r.y - c.y, c.y - (r.y + r.height - 1))
        return max(dx, dy)
    }

    /// Which way an arrow leaves `a` toward `b`; it enters `b` moving the same way.
    fileprivate static func direction(_ a: Box, _ b: Box) -> Dir {
        let hSep = b.x >= a.x + a.width + 1 || a.x >= b.x + b.width + 1
        let vSep = b.y >= a.y + a.height + 1 || a.y >= b.y + b.height + 1
        let dx2 = (2 * b.x + b.width) - (2 * a.x + a.width)
        let dy2 = (2 * b.y + b.height) - (2 * a.y + a.height)
        // Cells are about twice as tall as wide.
        let horizontal = hSep != vSep ? hSep : abs(dx2) >= 2 * abs(dy2)
        if horizontal { return dx2 >= 0 ? .right : .left }
        return dy2 >= 0 ? .down : .up
    }

    /// The other axis toward `b`.
    fileprivate static func alternative(_ a: Box, _ b: Box, _ d: Dir) -> Dir {
        if d.horizontal {
            if b.y >= a.y + a.height + 1 { return .down }
            if a.y >= b.y + b.height + 1 { return .up }
            return 2 * b.y + b.height >= 2 * a.y + a.height ? .down : .up
        }
        if b.x >= a.x + a.width + 1 { return .right }
        if a.x >= b.x + b.width + 1 { return .left }
        return 2 * b.x + b.width >= 2 * a.x + a.width ? .right : .left
    }

    /// Boxes in (y, x) order, sizes clamped so a border can be drawn.
    fileprivate static func canonicalBoxes(_ boxes: [Box]) -> [Box] {
        boxes.map { b -> Box in
            var b = b
            b.width = max(2, b.width)
            b.height = max(2, b.height)
            return b
        }.sorted {
            ($0.y, $0.x, $0.width, $0.height, $0.text.joined(separator: "\n"), $0.id)
                < ($1.y, $1.x, $1.width, $1.height, $1.text.joined(separator: "\n"), $1.id)
        }
    }

    // MARK: - Render

    fileprivate struct Item {
        var id: Int
        var from: Int
        var to: Int
        var label: [String]
    }

    static func render(_ d: Diagram) -> Rendered {
        let boxes = canonicalBoxes(d.boxes)
        var index: [Int: Int] = [:]
        for (i, b) in boxes.enumerated() where index[b.id] == nil { index[b.id] = i }
        var unrouted = Set<Int>()
        var items: [Item] = []
        for a in d.arrows {
            guard let f = index[a.from], let t = index[a.to], f != t else {
                unrouted.insert(a.id)
                continue
            }
            items.append(Item(id: a.id, from: f, to: t, label: normalizedLabel(a.label)))
        }
        items.sort {
            ($0.from, $0.to, $0.label.joined(separator: "\n"), $0.id) < ($1.from, $1.to, $1.label.joined(separator: "\n"), $1.id)
        }
        // Arrows that fail are dropped and the rest laid out again, so the
        // art equals the art of the diagram without them (parse round-trips).
        while true {
            var planner = Planner(boxes: boxes, items: items)
            let failed = planner.route()
            if failed.isEmpty {
                var rendered = planner.draw()
                rendered.unrouted.formUnion(unrouted)
                return rendered
            }
            // One at a time: a later failure may only be the knock-on of this
            // one. Many at once are dropped together (keeps big edits fast).
            let drop = failed.count > 3 ? failed : [failed.min()!]
            for i in drop { unrouted.insert(items[i].id) }
            items = items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
    }

    fileprivate struct Ends {
        var dir: Dir
        /// (cell outside the border, extra cost); the first is the preferred one.
        var starts: [(Int, Int)]
        var goals: [(Int, Int)]
    }

    /// Ports, routes and drawing for one canonical set of boxes and arrows.
    fileprivate struct Planner {
        let boxes: [Box]
        let items: [Item]
        let width: Int, height: Int
        /// 0 empty, 1 blocked, 2 straight horizontal line, 3 straight vertical line, 5 reserved port cell.
        var kind: [UInt8]
        var bits: [UInt8]
        var reserved: [UInt8]
        var nearBox: [Bool]
        var heads: [Int: Dir] = [:]
        var exits: [Int: Character] = [:]
        /// Per item: where its line may start and end.
        var ends: [Ends?]
        var paths: [[Int]?]
        /// Per item: the cells reserved for it.
        var own: [[Int]]

        init(boxes: [Box], items: [Item]) {
            self.boxes = boxes
            self.items = items
            let maxX = boxes.map { $0.x + $0.width - 1 }.max() ?? 0
            let maxY = boxes.map { $0.y + $0.height - 1 }.max() ?? 0
            width = maxX + 5
            height = maxY + 5
            kind = Array(repeating: 0, count: width * height)
            bits = Array(repeating: 0, count: width * height)
            reserved = Array(repeating: 0, count: width * height)
            nearBox = Array(repeating: false, count: width * height)
            ends = Array(repeating: nil, count: items.count)
            paths = Array(repeating: nil, count: items.count)
            own = Array(repeating: [], count: items.count)
            for b in boxes {
                for y in max(0, b.y)..<min(height, b.y + b.height) {
                    for x in max(0, b.x)..<min(width, b.x + b.width) { kind[y * width + x] = 1 }
                }
            }
            for y in 0..<height {
                for x in 0..<width where kind[y * width + x] == 0 {
                    for d in Dir.allCases {
                        let nx = x + d.dx, ny = y + d.dy
                        if nx >= 0, ny >= 0, nx < width, ny < height, kind[ny * width + nx] == 1 { nearBox[y * width + x] = true }
                    }
                }
            }
            assignPorts()
        }

        func cell(_ x: Int, _ y: Int) -> Int? { x >= 0 && y >= 0 && x < width && y < height ? y * width + x : nil }

        private mutating func assignPorts() {
            struct End { var item: Int; var exit: Bool; var key: Int }
            var sides: [Int: [End]] = [:] // box * 4 + side
            var dirs: [Dir] = []
            var used: [Int: Int] = [:]
            func capacity(_ box: Int, _ side: Dir) -> Int { side.horizontal ? boxes[box].height - 2 : boxes[box].width - 2 }
            func fits(_ box: Int, _ side: Dir) -> Bool { used[box * 4 + side.rawValue, default: 0] < capacity(box, side) }
            for (i, it) in items.enumerated() {
                let a = boxes[it.from], b = boxes[it.to]
                // The geometric side first; when either end of it is full, the other axis.
                var d = AsciiDiagram.direction(a, b)
                if !(fits(it.from, d) && fits(it.to, d.opposite)), case let alt = AsciiDiagram.alternative(a, b, d),
                   fits(it.from, alt) && fits(it.to, alt.opposite) {
                    d = alt
                }
                used[it.from * 4 + d.rawValue, default: 0] += 1
                used[it.to * 4 + d.opposite.rawValue, default: 0] += 1
                dirs.append(d)
                let keyFor = { (other: Box, side: Dir) in side.horizontal ? 2 * other.y + other.height : 2 * other.x + other.width }
                sides[it.from * 4 + d.rawValue, default: []].append(End(item: i, exit: true, key: keyFor(b, d)))
                sides[it.to * 4 + d.opposite.rawValue, default: []].append(End(item: i, exit: false, key: keyFor(a, d.opposite)))
            }
            var exitCell: [Int: [(Int, Int)]] = [:], entryCell: [Int: [(Int, Int)]] = [:]
            for (slot, list) in sides {
                let box = boxes[slot / 4], side = Dir(rawValue: slot % 4)!
                let sorted = list.sorted { ($0.key, $0.item, $0.exit ? 0 : 1) < ($1.key, $1.item, $1.exit ? 0 : 1) }
                let k = side.horizontal ? box.height - 2 : box.width - 2
                let n = min(sorted.count, k)
                func border(_ offset: Int) -> Int? {
                    switch side {
                    case .right: return cell(box.x + box.width - 1, box.y + 1 + offset)
                    case .left: return cell(box.x, box.y + 1 + offset)
                    case .down: return cell(box.x + 1 + offset, box.y + box.height - 1)
                    case .up: return cell(box.x + 1 + offset, box.y)
                    }
                }
                for (j, end) in sorted.enumerated() where j < n {
                    let offset = ((2 * j + 1) * k) / (2 * n)
                    guard let c = border(offset) else { continue }
                    // Alone on its side, a port may slide along it when
                    // that saves the line a bend; the middle is preferred.
                    var options = [(c, 0)]
                    if n == 1 {
                        for o in 0..<k where o != offset {
                            if let other = border(o) { options.append((other, 3 * abs(o - offset))) }
                        }
                    }
                    if end.exit { exitCell[end.item] = options } else { entryCell[end.item] = options }
                }
            }
            for i in items.indices {
                let d = dirs[i]
                guard let exitOptions = exitCell[i], let entryOptions = entryCell[i] else { continue }
                let step = d.dy * width + d.dx
                let starts = exitOptions.compactMap { o -> (Int, Int)? in
                    let x = o.0 % width + d.dx, y = o.0 / width + d.dy
                    guard let c = cell(x, y), kind[c] != 1 else { return nil }
                    return (c, o.1)
                }
                let goals = entryOptions.compactMap { o -> (Int, Int)? in
                    let x = o.0 % width - d.dx, y = o.0 / width - d.dy
                    guard let c = cell(x, y), kind[c] != 1 else { return nil }
                    return (c, o.1)
                }
                // The preferred cells must be usable; the others are extras.
                guard let first = starts.first, first.0 == exitOptions[0].0 + step,
                      let last = goals.first, last.0 == entryOptions[0].0 - step else { continue }
                let s = first.0, g = last.0
                let e = exitOptions[0].0, t = entryOptions[0].0
                let ex = e % width, ey = e / width, tx = t % width, ty = t / width
                ends[i] = Ends(dir: d, starts: starts, goals: goals)
                // The port cells, and the cells straight beyond them, are kept
                // for this arrow: nobody else may block its way in or out.
                var cells = [s]
                if g != s { cells.append(g) }
                for (x, y) in [(ex + 2 * d.dx, ey + 2 * d.dy), (tx - 2 * d.dx, ty - 2 * d.dy)] {
                    if let c = cell(x, y), kind[c] == 0 || kind[c] == 5, !cells.contains(c) { cells.append(c) }
                }
                for c in cells {
                    reserved[c] += 1
                    kind[c] = 5
                }
                own[i] = cells
            }
        }

        private mutating func release(_ i: Int) {
            for c in own[i] where kind[c] == 5 {
                reserved[c] -= 1
                if reserved[c] == 0 { kind[c] = 0 }
            }
        }

        /// Routes every arrow in order; returns the indices that failed.
        mutating func route() -> Set<Int> {
            var failed = Set<Int>()
            var dist = [Int32](repeating: .max, count: width * height * 4)
            var prev = [Int32](repeating: -1, count: width * height * 4)
            for i in items.indices {
                guard let e = ends[i], let path = search(e, own: own[i], dist: &dist, prev: &prev) else {
                    release(i)
                    failed.insert(i)
                    continue
                }
                commit(path, e)
                release(i)
                paths[i] = path
            }
            return failed
        }

        private func usable(_ c: Int, _ own: [Int]) -> Bool { kind[c] == 0 || kind[c] == 5 && own.contains(c) }

        private func search(_ e: Ends, own: [Int], dist: inout [Int32], prev: inout [Int32]) -> [Int]? {
            let starts = e.starts.filter { usable($0.0, own) }
            let goals = e.goals.filter { usable($0.0, own) }
            guard !starts.isEmpty, !goals.isEmpty else { return nil }
            // Boxes one cell apart: the head sits right after the exit.
            var direct: (Int, Int)?
            for s in starts {
                if let g = goals.first(where: { $0.0 == s.0 }), direct == nil || s.1 + g.1 < direct!.1 { direct = (s.0, s.1 + g.1) }
            }
            if let direct { return [direct.0] }
            dist.withUnsafeMutableBufferPointer { $0.update(repeating: .max) }
            let gxs = goals.map { $0.0 % width }, gys = goals.map { $0.0 / width }
            let gx0 = gxs.min()!, gx1 = gxs.max()!, gy0 = gys.min()!, gy1 = gys.max()!
            func h(_ c: Int) -> Int {
                let x = c % width, y = c / width
                return 10 * (max(0, gx0 - x, x - gx1) + max(0, gy0 - y, y - gy1))
            }
            var goalExtra: [Int: Int] = [:]
            for g in goals { goalExtra[g.0] = g.1 }
            var heap = Heap()
            for s in starts {
                let st = s.0 * 4 + e.dir.rawValue
                dist[st] = Int32(s.1)
                prev[st] = -1
                heap.push((s.1 + h(s.0)) << 32 | st)
            }
            var target = -1
            while let top = heap.pop() {
                let state = top & 0xFFFF_FFFF
                let c = state / 4, d = Dir(rawValue: state % 4)!
                let g = Int(dist[state])
                if (top >> 32) > g + h(c) { continue }
                if goalExtra[c] != nil {
                    if d == e.dir, prev[state] >= 0 { target = state; break }
                    continue
                }
                let cx = c % width, cy = c / width
                for nd in [d, d.clockwise, d.counterClockwise] {
                    let bend = nd != d
                    if bend, !usable(c, own) { continue }
                    guard let n = cell(cx + nd.dx, cy + nd.dy) else { continue }
                    var cost = bend ? 50 : 10
                    if let extra = goalExtra[n] {
                        guard nd == e.dir else { continue }
                        cost += extra
                    } else {
                        switch kind[n] {
                        case 0:
                            if nearBox[n] { cost += 3 }
                            // Lines keep a cell apart where they can.
                            let nx = n % width, ny = n / width
                            if nx > 0, bits[n - 1] != 0 { cost += 2 }
                            if nx < width - 1, bits[n + 1] != 0 { cost += 2 }
                            if ny > 0, bits[n - width] != 0 { cost += 2 }
                            if ny < height - 1, bits[n + width] != 0 { cost += 2 }
                        case 5 where own.contains(n): break
                        case 2 where !nd.horizontal, 3 where nd.horizontal: cost += 30
                        default: continue
                        }
                    }
                    let ns = n * 4 + nd.rawValue
                    let ng = g + cost
                    if ng < Int(dist[ns]) {
                        dist[ns] = Int32(ng)
                        prev[ns] = Int32(state)
                        heap.push((ng + h(n)) << 32 | ns)
                    }
                }
            }
            guard target >= 0 else { return nil }
            var path: [Int] = []
            var s = target
            while s >= 0 {
                path.append(s / 4)
                s = Int(prev[s])
            }
            path.reverse()
            guard Set(path).count == path.count else { return nil }
            return path
        }

        private mutating func commit(_ path: [Int], _ e: Ends) {
            exits[path[0] - (e.dir.dy * width + e.dir.dx)] = e.dir.exit
            var into = e.dir
            for (k, c) in path.enumerated() {
                if k == path.count - 1 {
                    heads[c] = e.dir
                    kind[c] = 1
                    break
                }
                let next = path[k + 1]
                let out: Dir = next == c + 1 ? .right : next == c - 1 ? .left : next > c ? .down : .up
                bits[c] |= into.opposite.bit | out.bit
                kind[c] = bits[c] == 5 ? 2 : bits[c] == 10 ? 3 : 1
                into = out
            }
        }

        // MARK: Drawing

        func draw() -> Rendered {
            var canvas = Canvas(width: width, height: height)
            for b in boxes {
                for x in b.x..<b.x + b.width {
                    canvas.set(x, b.y, "─")
                    canvas.set(x, b.y + b.height - 1, "─")
                }
                for y in b.y..<b.y + b.height {
                    canvas.set(b.x, y, "│")
                    canvas.set(b.x + b.width - 1, y, "│")
                }
                for y in b.y + 1..<b.y + b.height - 1 {
                    for x in b.x + 1..<b.x + b.width - 1 { canvas.set(x, y, " ") }
                }
                canvas.set(b.x, b.y, "┌")
                canvas.set(b.x + b.width - 1, b.y, "┐")
                canvas.set(b.x, b.y + b.height - 1, "└")
                canvas.set(b.x + b.width - 1, b.y + b.height - 1, "┘")
                let room = b.width - 4
                for (k, line) in b.text.prefix(max(0, b.height - 2)).enumerated() where room > 0 {
                    for (j, ch) in line.prefix(room).enumerated() { canvas.set(b.x + 2 + j, b.y + 1 + k, ch) }
                }
            }
            for (c, g) in exits { canvas.set(c % width, c / width, g) }
            for c in bits.indices where bits[c] != 0 { canvas.set(c % width, c / width, AsciiDiagram.lineGlyph(bits[c])) }
            for (c, d) in heads { canvas.set(c % width, c / width, d.head) }

            var result = Rendered(text: "", paths: [:], labels: [:], unrouted: [])
            var owner = [Int](repeating: -1, count: width * height)
            var cellPaths: [[Cell]] = Array(repeating: [], count: items.count)
            for (i, p) in paths.enumerated() {
                guard let p else { continue }
                cellPaths[i] = p.map { Cell(x: $0 % width, y: $0 / width) }
                result.paths[items[i].id] = cellPaths[i]
                for c in p { owner[c] = owner[c] == -1 ? i : -2 }
            }
            var labelMask = Set<Cell>()
            for (i, item) in items.enumerated() where !item.label.isEmpty {
                guard let path = paths[i], !path.isEmpty else { continue }
                let w = item.label.map(\.count).max() ?? 0, h = item.label.count
                func ownerAt(_ x: Int, _ y: Int) -> Int { cell(x, y).map { owner[$0] } ?? -1 }
                /// `strict`: a free cell all around (its own line may touch it).
                /// Otherwise only other labels need room (parse would join them).
                func valid(_ bx: Int, _ by: Int, strict: Bool = true) -> Bool {
                    guard bx >= 0, by >= 0 else { return false }
                    for y in by - 1...by + h {
                        for x in bx - 1...bx + w where !canvas.isFree(x, y) {
                            if y >= by && y < by + h && x >= bx && x < bx + w { return false }
                            if strict ? ownerAt(x, y) != i : labelMask.contains(Cell(x: x, y: y)) { return false }
                        }
                    }
                    for y in by..<by + h where labelMask.contains(Cell(x: bx - 2, y: y)) || labelMask.contains(Cell(x: bx + w + 1, y: y)) {
                        return false
                    }
                    // Parse gives a label to the nearest line: that must be this one.
                    let rect = Rect(x: bx, y: by, width: w, height: h)
                    let near = cellPaths[i].map { AsciiDiagram.distance(rect, $0) }.min() ?? .max
                    guard near < 64 else { return false }
                    for y in by - near...by + h - 1 + near {
                        for x in bx - near...bx + w - 1 + near {
                            let o = ownerAt(x, y)
                            if o != -1 && o != i { return false }
                        }
                    }
                    return true
                }
                let mid = path.count / 2
                var order = [mid]
                var step = 1
                while order.count < path.count {
                    if mid + step < path.count { order.append(mid + step) }
                    if mid - step >= 0 { order.append(mid - step) }
                    step += 1
                }
                var into: [Dir] = [ends[i]!.dir]
                for k in 1..<max(1, path.count) {
                    let a = path[k - 1], b = path[k]
                    into.append(b == a + 1 ? .right : b == a - 1 ? .left : b > a ? .down : .up)
                }
                func candidates(_ k: Int) -> [(Int, Int)] {
                    let c = path[k], cx = c % width, cy = c / width
                    let above = (cx - (w - 1) / 2, cy - h), below = (cx - (w - 1) / 2, cy + 1)
                    let right = (cx + 2, cy - (h - 1) / 2), left = (cx - 1 - w, cy - (h - 1) / 2)
                    let out = k + 1 < path.count ? into[k + 1] : into[k]
                    if into[k] != out { return [above, below, right, left] }
                    return into[k].horizontal ? [above, below] : [right, left]
                }
                var spot: (Int, Int)?
                for k in order {
                    if let c = candidates(k).first(where: { valid($0.0, $0.1) }) { spot = c; break }
                }
                if spot == nil {
                    let anchor = candidates(mid)[0]
                    search: for r in 1...12 {
                        for dy in -r...r {
                            for dx in -r...r where max(abs(dx), abs(dy)) == r && valid(anchor.0 + dx, anchor.1 + dy) {
                                spot = (anchor.0 + dx, anchor.1 + dy)
                                break search
                            }
                        }
                    }
                }
                if spot == nil {
                    let anchor = candidates(mid)[0]
                    search: for r in 0...30 {
                        for dy in -r...r {
                            for dx in -r...r where max(abs(dx), abs(dy)) == r && valid(anchor.0 + dx, anchor.1 + dy, strict: false) {
                                spot = (anchor.0 + dx, anchor.1 + dy)
                                break search
                            }
                        }
                    }
                }
                if spot == nil {
                    // Right of everything, stacked below earlier fallbacks.
                    let bx = canvas.maxWidth + 2
                    var by = max(0, path[mid] / width - (h - 1) / 2)
                    while (by - 1...by + h).contains(where: { y in (bx - 2...bx + w + 1).contains { !canvas.isFree($0, y) } }) { by += 1 }
                    spot = (bx, by)
                }
                let (bx, by) = spot!
                for (row, line) in item.label.enumerated() {
                    for (j, ch) in line.enumerated() {
                        canvas.set(bx + j, by + row, ch)
                        labelMask.insert(Cell(x: bx + j, y: by + row))
                    }
                }
                result.labels[item.id] = Rect(x: bx, y: by, width: w, height: h)
            }
            result.text = canvas.text()
            return result
        }
    }

    fileprivate struct Canvas {
        var rows: [[Character]]
        init(width: Int, height: Int) { rows = Array(repeating: Array(repeating: " ", count: width), count: height) }
        var maxWidth: Int { rows.map { row in (row.lastIndex { $0 != " " } ?? -1) + 1 }.max() ?? 0 }
        func isFree(_ x: Int, _ y: Int) -> Bool { y < 0 || y >= rows.count || x < 0 || x >= rows[y].count || rows[y][x] == " " }
        mutating func set(_ x: Int, _ y: Int, _ c: Character) {
            guard x >= 0, y >= 0 else { return }
            while rows.count <= y { rows.append([]) }
            if rows[y].count <= x { rows[y].append(contentsOf: Array(repeating: " ", count: x - rows[y].count + 1)) }
            rows[y][x] = c
        }
        func text() -> String {
            var lines = rows.map { row -> String in
                var s = String(row)
                while s.last == " " { s.removeLast() }
                return s
            }
            while lines.last?.isEmpty == true { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
    }

    /// Binary min-heap of packed (priority << 32 | state) keys.
    fileprivate struct Heap {
        var items: [Int] = []
        mutating func push(_ v: Int) {
            items.append(v)
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if items[p] <= items[i] { break }
                items.swapAt(p, i)
                i = p
            }
        }
        mutating func pop() -> Int? {
            guard let first = items.first else { return nil }
            let last = items.removeLast()
            if items.isEmpty { return first }
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l] < items[m] { m = l }
                if r < items.count && items[r] < items[m] { m = r }
                if m == i { break }
                items.swapAt(m, i)
                i = m
            }
            return first
        }
    }

    // MARK: - Parse

    static func parse(_ text: String) -> Diagram? {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var s = line
            while s.last == " " { s.removeLast() }
            return s
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        let normalized = lines.joined(separator: "\n")
        let grid = lines.map { Array($0) }
        let height = grid.count, width = grid.map(\.count).max() ?? 0
        guard width > 0 else { return nil }
        func at(_ x: Int, _ y: Int) -> Character { y >= 0 && y < height && x >= 0 && x < grid[y].count ? grid[y][x] : " " }
        var boxAt = [Int](repeating: -1, count: width * height)
        func boxOf(_ x: Int, _ y: Int) -> Int { x >= 0 && y >= 0 && x < width && y < height ? boxAt[y * width + x] : -1 }

        var boxes: [Box] = []
        for y in 0..<height {
            for x in 0..<grid[y].count where grid[y][x] == "┌" && boxAt[y * width + x] < 0 {
                var x2 = x + 1
                while at(x2, y) == "─" || at(x2, y) == "┴" { x2 += 1 }
                guard at(x2, y) == "┐" else { return nil }
                var y2 = y + 1
                while (at(x, y2) == "│" || at(x, y2) == "┤") && (at(x2, y2) == "│" || at(x2, y2) == "├") { y2 += 1 }
                guard at(x, y2) == "└", at(x2, y2) == "┘" else { return nil }
                for xx in x + 1..<x2 where at(xx, y2) != "─" && at(xx, y2) != "┬" { return nil }
                let id = boxes.count
                for yy in y...y2 {
                    for xx in x...x2 {
                        guard boxAt[yy * width + xx] < 0 else { return nil }
                        boxAt[yy * width + xx] = id
                    }
                }
                var text: [String] = []
                for yy in y + 1..<y2 {
                    var s = x + 2 < x2 - 1 ? String(grid[yy][min(x + 2, grid[yy].count)..<min(x2 - 1, grid[yy].count)]) : ""
                    while s.last == " " { s.removeLast() }
                    text.append(s)
                }
                while text.last?.isEmpty == true { text.removeLast() }
                if text.isEmpty { text = [""] }
                boxes.append(Box(id: id, x: x, y: y, width: x2 - x + 1, height: y2 - y + 1, text: text))
            }
        }
        guard !boxes.isEmpty else { return nil }

        // Arrows: trace from every exit on a border.
        var onLine = [Bool](repeating: false, count: width * height)
        var traced: [(from: Int, to: Int, path: [Cell])] = []
        for b in boxes {
            var exits: [(Int, Int, Dir)] = []
            for x in b.x + 1..<b.x + b.width - 1 {
                if at(x, b.y) == "┴" { exits.append((x, b.y, .up)) }
                if at(x, b.y + b.height - 1) == "┬" { exits.append((x, b.y + b.height - 1, .down)) }
            }
            for y in b.y + 1..<b.y + b.height - 1 {
                if at(b.x, y) == "┤" { exits.append((b.x, y, .left)) }
                if at(b.x + b.width - 1, y) == "├" { exits.append((b.x + b.width - 1, y, .right)) }
            }
            for (ex, ey, d) in exits {
                var x = ex + d.dx, y = ey + d.dy, dir = d
                var path: [Cell] = []
                var target = -1
                while true {
                    guard path.count <= width * height * 2, x >= 0, y >= 0, x < width, y < height, boxAt[y * width + x] < 0 else { return nil }
                    let ch = at(x, y)
                    path.append(Cell(x: x, y: y))
                    if let hd = Dir(head: ch) {
                        guard hd == dir else { return nil }
                        target = boxOf(x + dir.dx, y + dir.dy)
                        guard target >= 0, target != b.id else { return nil }
                        onLine[y * width + x] = true
                        break
                    }
                    guard let bits = lineBits(ch), bits & dir.opposite.bit != 0 else { return nil }
                    onLine[y * width + x] = true
                    if bits != 15 {
                        guard let out = Dir(bit: bits & ~dir.opposite.bit) else { return nil }
                        dir = out
                    }
                    x += dir.dx
                    y += dir.dy
                }
                traced.append((b.id, target, path))
            }
        }

        // Labels: what is left outside boxes and lines.
        func isLabel(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < grid[y].count else { return false }
            return grid[y][x] != " " && boxAt[y * width + x] < 0 && !onLine[y * width + x]
        }
        var segments: [(y: Int, x0: Int, x1: Int)] = []
        for y in 0..<height {
            var x = 0
            while x < grid[y].count {
                guard isLabel(x, y) else { x += 1; continue }
                let x0 = x
                var x1 = x
                while true {
                    if isLabel(x1 + 1, y) { x1 += 1 } else if at(x1 + 1, y) == " " && isLabel(x1 + 2, y) { x1 += 2 } else { break }
                }
                segments.append((y, x0, x1))
                x = x1 + 1
            }
        }
        var parent = Array(segments.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in segments.indices {
            for j in segments.indices where segments[j].y == segments[i].y + 1 && segments[j].x0 <= segments[i].x1 && segments[i].x0 <= segments[j].x1 {
                parent[root(j)] = root(i)
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in segments.indices { groups[root(i), default: []].append(i) }
        var labels: [Int: [String]] = [:]
        for (_, members) in groups.sorted(by: { $0.key < $1.key }) {
            let segs = members.map { segments[$0] }.sorted { $0.y < $1.y }
            guard Set(segs.map(\.y)).count == segs.count else { return nil }
            let x0 = segs.map(\.x0).min()!, x1 = segs.map(\.x1).max()!
            let rect = Rect(x: x0, y: segs[0].y, width: x1 - x0 + 1, height: segs.count)
            let lines = segs.map { String(grid[$0.y][$0.x0...$0.x1]).trimmingCharacters(in: .whitespaces) }
            let dists = traced.map { t in t.path.map { distance(rect, $0) }.min() ?? .max }
            guard let best = dists.min() else { return nil }
            let winners = dists.indices.filter { dists[$0] == best }
            guard winners.count == 1, labels[winners[0]] == nil else { return nil }
            labels[winners[0]] = lines
        }

        var arrows = traced.enumerated().map { Arrow(id: 0, from: $0.element.from, to: $0.element.to, label: labels[$0.offset] ?? []) }
        arrows.sort { ($0.from, $0.to, $0.label.joined(separator: "\n")) < ($1.from, $1.to, $1.label.joined(separator: "\n")) }
        for i in arrows.indices { arrows[i].id = i }
        let diagram = Diagram(boxes: boxes, arrows: arrows)
        guard render(diagram).text == normalized else { return nil }
        return diagram
    }

    // MARK: - Mermaid

    static func fromMermaid(_ source: String) -> Diagram? {
        guard let graph = MermaidASCII.parse(source), let drawing = MermaidASCII.drawing(source) else { return nil }
        let vertical = graph.vertical
        let labelOf = { (node: String) in graph.nodes.first { $0.id == node }?.label ?? [node] }
        let edgeLabels = graph.edges.map { e -> [String] in
            guard let l = e.label else { return [] }
            return normalizedLabel(l.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
                .components(separatedBy: "\n"))
        }
        let longest = edgeLabels.flatMap { $0 }.map(\.count).max() ?? 0
        let tallest = edgeLabels.map(\.count).max() ?? 0
        // Room along the flow for the arrow and its label.
        let gap = vertical ? max(4, tallest + 2) : max(6, longest + 4)
        let crossGap = vertical ? 4 : 2
        let factor = vertical ? 1.34 : 1.5

        struct Placed { var id: String; var rank: Int; var cross: Int; var box: Box }
        var placed = drawing.boxes.map { mb in
            Placed(id: mb.id, rank: mb.rank, cross: vertical ? mb.x : mb.y,
                   box: fitted(Box(id: 0, x: 0, y: 0, width: mb.width, height: mb.height, text: labelOf(mb.id))))
        }
        var main = 0
        for rank in Set(placed.map(\.rank)).sorted() {
            let members = placed.indices.filter { placed[$0].rank == rank }.sorted { placed[$0].cross < placed[$1].cross }
            let size = members.map { vertical ? placed[$0].box.height : placed[$0].box.width }.max() ?? 0
            var end = -crossGap
            for i in members {
                let cross = max(end + crossGap, Int((Double(placed[i].cross) * factor).rounded()))
                if vertical {
                    placed[i].box.x = cross
                    placed[i].box.y = main
                } else {
                    placed[i].box.x = main
                    placed[i].box.y = cross
                }
                end = cross + (vertical ? placed[i].box.width : placed[i].box.height)
            }
            main += size + gap
        }
        placed.sort { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }
        var index: [String: Int] = [:]
        for i in placed.indices {
            placed[i].box.id = i
            index[placed[i].id] = i
        }
        var arrows: [Arrow] = []
        for (k, e) in graph.edges.enumerated() {
            guard let f = index[e.from], let t = index[e.to], f != t else { continue }
            arrows.append(Arrow(id: arrows.count, from: f, to: t, label: edgeLabels[k]))
        }
        return Diagram(boxes: placed.map(\.box), arrows: arrows)
    }

    /// Mermaid ids: A…Z, then AA, AB, …
    static func mermaidID(_ i: Int) -> String {
        var n = i + 1
        var s = ""
        while n > 0 {
            n -= 1
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n /= 26
        }
        return s
    }

    static func mermaid(_ d: Diagram) -> String {
        let boxes = canonicalBoxes(d.boxes)
        var index: [Int: Int] = [:]
        for (i, b) in boxes.enumerated() where index[b.id] == nil { index[b.id] = i }
        var arrows: [(Int, Int, [String])] = []
        var horizontal = 0, verticalCount = 0
        for a in d.arrows {
            guard let f = index[a.from], let t = index[a.to], f != t else { continue }
            arrows.append((f, t, normalizedLabel(a.label)))
            if direction(boxes[f], boxes[t]).horizontal { horizontal += 1 } else { verticalCount += 1 }
        }
        arrows.sort { ($0.0, $0.1, $0.2.joined(separator: "\n")) < ($1.0, $1.1, $1.2.joined(separator: "\n")) }
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "#quot;") }
        var lines = [horizontal > verticalCount ? "graph LR" : "graph TD"]
        for (i, b) in boxes.enumerated() {
            let text = b.text.map(escape).joined(separator: "<br>")
            lines.append("  \(mermaidID(i))[\"\(text.isEmpty ? " " : text)\"]")
        }
        for (f, t, label) in arrows {
            if label.isEmpty {
                lines.append("  \(mermaidID(f)) --> \(mermaidID(t))")
            } else {
                let text = label.map { escape($0).replacingOccurrences(of: "|", with: "#124;") }.joined(separator: "<br>")
                lines.append("  \(mermaidID(f)) -->|\"\(text)\"| \(mermaidID(t))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
