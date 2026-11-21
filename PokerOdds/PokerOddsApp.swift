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

// MARK: - 六人德州扑克胜率（已知全部底牌，枚举剩余公共牌）

struct PlayerResult: Identifiable {
    let id: Int
    let win: Int
    let tie: Int
    let equity: Double
    var winPct: Double { Double(win) / Double(max(1, win + tie + (0))) }
}

struct EquityResult {
    let wins: [Int]
    let ties: [Int]
    let shares: [Double]
    let scenarios: Int
}

enum EquityCalculator {
    static func compute(holeCards: [[Int]], board: [Int]) -> EquityResult {
        let used = Set(holeCards.flatMap { $0 } + board)
        let deck = (0..<52).filter { !used.contains($0) }
        let missing = 5 - board.count
        let evaluator = HandEvaluator()
        let hands = (0..<6).map { _ in UnsafeMutablePointer<Int>.allocate(capacity: 7) }
        defer { hands.forEach { $0.deallocate() } }

        for p in 0..<6 {
            hands[p][0] = holeCards[p][0]
            hands[p][1] = holeCards[p][1]
            for i in 0..<board.count { hands[p][i + 2] = board[i] }
        }

        var wins = Array(repeating: 0, count: 6)
        var ties = Array(repeating: 0, count: 6)
        var shares = Array(repeating: 0.0, count: 6)
        var scenarios = 0
        var completedBoard = board

        func evaluate() {
            scenarios += 1
            var best = Int.min
            var winners: [Int] = []
            for p in 0..<6 {
                for i in 0..<5 { hands[p][i + 2] = completedBoard[i] }
                let score = evaluator.score(hands[p])
                if score > best {
                    best = score
                    winners = [p]
                } else if score == best {
                    winners.append(p)
                }
            }
            if winners.count == 1 {
                wins[winners[0]] += 1
                shares[winners[0]] += 1
            } else {
                for p in winners {
                    ties[p] += 1
                    shares[p] += 1.0 / Double(winners.count)
                }
            }
        }

        func enumerate(start: Int, left: Int) {
            if left == 0 {
                evaluate()
                return
            }
            if deck.count - start < left { return }
            for i in start...(deck.count - left) {
                completedBoard.append(deck[i])
                enumerate(start: i + 1, left: left - 1)
                completedBoard.removeLast()
            }
        }
        enumerate(start: 0, left: missing)

        return EquityResult(wins: wins, ties: ties, shares: shares, scenarios: scenarios)
    }
}

// MARK: - ViewModel

enum PickerTarget: Identifiable {
    case hole(player: Int, index: Int)
    case board(index: Int)
    var id: String {
        switch self {
        case .hole(let p, let i): return "hole-\(p)-\(i)"
        case .board(let i): return "board-\(i)"
        }
    }
}

@MainActor
final class OddsViewModel: ObservableObject {
    @Published var holes: [[Int?]] = Array(repeating: [nil, nil], count: 6)
    @Published var board: [Int?] = Array(repeating: nil, count: 4)
    @Published var result: EquityResult?
    @Published var isCalculating = false
    @Published var status = "请先选完六位玩家的 12 张底牌"
    private var generation = 0

    var usedCards: Set<Int> { Set((holes.flatMap { $0 } + board).compactMap { $0 }) }
    var allHolesSelected: Bool { holes.allSatisfy { $0.allSatisfy { $0 != nil } } }

    func card(for target: PickerTarget) -> Int? {
        switch target {
        case .hole(let p, let i): return holes[p][i]
        case .board(let i): return board[i]
        }
    }

    func set(_ card: Int?, for target: PickerTarget) {
        switch target {
        case .hole(let p, let i): holes[p][i] = card
        case .board(let i): board[i] = card
        }
        recalc()
    }

    func reset() {
        holes = Array(repeating: [nil, nil], count: 6)
        board = Array(repeating: nil, count: 4)
        recalc()
    }

    private func recalc() {
        generation += 1
        let gen = generation
        result = nil
        guard allHolesSelected else {
            isCalculating = false
            status = "请先选完六位玩家的 12 张底牌"
            return
        }
        let knownBoard = board.compactMap { $0 }
        let knownHoles = holes.map { $0.compactMap { $0 } }
        isCalculating = true
        status = "正在枚举剩余公共牌…"
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                EquityCalculator.compute(holeCards: knownHoles, board: knownBoard)
            }.value
            guard gen == self.generation else { return }
            self.result = r
            self.isCalculating = false
            self.status = "已知公共牌 \(knownBoard.count)/4 张 · 按剩余牌补齐至河牌"
        }
    }
}

// MARK: - 界面

struct ContentView: View {
    @StateObject private var vm = OddsViewModel()
    @State private var picking: PickerTarget?

    private let playerColumns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("六人桌 · 标准德州扑克 · 自动补齐未知公共牌")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: playerColumns, spacing: 6) {
                        ForEach(0..<6, id: \.self) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("玩家 \(p + 1)").font(.caption.weight(.semibold))
                                HStack(spacing: 5) {
                                    ForEach(0..<2, id: \.self) { i in
                                        CardSlotView(card: vm.holes[p][i]) {
                                            picking = .hole(player: p, index: i)
                                        }
                                    }
                                }
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("公共牌（最多输入 4 张明牌）").font(.caption.weight(.semibold))
                        HStack(spacing: 5) {
                            ForEach(0..<4, id: \.self) { i in
                                CardSlotView(card: vm.board[i]) {
                                    picking = .board(index: i)
                                }
                            }
                        }
                        Text("每增加或更换一张公共牌，都会自动重新计算；未知牌会枚举至完整五张公共牌。")
                            .font(.caption2).foregroundColor(.secondary)
                    }

                    HStack(spacing: 6) {
                        if vm.isCalculating { ProgressView().scaleEffect(0.8) }
                        Text(vm.status).font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text("场景：\(vm.result?.scenarios ?? 0)")
                            .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                    }

                    if let result = vm.result {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("六位玩家胜率").font(.subheadline.weight(.bold))
                            ForEach(0..<6, id: \.self) { p in
                                HStack(spacing: 6) {
                                    Text("P\(p + 1)").font(.caption.weight(.bold)).frame(width: 24, alignment: .leading)
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.gray.opacity(0.15))
                                            Capsule().fill(Color.green)
                                                .frame(width: geo.size.width * CGFloat(result.shares[p] / Double(max(1, result.scenarios))))
                                        }
                                    }
                                    .frame(height: 8)
                                    Text(String(format: "%.2f%%", result.shares[p] / Double(max(1, result.scenarios)) * 100))
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .frame(width: 58, alignment: .trailing)
                                }
                                HStack(spacing: 12) {
                                    Text("单独获胜 \(String(format: "%.2f%%", Double(result.wins[p]) / Double(max(1, result.scenarios)) * 100))%")
                                    Text("平局 \(String(format: "%.2f%%", Double(result.ties[p]) / Double(max(1, result.scenarios)) * 100))%")
                                }
                                .font(.system(size: 9)).foregroundColor(.secondary)
                            }
                            Text("上方主百分比为权益：平局时由并列玩家均分。")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if !vm.isCalculating {
                        Text("六位玩家的底牌全部选完后，即开始计算。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(8)
            }
            .navigationTitle("六人德州胜率")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("重置") { vm.reset() }
                }
            }
            .sheet(item: $picking) { target in
                CardPickerView(
                    current: vm.card(for: target),
                    disabled: vm.usedCards,
                    title: pickerTitle(target)
                ) { card in
                    vm.set(card, for: target)
                    picking = nil
                }
            }
        }
    }

    private func pickerTitle(_ target: PickerTarget) -> String {
        switch target {
        case .hole(let p, let i): return "玩家 \(p + 1) 底牌 \(i + 1)"
        case .board(let i): return "公共牌 \(i + 1)"
        }
    }
}

struct CardSlotView: View {
    let card: Int?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(card == nil ? Color(.systemBackground) : Color.white)
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                if let c = card {
                    Text(Card.text(c))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(Card.isRed(c) ? .red : .black)
                } else {
                    Image(systemName: "plus").font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(width: 43, height: 58)
        }
        .buttonStyle(.plain)
    }
}

struct CardPickerView: View {
    let current: Int?
    let disabled: Set<Int>
    let title: String
    let onSelect: (Int?) -> Void

    @Environment(\.presentationMode) private var presentationMode
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 7) {
                    if let c = current {
                        Button("清除此位置") { onSelect(nil) }
                            .font(.caption)
                            .padding(5)
                    }
                    ForEach([3, 2, 1, 0], id: \.self) { suit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Card.suitSymbols[suit])
                                .font(.caption.weight(.bold))
                                .foregroundColor(suit == 1 || suit == 2 ? .red : .primary)
                            LazyVGrid(columns: columns, spacing: 3) {
                                ForEach((0..<13).reversed(), id: \.self) { rank in
                                    let card = Card.make(rank: rank, suit: suit)
                                    let unavailable = disabled.contains(card) && card != current
                                    Button {
                                        onSelect(card)
                                    } label: {
                                        Text(Card.rankSymbols[rank])
                                            .font(.system(size: 13, weight: .semibold))
                                            .frame(maxWidth: .infinity, minHeight: 35)
                                            .background(card == current ? Color.accentColor.opacity(0.35) : Color(.secondarySystemBackground))
                                            .foregroundColor(Card.isRed(card) ? .red : .primary)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .disabled(unavailable)
                                    .opacity(unavailable ? 0.2 : 1)
                                }
                            }
                        }
                    }
                }
                .padding(7)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}
