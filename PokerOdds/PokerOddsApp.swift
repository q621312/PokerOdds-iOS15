import SwiftUI

// MARK: - App 入口

@main
struct PokerOddsApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - 牌的表示（0...51：rank * 4 + suit）

enum Card {
    static let rankSymbols = ["2","3","4","5","6","7","8","9","10","J","Q","K","A"]
    static let suitSymbols = ["♣","♦","♥","♠"]

    static func rank(_ c: Int) -> Int { c >> 2 }
    static func suit(_ c: Int) -> Int { c & 3 }
    static func make(rank: Int, suit: Int) -> Int { rank * 4 + suit }
    static func isRed(_ c: Int) -> Bool { let s = suit(c); return s == 1 || s == 2 }
    static func text(_ c: Int) -> String { rankSymbols[rank(c)] + suitSymbols[suit(c)] }
}

// MARK: - 7 张牌评估器（分数越大牌越大）

final class HandEvaluator {
    private let rc = UnsafeMutablePointer<Int>.allocate(capacity: 13) // 每个点数的张数
    private let sc = UnsafeMutablePointer<Int>.allocate(capacity: 4)  // 每个花色的张数
    private let sm = UnsafeMutablePointer<Int>.allocate(capacity: 4)  // 每个花色的点数位掩码

    init() {
        rc.initialize(repeating: 0, count: 13)
        sc.initialize(repeating: 0, count: 4)
        sm.initialize(repeating: 0, count: 4)
    }

    deinit {
        rc.deinitialize(count: 13); sc.deinitialize(count: 4); sm.deinitialize(count: 4)
        rc.deallocate(); sc.deallocate(); sm.deallocate()
    }

    /// 返回顺子的最大牌点数(0=2 ... 12=A)，没有顺子返回 -1（支持 A-2-3-4-5）
    private static func straightHigh(_ mask: Int) -> Int {
        let m14 = (mask << 1) | ((mask >> 12) & 1) // bit0 = A(低位用)
        var h = 13
        while h >= 4 {
            if (m14 >> (h - 4)) & 0x1F == 0x1F { return h - 1 }
            h -= 1
        }
        return -1
    }

    /// 编码：类别<<20 | 5个4位的比较值
    private static func pack(_ cat: Int, prefix: Int, prefixCount: Int, mask: Int, take n: Int) -> Int {
        var v = prefix, taken = 0, r = 12
        while taken < n && r >= 0 {
            if (mask >> r) & 1 == 1 { v = (v << 4) | r; taken += 1 }
            r -= 1
        }
        v <<= (5 - prefixCount - n) * 4
        return (cat << 20) | v
    }

    func score(_ c: UnsafePointer<Int>) -> Int {
        rc.update(repeating: 0, count: 13)
        sc.update(repeating: 0, count: 4)
        sm.update(repeating: 0, count: 4)

        var rankMask = 0
        for k in 0..<7 {
            let r = c[k] >> 2, s = c[k] & 3
            rc[r] += 1; sc[s] += 1
            sm[s] |= 1 << r
            rankMask |= 1 << r
        }

        // 同花 / 同花顺
        var flushMask = 0
        for s in 0..<4 where sc[s] >= 5 { flushMask = sm[s] }
        if flushMask != 0 {
            let sh = Self.straightHigh(flushMask)
            if sh >= 0 { return Self.pack(8, prefix: sh, prefixCount: 1, mask: 0, take: 0) }
        }

        // 统计四条 / 三条 / 对子
        var quad = -1, t1 = -1, t2 = -1, p1 = -1, p2 = -1
        var r = 12
        while r >= 0 {
            switch rc[r] {
            case 4: quad = r
            case 3: if t1 < 0 { t1 = r } else { t2 = r }
            case 2: if p1 < 0 { p1 = r } else if p2 < 0 { p2 = r }
            default: break
            }
            r -= 1
        }

        if quad >= 0 {
            return Self.pack(7, prefix: quad, prefixCount: 1, mask: rankMask & ~(1 << quad), take: 1)
        }
        if t1 >= 0 && (t2 >= 0 || p1 >= 0) {
            let pair = max(t2, p1)
            return Self.pack(6, prefix: (t1 << 4) | pair, prefixCount: 2, mask: 0, take: 0)
        }
        if flushMask != 0 {
            return Self.pack(5, prefix: 0, prefixCount: 0, mask: flushMask, take: 5)
        }
        let sh = Self.straightHigh(rankMask)
        if sh >= 0 { return Self.pack(4, prefix: sh, prefixCount: 1, mask: 0, take: 0) }
        if t1 >= 0 {
            return Self.pack(3, prefix: t1, prefixCount: 1, mask: rankMask & ~(1 << t1), take: 2)
        }
        if p1 >= 0 && p2 >= 0 {
            return Self.pack(2, prefix: (p1 << 4) | p2, prefixCount: 2,
                             mask: rankMask & ~((1 << p1) | (1 << p2)), take: 1)
        }
        if p1 >= 0 {
            return Self.pack(1, prefix: p1, prefixCount: 1, mask: rankMask & ~(1 << p1), take: 3)
        }
        return Self.pack(0, prefix: 0, prefixCount: 0, mask: rankMask, take: 5)
    }
}

// MARK: - 胜率计算（精确枚举）

struct EquityResult {
    let win: Int
    let tie: Int
    let lose: Int
    var total: Int { win + tie + lose }
    var winPct: Double { Double(win) / Double(total) }
    var tiePct: Double { Double(tie) / Double(total) }
    var losePct: Double { Double(lose) / Double(total) }
    /// 平局按一半计入的权益
    var equity: Double { (Double(win) + Double(tie) / 2) / Double(total) }
}

enum EquityCalculator {
    /// hero: 玩家1两张牌；board: 三张翻牌。
    /// 枚举：玩家2任意两张手牌 × 转牌+河牌任意两张，共 C(47,2) × C(45,2) = 1,070,190 种。
    static func compute(hero: [Int], board: [Int]) -> EquityResult {
        let used = Set(hero + board)
        let deck = (0..<52).filter { !used.contains($0) }
        let n = deck.count // 47

        let ev = HandEvaluator()
        let h = UnsafeMutablePointer<Int>.allocate(capacity: 7)
        let o = UnsafeMutablePointer<Int>.allocate(capacity: 7)
        defer { h.deallocate(); o.deallocate() }

        for k in 0..<3 { h[k] = board[k]; o[k] = board[k] }
        h[5] = hero[0]; h[6] = hero[1]

        var win = 0, tie = 0, lose = 0

        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                o[5] = deck[i]; o[6] = deck[j]
                for a in 0..<(n - 1) {
                    if a == i || a == j { continue }
                    for b in (a + 1)..<n {
                        if b == i || b == j { continue }
                        let t = deck[a], r = deck[b]
                        h[3] = t; h[4] = r
                        o[3] = t; o[4] = r
                        let hs = ev.score(h), os = ev.score(o)
                        if hs > os { win += 1 } else if hs == os { tie += 1 } else { lose += 1 }
                    }
                }
            }
        }
        return EquityResult(win: win, tie: tie, lose: lose)
    }
}

// MARK: - ViewModel

enum Slot: Hashable, Identifiable {
    case board(Int), hero(Int)
    var id: Self { self }
}

@MainActor
final class OddsViewModel: ObservableObject {
    @Published var board: [Int?] = Array(repeating: nil, count: 3)
    @Published var hero: [Int?] = Array(repeating: nil, count: 2)
    @Published var result: EquityResult?
    @Published var isCalculating = false
    private var generation = 0

    var usedCards: Set<Int> { Set((board + hero).compactMap { $0 }) }

    func card(for slot: Slot) -> Int? {
        switch slot {
        case .board(let i): return board[i]
        case .hero(let i): return hero[i]
        }
    }

    func set(_ card: Int?, for slot: Slot) {
        switch slot {
        case .board(let i): board[i] = card
        case .hero(let i): hero[i] = card
        }
        recalc()
    }

    func setCards(_ cards: [Int], forBoard: Bool) {
        if forBoard {
            board = Array(cards.prefix(3)).map { Optional($0) } + Array(repeating: nil, count: max(0, 3 - cards.count))
        } else {
            hero = Array(cards.prefix(2)).map { Optional($0) } + Array(repeating: nil, count: max(0, 2 - cards.count))
        }
        recalc()
    }

    func reset() {
        board = Array(repeating: nil, count: 3)
        hero = Array(repeating: nil, count: 2)
        recalc()
    }

    private func recalc() {
        generation += 1
        let gen = generation
        result = nil
        isCalculating = false

        let b = board.compactMap { $0 }
        let h = hero.compactMap { $0 }
        guard b.count == 3, h.count == 2 else { return }

        isCalculating = true
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                EquityCalculator.compute(hero: h, board: b)
            }.value
            guard gen == self.generation else { return }
            self.result = r
            self.isCalculating = false
        }
    }
}

// MARK: - 界面

enum PickerTarget: String, Identifiable {
    case board, hero
    var id: String { rawValue }
    var count: Int { self == .board ? 3 : 2 }
}

struct ContentView: View {
    @StateObject private var vm = OddsViewModel()
    @State private var picking: PickerTarget?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("公共牌（翻牌）") {
                        HStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { i in
                                CardSlotView(card: vm.board[i]) { picking = .board }
                            }
                        }
                    }
                    section("玩家1 手牌（明牌）") {
                        HStack(spacing: 8) {
                            ForEach(0..<2, id: \.self) { i in
                                CardSlotView(card: vm.hero[i]) { picking = .hero }
                            }
                        }
                    }
                    section("玩家2 手牌（暗牌，未知）") {
                        HStack(spacing: 8) {
                            ForEach(0..<2, id: \.self) { _ in CardBackView() }
                        }
                    }
                    ResultView(result: vm.result, isCalculating: vm.isCalculating)
                }
                .padding(12)
            }
            .navigationTitle("德州扑克胜率")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("重置") { vm.reset() }
                }
            }
            .sheet(item: $picking) { target in
                CardPickerView(
                    initial: (target == .board ? vm.board : vm.hero).compactMap { $0 },
                    requiredCount: target.count,
                    disabled: vm.usedCards,
                    title: target == .board ? "选择公共牌" : "选择玩家1手牌"
                ) { cards in
                    vm.setCards(cards, forBoard: target == .board)
                    picking = nil
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            content()
        }
    }
}

struct CardSlotView: View {
    let card: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(card == nil ? Color(.secondarySystemBackground) : Color.white)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(card == nil ? Color.gray.opacity(0.5) : Color.gray.opacity(0.3),
                                  style: StrokeStyle(lineWidth: 1.5, dash: card == nil ? [5] : []))
                if let c = card {
                    Text(Card.text(c))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(Card.isRed(c) ? .red : .black)
                } else {
                    Image(systemName: "plus").foregroundColor(.secondary)
                }
            }
            .frame(width: 52, height: 74)
        }
        .buttonStyle(.plain)
    }
}

struct CardBackView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text("?").font(.title).bold().foregroundColor(.white.opacity(0.8)))
            .frame(width: 70, height: 100)
    }
}

struct ResultView: View {
    let result: EquityResult?
    let isCalculating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCalculating {
                HStack(spacing: 8) {
                    Text("玩家1 胜率").font(.headline)
                    Spacer()
                    ProgressView()
                    Text("正在计算…").font(.footnote).foregroundColor(.secondary)
                }
            } else if let r = result {
                HStack(alignment: .firstTextBaseline) {
                    Text("玩家1 胜率").font(.headline)
                    Spacer()
                    Text(String(format: "%.2f%%", r.winPct * 100))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                        .monospacedDigit()
                }

                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.green).frame(width: geo.size.width * r.winPct)
                        Rectangle().fill(Color.orange).frame(width: geo.size.width * r.tiePct)
                        Rectangle().fill(Color.red).frame(width: geo.size.width * r.losePct)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 9)

                HStack(spacing: 0) {
                    compactMetric(.green, "获胜", r.winPct)
                    Spacer(minLength: 6)
                    compactMetric(.orange, "平局", r.tiePct)
                    Spacer(minLength: 6)
                    compactMetric(.red, "落败", r.losePct)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("权益（平局算一半）").font(.caption).foregroundColor(.secondary)
                        Text(String(format: "%.2f%%", r.equity * 100))
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("枚举情况").font(.caption).foregroundColor(.secondary)
                        Text(r.total.formatted())
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
            } else {
                Text("请选满 3 张公共牌和玩家1的 2 张手牌")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func compactMetric(_ color: Color, _ title: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(String(format: "%.2f%%", value * 100))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
}

struct CardPickerView: View {
    let initial: [Int]
    let requiredCount: Int
    let disabled: Set<Int>
    let title: String
    let onConfirm: ([Int]) -> Void

    @State private var selected: [Int]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    init(initial: [Int], requiredCount: Int, disabled: Set<Int>, title: String, onConfirm: @escaping ([Int]) -> Void) {
        self.initial = initial
        self.requiredCount = requiredCount
        self.disabled = disabled.subtracting(initial)
        self.title = title
        self.onConfirm = onConfirm
        _selected = State(initialValue: initial)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                Text("已选 \(selected.count)/\(requiredCount) 张 · 点击牌面选择或取消")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    ForEach(0..<requiredCount, id: \.self) { i in
                        ZStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(i < selected.count ? Color(.secondarySystemBackground) : Color.clear)
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: i < selected.count ? [] : [3]))
                            if i < selected.count {
                                Text(Card.text(selected[i]))
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(Card.isRed(selected[i]) ? .red : .primary)
                            } else {
                                Image(systemName: "plus").foregroundColor(.secondary)
                            }
                        }
                        .frame(height: 42)
                    }
                }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach([3, 2, 1, 0], id: \.self) { suit in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Card.suitSymbols[suit])
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(suit == 1 || suit == 2 ? .red : .primary)
                                LazyVGrid(columns: columns, spacing: 3) {
                                    ForEach((0..<13).reversed(), id: \.self) { rank in
                                        let card = Card.make(rank: rank, suit: suit)
                                        let isSelected = selected.contains(card)
                                        let isDisabled = disabled.contains(card) && !isSelected
                                        Button {
                                            if isSelected {
                                                selected.removeAll { $0 == card }
                                            } else if selected.count < requiredCount && !isDisabled {
                                                selected.append(card)
                                            }
                                        } label: {
                                            Text(Card.rankSymbols[rank])
                                                .font(.system(size: 13, weight: .semibold))
                                                .frame(maxWidth: .infinity, minHeight: 32)
                                                .background(isSelected ? Color.accentColor.opacity(0.35) : Color(.secondarySystemBackground))
                                                .foregroundColor(Card.isRed(card) ? .red : .primary)
                                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
                                        }
                                        .disabled(isDisabled)
                                        .opacity(isDisabled ? 0.22 : 1)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                HStack {
                    Button("清空选择") { selected.removeAll() }
                        .disabled(selected.isEmpty)
                    Spacer()
                    Button("确认选择") { onConfirm(selected) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.count != requiredCount)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}