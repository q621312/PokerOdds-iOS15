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

// MARK: - 六人标准德州扑克胜率（全部底牌明牌，公共牌最多四张明牌+一张暗牌）

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
                for i in 0..<5 {
                    hands[p][i + 2] = completedBoard[i]
                }
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
                shares[winners[0]] += 1.0
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
            guard deck.count - start >= left else { return }
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

// MARK: - 选牌目标与视图模型

enum PickerTarget: Identifiable {
    case player(index: Int)
    case board

    var id: String {
        switch self {
        case .player(let index): return "player-\(index)"
        case .board: return "board"
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

    var usedCards: Set<Int> {
        Set((holes.flatMap { $0 } + board).compactMap { $0 })
    }

    var allHolesSelected: Bool {
        holes.allSatisfy { $0.allSatisfy { $0 != nil } }
    }

    func cards(for target: PickerTarget) -> [Int] {
        switch target {
        case .player(let index): return holes[index].compactMap { $0 }
        case .board: return board.compactMap { $0 }
        }
    }

    func selectionLimit(for target: PickerTarget) -> Int {
        switch target {
        case .player: return 2
        case .board: return 4
        }
    }

    func set(_ cards: [Int], for target: PickerTarget) {
        switch target {
        case .player(let index):
            holes[index] = (0..<2).map { $0 < cards.count ? Optional(cards[$0]) : nil }
        case .board:
            board = (0..<4).map { $0 < cards.count ? Optional(cards[$0]) : nil }
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
        status = knownBoard.count == 4
            ? "正在枚举最后一张公共牌暗牌…"
            : "正在枚举剩余公共牌（含最后一张暗牌）…"

        Task {
            let calculated = await Task.detached(priority: .userInitiated) {
                EquityCalculator.compute(holeCards: knownHoles, board: knownBoard)
            }.value

            guard gen == self.generation else { return }
            self.result = calculated
            self.isCalculating = false
            self.status = "已计算：\(knownBoard.count) 张公共牌明牌 + \(5 - knownBoard.count) 张未知公共牌"
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var vm = OddsViewModel()
    @State private var picking: PickerTarget?

    private let playerColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("六人桌 · 标准德州扑克 · 每人两张明牌")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: playerColumns, spacing: 6) {
                        ForEach(0..<6, id: \.self) { player in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("玩家 \(player + 1)")
                                    .font(.caption.weight(.semibold))
                                HStack(spacing: 5) {
                                    ForEach(0..<2, id: \.self) { slot in
                                        CardSlotView(card: vm.holes[player][slot]) {
                                            picking = .player(index: player)
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
                        Text("公共牌（四张明牌 + 一张暗牌）")
                            .font(.caption.weight(.semibold))
                        HStack(spacing: 5) {
                            ForEach(0..<4, id: \.self) { index in
                                CardSlotView(card: vm.board[index]) {
                                    picking = .board
                                }
                            }
                            HiddenCardSlotView()
                        }
                        Text("前四张公共牌逐张公开并选择；最右侧为未公开的第五张公共牌，程序自动枚举，不需要手动选择。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 6) {
                        if vm.isCalculating { ProgressView().scaleEffect(0.8) }
                        Text(vm.status)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let result = vm.result {
                            Text("场景：\(result.scenarios.formatted())")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }

                    if let result = vm.result {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("六位玩家胜率（平局均分权益）")
                                .font(.subheadline.weight(.bold))

                            ForEach(0..<6, id: \.self) { player in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("P\(player + 1)")
                                            .font(.caption.weight(.bold))
                                            .frame(width: 24, alignment: .leading)

                                        GeometryReader { geometry in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Color.gray.opacity(0.15))
                                                Capsule()
                                                    .fill(Color.green)
                                                    .frame(width: geometry.size.width * CGFloat(result.shares[player] / Double(max(1, result.scenarios))))
                                            }
                                        }
                                        .frame(height: 8)

                                        Text(String(format: "%.2f%%", result.shares[player] / Double(max(1, result.scenarios)) * 100))
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .frame(width: 58, alignment: .trailing)
                                    }

                                    HStack(spacing: 12) {
                                        Text("单独获胜 \(String(format: "%.2f%%", Double(result.wins[player]) / Double(max(1, result.scenarios)) * 100))%")
                                        Text("参与平局 \(String(format: "%.2f%%", Double(result.ties[player]) / Double(max(1, result.scenarios)) * 100))%")
                                    }
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 30)
                                }
                            }

                            Text("胜率按权益计算：单独获胜计 100%，多人平局时由获胜玩家均分。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if !vm.isCalculating {
                        Text("六位玩家的 12 张底牌全部选完后，立即开始计算；之后每增加或更换一张公共牌明牌，都会重新计算。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
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
        case .player(let index): return "玩家 \(index + 1) 两张底牌"
        case .board: return "选择公共牌明牌（最多四张）"
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

                if let card = card {
                    Text(Card.text(card))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(Card.isRed(card) ? .red : .black)
                } else {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 43, height: 58)
        }
        .buttonStyle(.plain)
    }
}

struct HiddenCardSlotView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemGray4))
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
            VStack(spacing: 2) {
                Image(systemName: "questionmark")
                    .font(.headline.weight(.bold))
                Text("暗牌")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.secondary)
        }
        .frame(width: 43, height: 58)
    }
}

// MARK: - 区域多选：选满数量自动提交，不足时手动确认

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
