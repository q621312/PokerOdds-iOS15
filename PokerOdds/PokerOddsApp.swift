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

// MARK: - 双人特殊规则胜率
struct EquityResult {
    let wins: Int
    let ties: Int
    let scenarios: Int
    var equity: Double { (Double(wins) + Double(ties) * 0.5) / Double(max(1, scenarios)) }
    var winRate: Double { Double(wins) / Double(max(1, scenarios)) }
    var tieRate: Double { Double(ties) / Double(max(1, scenarios)) }
}

enum EquityCalculator {
    // 一对4及以上：任何牌型类别更高，或对子类别中对子点数至少为4。
    private static let pairOfFoursThreshold = (1 << 20) | (2 << 16)

    static func compute(playerOne: [Int], flop: [Int]) -> EquityResult {
        let used = Set(playerOne + flop)
        let deck = (0..<52).filter { !used.contains($0) }
        let evaluator = HandEvaluator()
        let hand1 = UnsafeMutablePointer<Int>.allocate(capacity: 7)
        let hand2 = UnsafeMutablePointer<Int>.allocate(capacity: 7)
        defer { hand1.deallocate(); hand2.deallocate() }

        hand1[0] = playerOne[0]
        hand1[1] = playerOne[1]
        hand2[0] = 0
        hand2[1] = 0
        for i in 0..<3 {
            hand1[i + 2] = flop[i]
            hand2[i + 2] = flop[i]
        }

        var wins = 0
        var ties = 0
        var scenarios = 0
        let n = deck.count

        // 先枚举玩家二的两张暗牌，再从剩余牌中枚举转牌和河牌。
        for a in 0..<(n - 1) {
            hand2[0] = deck[a]
            for b in (a + 1)..<n {
                hand2[1] = deck[b]
                var boardIndex = [Int]()
                boardIndex.reserveCapacity(n - 2)
                for k in 0..<n where k != a && k != b { boardIndex.append(deck[k]) }

                for x in 0..<(boardIndex.count - 1) {
                    hand1[5] = boardIndex[x]
                    hand2[5] = boardIndex[x]
                    for y in (x + 1)..<boardIndex.count {
                        hand1[6] = boardIndex[y]
                        hand2[6] = boardIndex[y]
                        scenarios += 1

                        let score2 = evaluator.score(hand2)
                        if score2 < pairOfFoursThreshold {
                            wins += 1
                        } else {
                            let score1 = evaluator.score(hand1)
                            if score1 > score2 { wins += 1 }
                            else if score1 == score2 { ties += 1 }
                        }
                    }
                }
            }
        }
        return EquityResult(wins: wins, ties: ties, scenarios: scenarios)
    }
}

// MARK: - 选牌目标与视图模型
enum PickerTarget: Identifiable {
    case playerOne(index: Int)
    case board(index: Int)
    var id: String {
        switch self {
        case .playerOne(let i): return "p1-\(i)"
        case .board(let i): return "board-\(i)"
        }
    }
}

@MainActor
final class OddsViewModel: ObservableObject {
    @Published var playerOne: [Int?] = [nil, nil]
    @Published var board: [Int?] = [nil, nil, nil]
    @Published var result: EquityResult?
    @Published var isCalculating = false
    @Published var status = "请选择玩家一的两张明牌和公共牌三张明牌"
    private var generation = 0

    var usedCards: Set<Int> { Set((playerOne + board).compactMap { $0 }) }
    var ready: Bool { playerOne.allSatisfy { $0 != nil } && board.allSatisfy { $0 != nil } }

    // 点击任一槽位后，选牌器管理该区域的全部牌，而不是只编辑单个槽位。
    func cards(for target: PickerTarget) -> [Int] {
        switch target {
        case .playerOne: return playerOne.compactMap { $0 }
        case .board: return board.compactMap { $0 }
        }
    }

    func selectionLimit(for target: PickerTarget) -> Int {
        switch target {
        case .playerOne: return 2
        case .board: return 3
        }
    }

    func set(_ cards: [Int], for target: PickerTarget) {
        switch target {
        case .playerOne:
            playerOne = (0..<2).map { $0 < cards.count ? Optional(cards[$0]) : nil }
        case .board:
            board = (0..<3).map { $0 < cards.count ? Optional(cards[$0]) : nil }
        }
        recalc()
    }

    func reset() {
        playerOne = [nil, nil]
        board = [nil, nil, nil]
        recalc()
    }

    private func recalc() {
        generation += 1
        let gen = generation
        result = nil
        guard ready else {
            isCalculating = false
            status = "请选择玩家一的两张明牌和公共牌三张明牌"
            return
        }
        let p1 = playerOne.compactMap { $0 }
        let flop = board.compactMap { $0 }
        isCalculating = true
        status = "正在枚举玩家二暗牌及后两张公共牌…"
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                EquityCalculator.compute(playerOne: p1, flop: flop)
            }.value
            guard gen == self.generation else { return }
            self.result = r
            self.isCalculating = false
            self.status = "已完成全部可能局面"
        }
    }
}

// MARK: - 主界面
struct ContentView: View {
    @StateObject private var vm = OddsViewModel()
    @State private var picking: PickerTarget?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("玩家二暗牌未知 · 按特殊规则计算最终胜率")
                        .font(.caption2).foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("玩家一（两张明牌）").font(.caption.weight(.semibold))
                        HStack(spacing: 6) {
                            ForEach(0..<2, id: \.self) { i in
                                CardSlotView(card: vm.playerOne[i]) {
                                    picking = .playerOne(index: i)
                                }
                            }
                        }
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 5) {
                        Text("公共牌（三张明牌）").font(.caption.weight(.semibold))
                        HStack(spacing: 6) {
                            ForEach(0..<3, id: \.self) { i in
                                CardSlotView(card: vm.board[i]) {
                                    picking = .board(index: i)
                                }
                            }
                        }
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 5) {
                        if vm.isCalculating { ProgressView().scaleEffect(0.8) }
                        Text(vm.status).font(.caption2).foregroundColor(.secondary)
                    }

                    if let r = vm.result {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("玩家一最终胜率").font(.subheadline.weight(.bold))
                            Text(String(format: "%.4f%%", r.equity * 100))
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .foregroundColor(.green)
                            HStack(spacing: 12) {
                                Text(String(format: "单独获胜 %.4f%%", r.winRate * 100))
                                Text(String(format: "平局 %.4f%%", r.tieRate * 100))
                            }
                            .font(.caption).foregroundColor(.secondary)
                            Text("计算局面：\(r.scenarios.formatted())")
                                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                            Text("规则：玩家二最终最佳五张牌低于一对4，玩家一直接获胜；否则按标准德州扑克比较。平局按各半计入胜率。")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if !vm.isCalculating {
                        Text("五张已知牌全部选完后，自动开始枚举所有可能的暗牌与转牌、河牌。")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(8)
            }
            .navigationTitle("德州胜率计算")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("重置") { vm.reset() }
                }
            }
            .sheet(item: $picking) { target in
                CardPickerView(
                    selectedCards: vm.cards(for: target),
                    disabled: vm.usedCards.subtracting(vm.cards(for: target)),
                    selectionLimit: vm.selectionLimit(for: target),
                    title: pickerTitle(target)
                ) { cards in
                    vm.set(cards, for: target)
                    picking = nil
                }
            }
        }
    }

    private func pickerTitle(_ target: PickerTarget) -> String {
        switch target {
        case .playerOne(let i): return "玩家一底牌 \(i + 1)"
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

// MARK: - 多张选牌：玩家明牌选满2张、公共牌选满3张时自动提交；不足时手动确认
struct CardPickerView: View {
    let selectedCards: [Int]
    let disabled: Set<Int>
    let selectionLimit: Int
    let title: String
    let onSelect: ([Int]) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var draftCards: [Int]
    private let suitsInOrder = [3, 0, 2, 1] // 黑桃、梅花、红桃、方块

    init(selectedCards: [Int], disabled: Set<Int>, selectionLimit: Int,
         title: String, onSelect: @escaping ([Int]) -> Void) {
        self.selectedCards = selectedCards
        self.disabled = disabled
        self.selectionLimit = selectionLimit
        self.title = title
        self.onSelect = onSelect
        _draftCards = State(initialValue: selectedCards)
    }

    private var isFull: Bool { draftCards.count == selectionLimit }

    private func toggle(_ card: Int) {
        if let index = draftCards.firstIndex(of: card) {
            draftCards.remove(at: index)
        } else if draftCards.count < selectionLimit {
            draftCards.append(card)
            if draftCards.count == selectionLimit {
                onSelect(draftCards)
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Text("已选 \(draftCards.count)/\(selectionLimit) 张：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(draftCards, id: \.self) { card in
                        Text(Card.text(card))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Card.isRed(card) ? .red : .primary)
                    }
                    Spacer()
                    if !draftCards.isEmpty {
                        Button("清空") { draftCards.removeAll() }
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 3)

                ForEach(suitsInOrder, id: \.self) { suit in
                    HStack(spacing: 2) {
                        ForEach((0..<13).reversed(), id: \.self) { rank in
                            let card = Card.make(rank: rank, suit: suit)
                            let unavailable = disabled.contains(card)
                            let selected = draftCards.contains(card)
                            Button {
                                toggle(card)
                            } label: {
                                Text(Card.rankSymbols[rank] + Card.suitSymbols[suit])
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .minimumScaleFactor(0.65)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(selected ? Color.accentColor.opacity(0.35) : Color(.secondarySystemBackground))
                                    .foregroundColor(Card.isRed(card) ? .red : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .disabled(unavailable || (!selected && draftCards.count >= selectionLimit))
                            .opacity(unavailable ? 0.2 : 1)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button {
                    onSelect(draftCards)
                } label: {
                    Text("确认选择（\(draftCards.count)张）")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftCards.isEmpty || isFull)
                .padding(.bottom, 5)
            }
            .padding(.horizontal, 5)
            .padding(.top, 8)
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
