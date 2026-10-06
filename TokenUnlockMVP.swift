//
//  TokenUnlockMVP.swift
//  Single-file MVP sketch: token unlock list, detail, reminders, calendar.
//
//  Requirements: Xcode 15+, iOS 17+ (SwiftData + @Observable).
//  Setup: new iOS App project (SwiftUI). Delete the default App file and
//  ContentView.swift, drop this file in. Only one @main may exist.
//  Local notifications need no extra capability.
//

import SwiftUI
import SwiftData
import UserNotifications

// MARK: - App entry

@main
struct TokenUnlockApp: App {
    private let modelContainer: ModelContainer

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

        let schema = Schema([Reminder.self, WatchedToken.self])
        do {
            modelContainer = try ModelContainer(for: schema)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Brand.pink)
        }
        .modelContainer(modelContainer)
    }
}


// MARK: - Persistence model (SwiftData)

/// One saved reminder per unlock. Stores a snapshot of the unlock so the
/// Reminders tab and notifications work offline and without the API.
@Model
final class Reminder {
    @Attribute(.unique) var unlockID: String
    var coinName: String
    var symbol: String
    var unlockDate: Date
    var usdValue: Double
    var percentOfSupply: Double
    var offsetsMinutes: [Int]
    var createdAt: Date

    init(target: ReminderTarget, offsetsMinutes: [Int]) {
        self.unlockID = target.unlockID
        self.coinName = target.coinName
        self.symbol = target.symbol
        self.unlockDate = target.date
        self.usdValue = target.usdValue
        self.percentOfSupply = target.percentOfSupply
        self.offsetsMinutes = offsetsMinutes
        self.createdAt = .now
    }
}

/// A token on the watchlist: every upcoming unlock of it gets an alert.
@Model
final class WatchedToken {
    @Attribute(.unique) var symbol: String
    var coinName: String
    var alertOffsetMinutes: Int
    var createdAt: Date

    init(symbol: String, coinName: String, alertOffsetMinutes: Int = ReminderOffset.oneDay.rawValue) {
        self.symbol = symbol
        self.coinName = coinName
        self.alertOffsetMinutes = alertOffsetMinutes
        self.createdAt = .now
    }
}

extension ModelContext {
    func toggleWatch(symbol: String, coinName: String, existing: WatchedToken?) {
        if let existing {
            delete(existing)
        } else {
            insert(WatchedToken(symbol: symbol, coinName: coinName))
        }
    }
}

// MARK: - Domain types

struct Recipient: Hashable {
    let name: String
    let percent: Double // share of this unlock
}

enum UnlockSchedule: String, Hashable {
    case cliff, monthly, quarterly

    var label: String {
        switch self {
        case .cliff: "One-time cliff"
        case .monthly: "Monthly vesting"
        case .quarterly: "Quarterly vesting"
        }
    }
}

struct UnlockItem: Identifiable, Hashable {
    let id: String
    let coinName: String
    let symbol: String
    let date: Date
    let usdValue: Double
    let percentOfSupply: Double
    let recipients: [Recipient]
    let isConfirmed: Bool
    // Optional so an item rebuilt from a saved Reminder snapshot still works.
    var tokenAmount: Double?
    var priceUSD: Double?
    var priceChange24h: Double?
    var percentOfCirculating: Double?
    var schedule: UnlockSchedule?
    var volume24hUSD: Double?
}

/// Rough sell-pressure estimate: how long the market needs to absorb the
/// unlock at current volume, and how much it dilutes circulating supply.
enum UnlockImpact: Int, Comparable {
    case low, medium, high

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .low: "Low impact"
        case .medium: "Medium impact"
        case .high: "High impact"
        }
    }

    var color: Color {
        switch self {
        case .low: .green
        case .medium: .orange
        case .high: Brand.hotPink
        }
    }

    var explanation: String {
        switch self {
        case .low: "Small next to daily trading. The market usually absorbs unlocks like this without much notice."
        case .medium: "Noticeable supply. If recipients sell, it can weigh on price around the unlock date."
        case .high: "Large next to daily trading and circulating supply. Unlocks like this often move the price."
        }
    }
}

extension UnlockItem {
    /// Unlock value expressed in days of current 24h trading volume.
    var daysOfVolume: Double? {
        guard let volume24hUSD, volume24hUSD > 0 else { return nil }
        return usdValue / volume24hUSD
    }

    var impact: UnlockImpact? {
        guard let days = daysOfVolume else { return nil }
        let dilution = percentOfCirculating ?? percentOfSupply
        if days >= 1 || dilution >= 5 { return .high }
        if days >= 0.15 || dilution >= 1.5 { return .medium }
        return .low
    }
}

/// Lightweight snapshot used by the reminder sheet (works for both an
/// UnlockItem from the API and a saved Reminder).
struct ReminderTarget {
    let unlockID: String
    let coinName: String
    let symbol: String
    let date: Date
    let usdValue: Double
    let percentOfSupply: Double
}

extension UnlockItem {
    var target: ReminderTarget {
        ReminderTarget(unlockID: id, coinName: coinName, symbol: symbol,
                       date: date, usdValue: usdValue, percentOfSupply: percentOfSupply)
    }
}

extension Reminder {
    var target: ReminderTarget {
        ReminderTarget(unlockID: unlockID, coinName: coinName, symbol: symbol,
                       date: unlockDate, usdValue: usdValue, percentOfSupply: percentOfSupply)
    }
}

enum ReminderOffset: Int, CaseIterable, Identifiable {
    case fifteenMinutes = 15
    case oneHour = 60
    case oneDay = 1440

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fifteenMinutes: "15 minutes before"
        case .oneHour: "1 hour before"
        case .oneDay: "1 day before"
        }
    }

    var leadText: String {
        switch self {
        case .fifteenMinutes: "in 15 minutes"
        case .oneHour: "in 1 hour"
        case .oneDay: "in 1 day"
        }
    }
}

// MARK: - Data service (mock now, real API later)

protocol UnlockService: Sendable {
    func fetchUnlocks() async throws -> [UnlockItem]
}

// MARK: - API contract (what the backend is expected to return)

/// snake_case JSON, ISO 8601 dates. The mock produces exactly these bytes,
/// so a real service only needs `URLSession` + `UnlockAPI.decodeUnlocks`.
struct UnlocksResponseDTO: Codable {
    struct Meta: Codable {
        let updatedAt: Date
        let source: String
    }
    let data: [UnlockDTO]
    let meta: Meta
}

struct UnlockDTO: Codable {
    struct Token: Codable {
        let name: String
        let symbol: String
        let priceUsd: Double
        let priceChange24h: Double
        let volume24hUsd: Double
        let circulatingSupply: Double
        let totalSupply: Double
    }
    struct Allocation: Codable {
        let name: String
        let percent: Double
    }

    let id: String
    let token: Token
    let unlockDate: Date
    let amount: Double
    let valueUsd: Double
    let percentOfTotalSupply: Double
    let percentOfCirculating: Double
    let schedule: String // "cliff" | "monthly" | "quarterly"
    let isConfirmed: Bool
    let allocations: [Allocation]
}

enum UnlockAPI {
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Fallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601.string(from: date))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = iso8601.date(from: value) ?? iso8601Fallback.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized ISO8601 date: \(value)"
            )
        }
        return decoder
    }

    static func items(from response: UnlocksResponseDTO) -> [UnlockItem] {
        response.data.map(UnlockItem.init(dto:))
    }

    /// Real backend entry point once networking is wired up.
    static func decodeUnlocks(_ data: Data) throws -> [UnlockItem] {
        try items(from: decoder.decode(UnlocksResponseDTO.self, from: data))
    }
}

extension UnlockItem {
    init(dto: UnlockDTO) {
        self.init(
            id: dto.id,
            coinName: dto.token.name,
            symbol: dto.token.symbol,
            date: dto.unlockDate,
            usdValue: dto.valueUsd,
            percentOfSupply: dto.percentOfTotalSupply,
            recipients: dto.allocations.map { Recipient(name: $0.name, percent: $0.percent) },
            isConfirmed: dto.isConfirmed,
            tokenAmount: dto.amount,
            priceUSD: dto.token.priceUsd,
            priceChange24h: dto.token.priceChange24h,
            percentOfCirculating: dto.percentOfCirculating,
            schedule: UnlockSchedule(rawValue: dto.schedule) ?? .cliff,
            volume24hUSD: dto.token.volume24hUsd
        )
    }
}

// MARK: - Mock backend

/// Simulated backend. Expands vesting schedules modelled on real tokens
/// (amounts approximate, prices/supply from CoinGecko, Oct 2026) into unlock
/// events for the next ~8 months, then round-trips them through JSON.
/// Also simulates latency, small price moves between refreshes and the odd
/// network failure (never on the first request, so launch always works).
final class MockUnlockService: UnlockService {
    private let failureRate: Double
    private var requestCount = 0

    /// Set above 0 to simulate flaky network on pull-to-refresh (never on first load).
    init(failureRate: Double = 0) {
        self.failureRate = failureRate
    }

    func fetchUnlocks() async throws -> [UnlockItem] {
        requestCount += 1
        try await Task.sleep(for: .milliseconds(Int.random(in: 350...1100)))

        if requestCount > 1, failureRate > 0, Double.random(in: 0..<1) < failureRate {
            let failures: [(URLError.Code, String)] = [
                (.timedOut, "The request timed out."),
                (.notConnectedToInternet, "The Internet connection appears to be offline."),
                (.networkConnectionLost, "The network connection was lost."),
            ]
            let (code, message) = failures.randomElement()!
            throw URLError(code, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let response = MockCatalog.response(now: .now)
        guard !response.data.isEmpty else {
            throw URLError(.cannotDecodeContentData,
                           userInfo: [NSLocalizedDescriptionKey: "Mock catalog returned no unlocks."])
        }

        // Build domain models from the DTO (always). Round-trip JSON in debug to
        // catch contract drift before a real API is plugged in.
        let items = UnlockAPI.items(from: response)
        #if DEBUG
        do {
            let json = try UnlockAPI.encoder.encode(response)
            _ = try UnlockAPI.decodeUnlocks(json)
        } catch {
            print("Mock JSON contract mismatch (mock still loads):", error)
        }
        #endif
        return items
    }
}

private struct VestingSchedule {
    let name: String
    let symbol: String
    let kind: UnlockSchedule
    /// Months (1-12) the unlock happens in; nil means every month.
    let months: Set<Int>?
    /// Day of month, clamped to the month's length (e.g. 30 → Feb 28).
    let day: Int
    let hourUTC: Int
    let amount: Double
    let price: Double
    let volume24h: Double
    let circulating: Double
    let total: Double
    let allocations: [UnlockDTO.Allocation]
    var isConfirmed = true
}

private enum MockCatalog {
    static let horizonDays = 240.0
    /// Events further out than this are flagged as estimates.
    static let confirmedWithinDays = 120.0

    static func response(now: Date) -> UnlocksResponseDTO {
        let end = now.addingTimeInterval(horizonDays * 86_400)
        let dayKey = now.formatted(.iso8601.year().month().day())
        var events: [UnlockDTO] = []

        for s in schedules {
            // Same 24h move all day, plus a little jitter on every refresh.
            var rng = SeededGenerator(seed: "\(s.symbol)-\(dayKey)")
            let change24h = Double.random(in: -9...9, using: &rng)
            let price = s.price * (1 + change24h / 100) * Double.random(in: 0.995...1.005)
            let volume = s.volume24h * Double.random(in: 0.75...1.25, using: &rng)
                * Double.random(in: 0.98...1.02)

            var circulating = s.circulating
            for date in occurrences(of: s, after: now, until: end) {
                let isConfirmed = s.isConfirmed
                    && date.timeIntervalSince(now) < confirmedWithinDays * 86_400
                events.append(UnlockDTO(
                    id: "\(s.symbol.lowercased())-\(date.formatted(.iso8601.year().month().day()))",
                    token: .init(name: s.name, symbol: s.symbol, priceUsd: price,
                                 priceChange24h: change24h, volume24hUsd: volume,
                                 circulatingSupply: s.circulating,
                                 totalSupply: s.total),
                    unlockDate: date,
                    amount: s.amount,
                    valueUsd: s.amount * price,
                    percentOfTotalSupply: s.amount / s.total * 100,
                    percentOfCirculating: s.amount / circulating * 100,
                    schedule: s.kind.rawValue,
                    isConfirmed: isConfirmed,
                    allocations: s.allocations
                ))
                circulating += s.amount
            }
        }

        events.sort { ($0.unlockDate, -$0.valueUsd) < ($1.unlockDate, -$1.valueUsd) }
        return UnlocksResponseDTO(data: events, meta: .init(updatedAt: now, source: "mock"))
    }

    private static func occurrences(of s: VestingSchedule, after now: Date, until end: Date) -> [Date] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let thisMonth = utc.date(from: utc.dateComponents([.year, .month], from: now))!

        return (0..<9).compactMap { offset -> Date? in
            guard let monthStart = utc.date(byAdding: .month, value: offset, to: thisMonth) else { return nil }
            let comps = utc.dateComponents([.year, .month], from: monthStart)
            if let months = s.months, !months.contains(comps.month!) { return nil }
            let daysInMonth = utc.range(of: .day, in: .month, for: monthStart)!.count
            let date = utc.date(from: DateComponents(
                year: comps.year, month: comps.month, day: min(s.day, daysInMonth), hour: s.hourUTC))!
            return date > now && date <= end ? date : nil
        }
    }

    private static func split(_ parts: (String, Double)...) -> [UnlockDTO.Allocation] {
        parts.map { UnlockDTO.Allocation(name: $0.0, percent: $0.1) }
    }

    static let schedules: [VestingSchedule] = [
        VestingSchedule(name: "Arbitrum", symbol: "ARB", kind: .monthly, months: nil, day: 16, hourUTC: 13,
                        amount: 92_650_000, price: 0.2015, volume24h: 179_000_000, circulating: 6_785_574_605, total: 10_000_000_000,
                        allocations: split(("Team & advisors", 60.6), ("Investors", 39.4))),
        VestingSchedule(name: "Aptos", symbol: "APT", kind: .monthly, months: nil, day: 12, hourUTC: 0,
                        amount: 11_310_000, price: 0.8085, volume24h: 66_500_000, circulating: 871_172_141, total: 1_209_612_277,
                        allocations: split(("Community", 34), ("Core contributors", 29),
                                           ("Investors", 19), ("Foundation", 18))),
        VestingSchedule(name: "Sui", symbol: "SUI", kind: .monthly, months: nil, day: 1, hourUTC: 0,
                        amount: 44_000_000, price: 1.17, volume24h: 724_000_000, circulating: 4_118_270_447, total: 10_000_000_000,
                        allocations: split(("Series B investors", 30), ("Series A investors", 25),
                                           ("Early contributors", 25), ("Mysten Labs", 20))),
        VestingSchedule(name: "Optimism", symbol: "OP", kind: .monthly, months: nil, day: 30, hourUTC: 0,
                        amount: 31_340_000, price: 0.1354, volume24h: 87_300_000, circulating: 2_299_624_975, total: 4_294_967_296,
                        allocations: split(("Core contributors", 54), ("Investors", 46))),
        VestingSchedule(name: "Starknet", symbol: "STRK", kind: .monthly, months: nil, day: 15, hourUTC: 0,
                        amount: 127_000_000, price: 0.0486, volume24h: 68_300_000, circulating: 7_421_949_505, total: 10_000_000_000,
                        allocations: split(("Early contributors", 50.4), ("Investors", 49.6))),
        VestingSchedule(name: "Sei", symbol: "SEI", kind: .monthly, months: nil, day: 15, hourUTC: 12,
                        amount: 55_560_000, price: 0.0707, volume24h: 50_400_000, circulating: 6_733_333_333, total: 10_000_000_000,
                        allocations: split(("Ecosystem reserve", 50), ("Team", 30), ("Private investors", 20))),
        VestingSchedule(name: "Ethena", symbol: "ENA", kind: .monthly, months: nil, day: 2, hourUTC: 8,
                        amount: 171_880_000, price: 0.2341, volume24h: 283_000_000, circulating: 10_095_312_500, total: 15_000_000_000,
                        allocations: split(("Core contributors", 56), ("Investors", 44))),
        VestingSchedule(name: "ZKsync", symbol: "ZK", kind: .monthly, months: nil, day: 17, hourUTC: 0,
                        amount: 173_000_000, price: 0.0130, volume24h: 11_700_000, circulating: 10_816_539_153, total: 21_000_000_000,
                        allocations: split(("Team", 51), ("Investors", 49))),
        VestingSchedule(name: "Celestia", symbol: "TIA", kind: .monthly, months: nil, day: 30, hourUTC: 14,
                        amount: 16_200_000, price: 0.4766, volume24h: 78_000_000, circulating: 976_303_634, total: 1_178_536_352,
                        allocations: split(("Early backers", 60), ("Core contributors", 40)),
                        isConfirmed: false),
        VestingSchedule(name: "dYdX", symbol: "DYDX", kind: .monthly, months: nil, day: 1, hourUTC: 15,
                        amount: 8_330_000, price: 0.1516, volume24h: 8_100_000, circulating: 846_094_216, total: 958_342_751,
                        allocations: split(("Investors", 65), ("Founders & employees", 35))),
        VestingSchedule(name: "Jupiter", symbol: "JUP", kind: .monthly, months: nil, day: 28, hourUTC: 16,
                        amount: 53_470_000, price: 0.3301, volume24h: 67_100_000, circulating: 3_319_369_204, total: 6_861_486_482,
                        allocations: split(("Team", 100))),
        VestingSchedule(name: "Avalanche", symbol: "AVAX", kind: .quarterly, months: [2, 5, 8, 11], day: 23, hourUTC: 0,
                        amount: 1_670_000, price: 11.07, volume24h: 492_000_000, circulating: 443_231_081, total: 469_899_771,
                        allocations: split(("Team", 50), ("Foundation", 25), ("Strategic partners", 25))),
        VestingSchedule(name: "Ondo", symbol: "ONDO", kind: .cliff, months: [1], day: 18, hourUTC: 0,
                        amount: 1_940_000_000, price: 0.4922, volume24h: 176_600_000, circulating: 4_869_330_647, total: 10_000_000_000,
                        allocations: split(("Ecosystem growth", 40), ("Protocol development", 30),
                                           ("Private sales", 30))),
        VestingSchedule(name: "Wormhole", symbol: "W", kind: .cliff, months: [4], day: 3, hourUTC: 0,
                        amount: 1_280_000_000, price: 0.0138, volume24h: 11_500_000, circulating: 6_586_023_610, total: 10_000_000_000,
                        allocations: split(("Core contributors", 40), ("Ecosystem", 35), ("Strategic network", 25)),
                        isConfirmed: false),
        VestingSchedule(name: "Pyth Network", symbol: "PYTH", kind: .cliff, months: [5], day: 20, hourUTC: 14,
                        amount: 2_130_000_000, price: 0.0781, volume24h: 23_200_000, circulating: 7_874_959_274, total: 10_000_000_000,
                        allocations: split(("Ecosystem growth", 52), ("Publisher rewards", 18),
                                           ("Private sales", 18), ("Protocol development", 12))),
    ]
}

/// Deterministic RNG (SplitMix64 seeded with FNV-1a), so mock values stay
/// stable for a given key. Swift's `Hasher` is randomized per launch.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: String) {
        state = seed.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - View model

@Observable
@MainActor
final class UnlocksViewModel {
    var items: [UnlockItem] = []
    var isLoading = false
    var errorMessage: String?
    var lastUpdated: Date?

    private let service: UnlockService

    init(service: UnlockService) {
        self.service = service
    }

    func load() async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await service.fetchUnlocks()
            items = fetched
            lastUpdated = .now
            errorMessage = nil
        } catch is CancellationError {
            // View went away mid-refresh; keep whatever we already had.
            return
        } catch {
            #if DEBUG
            print("Unlock load failed:", error)
            #endif
            if items.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Local notifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

enum NotificationScheduler {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func identifier(_ unlockID: String, _ offset: Int) -> String {
        "unlock-\(unlockID)-\(offset)"
    }

    static func cancel(unlockID: String) {
        let ids = ReminderOffset.allCases.map { identifier(unlockID, $0.rawValue) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Cancels any old notifications for this unlock, then schedules the current set.
    /// Offsets whose fire time is already in the past are skipped.
    static func schedule(_ reminder: Reminder) {
        cancel(unlockID: reminder.unlockID)

        for offset in reminder.offsetsMinutes {
            let fireDate = reminder.unlockDate.addingTimeInterval(-Double(offset) * 60)
            guard fireDate > .now else { continue }

            let body = "\(reminder.usdValue.compactUSD) (\(reminder.percentOfSupply.percentText) of supply) unlocks "
                + reminder.unlockDate.formatted(date: .abbreviated, time: .shortened)
            UNUserNotificationCenter.current().add(request(
                id: identifier(reminder.unlockID, offset), symbol: reminder.symbol,
                offset: offset, body: body, fireDate: fireDate))
        }
    }

    // MARK: Watchlist

    private static let watchPrefix = "watch-"
    /// iOS keeps at most 64 pending notifications per app; leave room for
    /// one-off reminders.
    private static let maxWatchAlerts = 40

    /// Replaces all watchlist alerts with one per upcoming unlock of each
    /// watched token (nearest first). Unlocks that already have their own
    /// reminder are skipped so nothing fires twice.
    static func syncWatchlist(_ watched: [WatchedToken], items: [UnlockItem], skipping reminderIDs: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(watchPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        guard !watched.isEmpty, await requestAuthorization() else { return }

        let offsets = Dictionary(watched.map { ($0.symbol, $0.alertOffsetMinutes) }, uniquingKeysWith: { a, _ in a })
        let planned = items
            .filter { !reminderIDs.contains($0.id) }
            .compactMap { item -> (fireDate: Date, item: UnlockItem, offset: Int)? in
                guard let offset = offsets[item.symbol] else { return nil }
                let fireDate = item.date.addingTimeInterval(-Double(offset) * 60)
                return fireDate > .now ? (fireDate, item, offset) : nil
            }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(maxWatchAlerts)

        for (fireDate, item, offset) in planned {
            var body = "\(item.tokenAmount.map { "\($0.compactNumber) \(item.symbol)" } ?? item.symbol) "
                + "(\(item.usdValue.compactUSD)) unlocks "
                + item.date.formatted(date: .abbreviated, time: .shortened)
            if let impact = item.impact {
                body += ". \(impact.label)."
            }
            try? await center.add(request(
                id: "\(watchPrefix)\(item.id)", symbol: item.symbol,
                offset: offset, body: body, fireDate: fireDate, subtitle: "From your watchlist"))
        }
    }

    private static func request(id: String, symbol: String, offset: Int, body: String,
                                fireDate: Date, subtitle: String? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "\(symbol) unlock \(ReminderOffset(rawValue: offset)?.leadText ?? "soon")"
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}

// MARK: - Formatting helpers

extension Double {
    var compactUSD: String {
        // Currency + compact notation is iOS 18+. Abbreviate by hand for iOS 17.
        "\(self < 0 ? "-" : "")$\(abs(self).compactNumber)"
    }

    var compactNumber: String {
        let absValue = abs(self)
        let (divisor, suffix): (Double, String) = {
            if absValue >= 1_000_000_000 { return (1_000_000_000, "B") }
            if absValue >= 1_000_000 { return (1_000_000, "M") }
            if absValue >= 1_000 { return (1_000, "K") }
            return (1, "")
        }()
        let number = (absValue / divisor).formatted(.number.precision(.fractionLength(0...1)))
        return "\(self < 0 ? "-" : "")\(number)\(suffix)"
    }

    var priceText: String {
        formatted(.currency(code: "USD").precision(.significantDigits(2...4)))
    }

    /// `self` is a number of days of trading volume.
    var tradingTimeText: String {
        let hours = Int((self * 24).rounded())
        if hours < 1 { return "under 1 hour of trading" }
        if hours == 1 { return "1 hour of trading" }
        if hours < 48 { return "\(hours) hours of trading" }
        return "\(formatted(.number.precision(.fractionLength(1)))) days of trading"
    }

    var signedPercentText: String { String(format: "%+.1f%%", self) }
    var percentText: String { String(format: "%.1f%%", self) }
}

extension View {
    /// `navigationBarTitleDisplayMode` exists on iOS/visionOS, not macOS.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(macOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }

    func playfulScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { PlayfulBackground() }
    }

    func playfulCardRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .padding(.horizontal, 16) // Added horizontal spacing so cards don't touch edges
                    .padding(.vertical, 4)
            )
    }

    /// `.animation(_:value:)` needs a concrete view; also skip it on older OS versions.
    @ViewBuilder
    func valueAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.animation(animation, value: value)
        } else {
            self
        }
    }

    @ViewBuilder
    func playfulSymbolEffects(trigger: Bool) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self
                .symbolEffect(.bounce, value: trigger)
                .symbolEffect(.pulse, options: .repeating, isActive: trigger)
        } else {
            self
        }
    }
}

// MARK: - Brand

enum Brand {
    static let pink = Color(red: 0.98, green: 0.38, blue: 0.72)
    static let hotPink = Color(red: 1.0, green: 0.48, blue: 0.82)
    static let purple = Color(red: 0.62, green: 0.42, blue: 1.0)
    static let violet = Color(red: 0.38, green: 0.18, blue: 0.72)
    static let ink = Color(red: 0.06, green: 0.04, blue: 0.12)

    static var accent: LinearGradient {
        LinearGradient(
            colors: [hotPink, pink, purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var softAccent: LinearGradient {
        LinearGradient(
            colors: [pink.opacity(0.9), purple.opacity(0.9)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct PlayfulBackground: View {
    var body: some View {
        ZStack {
            Brand.ink
            Circle()
                .fill(Brand.violet.opacity(0.7))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: -140, y: -220)
            Circle()
                .fill(Brand.pink.opacity(0.45))
                .frame(width: 300, height: 300)
                .blur(radius: 100)
                .offset(x: 160, y: -40)
            Circle()
                .fill(Brand.purple.opacity(0.4))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: 20, y: 340)
            LinearGradient(
                colors: [.clear, Brand.ink.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Real Crypto Icons Mapping
extension String {
    var coinIconURL: URL? {
        let urlString: String
        let base = "https://coin-images.coingecko.com/coins/images/"
        switch self.uppercased() {
        case "ARB":  urlString = base + "16547/large/arb.jpg"
        case "APT":  urlString = base + "26455/large/Aptos-Network-Profile-Picture_%281%29.png"
        case "SUI":  urlString = base + "26375/large/sui-ocean-square.png"
        case "TIA":  urlString = base + "31967/large/tia.jpg"
        case "OP":   urlString = base + "25244/large/Token.png"
        case "STRK": urlString = base + "26433/large/starknet.png"
        case "SEI":  urlString = base + "28205/large/Sei_Logo_-_Transparent.png"
        case "ZK":   urlString = base + "38043/large/ZKTokenBlack.png"
        case "ENA":  urlString = base + "36530/large/ethena.png"
        case "DYDX": urlString = base + "32594/large/dydx.png"
        case "JUP":  urlString = base + "34188/large/jup.png"
        case "AVAX": urlString = base + "12559/large/Avalanche_Circle_RedWhite_Trans.png"
        case "ONDO": urlString = base + "26580/large/ONDO.png"
        case "W":    urlString = base + "35087/large/W_Token_%283%29.png"
        case "PYTH": urlString = base + "31924/large/pyth.png"
        default: return nil
        }
        return URL(string: urlString)
    }
}

struct CoinBadge: View {
    let symbol: String
    var size: CGFloat = 44

    var body: some View {
        if let url = symbol.coinIconURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    fallbackView
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: Brand.pink.opacity(0.35), radius: 8, y: 4)
        } else {
            fallbackView
        }
    }
    
    private var fallbackView: some View {
        Text(String(symbol.prefix(2)))
            .font(.system(size: size * 0.32, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Brand.accent, in: Circle())
            .overlay {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: Brand.pink.opacity(0.35), radius: 8, y: 4)
    }
}

// MARK: - Onboarding

private let onboardingCompletedKey = "hasCompletedOnboarding"

struct OnboardingSlide: Identifiable, Hashable {
    let id: Int
    let symbol: String
    let title: String
    let subtitle: String
}

enum OnboardingContent {
    static let slides: [OnboardingSlide] = [
        OnboardingSlide(
            id: 0,
            symbol: "sparkles",
            title: "Token Unlocks",
            subtitle: "A heads-up for crypto vesting cliffs. See when tokens hit the market, how big the unlock is, and who receives them."
        ),
        OnboardingSlide(
            id: 1,
            symbol: "lock.open.fill",
            title: "What’s coming next",
            subtitle: "Browse upcoming unlocks by week, month, or just the high-impact ones. Each unlock is sized against daily trading volume, so you can tell a ripple from a wave."
        ),
        OnboardingSlide(
            id: 2,
            symbol: "calendar",
            title: "Marked on the calendar",
            subtitle: "Jump to any day and spot unlocks at a glance. Purple dots are events, pink dots are reminders you set."
        ),
        OnboardingSlide(
            id: 3,
            symbol: "bell.badge.fill",
            title: "Never miss a cliff",
            subtitle: "Star a token to get alerts for every unlock it has, or set a one-off reminder 15 minutes, 1 hour, or 1 day before."
        ),
        OnboardingSlide(
            id: 4,
            symbol: "moon.stars.fill",
            title: "You’re in",
            subtitle: "Stay on the dark side, follow the pink glow, and keep an eye on supply. Ready when you are."
        ),
    ]
}

struct OnboardingView: View {
    var onFinished: () -> Void

    @State private var page = 0
    @State private var appeared = false

    private var isLast: Bool { page == OnboardingContent.slides.count - 1 }

    var body: some View {
        ZStack {
            PlayfulBackground()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if !isLast {
                        Button("Skip", action: finish)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .frame(height: 36)

                Group {
                    #if os(iOS) || os(visionOS)
                    TabView(selection: $page) {
                        ForEach(OnboardingContent.slides) { slide in
                            OnboardingSlidePage(slide: slide)
                                .tag(slide.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    #else
                    OnboardingSlidePage(slide: OnboardingContent.slides[page])
                    #endif
                }
                .valueAnimation(.spring(response: 0.45, dampingFraction: 0.85), value: page)

                HStack(spacing: 8) {
                    ForEach(OnboardingContent.slides) { slide in
                        Capsule()
                            .fill(slide.id == page ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.white.opacity(0.22)))
                            .frame(width: slide.id == page ? 22 : 8, height: 8)
                    }
                }
                .padding(.bottom, 20)
                .valueAnimation(.spring(response: 0.35, dampingFraction: 0.7), value: page)

                Button(action: advance) {
                    Text(isLast ? "Let’s go" : "Next")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.white)
                        .background(Brand.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Brand.pink.opacity(0.35), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .scaleEffect(appeared ? 1 : 0.92)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                appeared = true
            }
        }
    }

    private func advance() {
        if isLast {
            finish()
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                page += 1
            }
        }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.35)) {
            onFinished()
        }
    }
}

struct OnboardingSlidePage: View {
    let slide: OnboardingSlide

    @State private var appeared = false
    @State private var bob = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(Brand.violet.opacity(0.35))
                    .frame(width: 168, height: 168)
                    .blur(radius: 8)
                    .scaleEffect(bob ? 1.08 : 0.92)

                Image(systemName: slide.symbol)
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .symbolRenderingMode(.hierarchical)
                    .playfulSymbolEffects(trigger: appeared)
                    .scaleEffect(appeared ? 1 : 0.55)
                    .offset(y: bob ? -10 : 8)
            }
            .frame(height: 180)

            VStack(spacing: 12) {
                Text(slide.title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)

                Text(slide.subtitle)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 12)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .onAppear { play() }
        .onChange(of: slide.id) { _, _ in
            appeared = false
            play()
        }
    }

    private func play() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
            appeared = true
        }
        withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
            bob = true
        }
    }
}

// MARK: - Root

struct RootView: View {
    @AppStorage(onboardingCompletedKey) private var hasCompletedOnboarding = false
    @State private var vm = UnlocksViewModel(service: MockUnlockService())
    @Query private var watched: [WatchedToken]
    @Query private var reminders: [Reminder]

    /// Changes whenever watchlist alerts need rescheduling.
    private var watchSyncKey: String {
        [watched.map { "\($0.symbol):\($0.alertOffsetMinutes)" }.sorted().joined(separator: ","),
         vm.items.map(\.id).joined(separator: ","),
         reminders.map(\.unlockID).sorted().joined(separator: ",")]
            .joined(separator: "|")
    }

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                TabView {
                    UpcomingView()
                        .tabItem { Label("Upcoming", systemImage: "calendar.badge.clock") } // Змінена іконка
                    CalendarView()
                        .tabItem { Label("Reminders", systemImage: "bell.fill") } // Змінена іконка
                }
            } else {
                OnboardingView {
                    hasCompletedOnboarding = true
                }
            }
        }
        .environment(vm)
        .valueAnimation(.easeInOut(duration: 0.4), value: hasCompletedOnboarding)
        .task(id: hasCompletedOnboarding) {
            guard hasCompletedOnboarding, vm.items.isEmpty else { return }
            await vm.load()
        }
        .task(id: watchSyncKey) {
            guard !vm.items.isEmpty else { return }
            await NotificationScheduler.syncWatchlist(
                watched, items: vm.items, skipping: Set(reminders.map(\.unlockID)))
        }
    }
}

// MARK: - Screen 1: Upcoming list

enum UnlockFilter: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case all = "All" // Замінили Big ($50M+) на логічне All
    case watching = "Watching"
    case highImpact = "High impact"
    var id: String { rawValue }

    var systemImage: String? {
        switch self {
        case .watching: "star.fill"
        case .highImpact: "flame.fill"
        default: nil
        }
    }
}

struct UpcomingView: View {
    @Environment(UnlocksViewModel.self) private var vm
    @Environment(\.modelContext) private var context
    @Query private var reminders: [Reminder]
    @Query private var watched: [WatchedToken]
    @State private var filter: UnlockFilter = .month

    private var reminderIDs: Set<String> { Set(reminders.map(\.unlockID)) }
    private var watchedSymbols: Set<String> { Set(watched.map(\.symbol)) }

    private var filtered: [UnlockItem] {
        let cal = Calendar.current
        switch filter {
        case .week:
            let end = cal.date(byAdding: .day, value: 7, to: .now)!
            return vm.items.filter { $0.date < end }
        case .month:
            let end = cal.date(byAdding: .day, value: 30, to: .now)!
            return vm.items.filter { $0.date < end }
        case .all: // Повертаємо всі дані
            return vm.items
        case .watching:
            return vm.items.filter { watchedSymbols.contains($0.symbol) }
        case .highImpact:
            return vm.items.filter { $0.impact == .high }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(UnlockFilter.allCases) { option in
                            Button {
                                filter = option
                            } label: {
                                HStack(spacing: 5) {
                                    if let systemImage = option.systemImage {
                                        Image(systemName: systemImage).font(.caption)
                                    }
                                    Text(option.rawValue)
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundStyle(filter == option ? Color.white : Color.white.opacity(0.7))
                                .background {
                                    if filter == option {
                                        Capsule().fill(Brand.accent)
                                    } else {
                                        Capsule().fill(Color.white.opacity(0.08))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                statusLine

                List {
                    if vm.isLoading && vm.items.isEmpty {
                        ForEach(0..<6, id: \.self) { index in
                            UnlockRow(item: .placeholder(index), hasReminder: false)
                                .redacted(reason: .placeholder)
                                .playfulCardRow()
                        }
                    } else {
                        ForEach(filtered) { item in
                            let watch = watched.first { $0.symbol == item.symbol }
                            NavigationLink(value: item) {
                                UnlockRow(item: item, hasReminder: reminderIDs.contains(item.id),
                                          isWatched: watch != nil)
                            }
                            .playfulCardRow()
                            .swipeActions(edge: .leading) {
                                Button {
                                    context.toggleWatch(symbol: item.symbol, coinName: item.coinName, existing: watch)
                                } label: {
                                    Label(watch == nil ? "Watch" : "Unwatch",
                                          systemImage: watch == nil ? "star.fill" : "star.slash")
                                }
                                .tint(watch == nil ? Brand.purple : .gray)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if vm.isLoading && vm.items.isEmpty {
                        EmptyView()
                    } else if let error = vm.errorMessage, vm.items.isEmpty {
                        ContentUnavailableView {
                            Label("Couldn't load", systemImage: "wifi.slash")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try again") { Task { await vm.load() } }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if filter == .watching && watched.isEmpty {
                        ContentUnavailableView(
                            "Your watchlist is empty", systemImage: "star",
                            description: Text("Swipe right on an unlock or tap the star on its page to get alerts for every unlock of that token."))
                    } else if filtered.isEmpty {
                        ContentUnavailableView("No unlocks", systemImage: "lock.open")
                    }
                }
                .refreshable { await vm.load() }
            }
            .playfulScreen()
            .navigationTitle("Token Unlocks")
            .navigationDestination(for: UnlockItem.self) { UnlockDetailView(item: $0) }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if vm.errorMessage != nil, !vm.items.isEmpty {
            Label("Couldn't refresh. Pull down to try again.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.hotPink)
                .padding(.bottom, 4)
        } else if let lastUpdated = vm.lastUpdated {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
        }
    }
}

extension UnlockItem {
    /// Stand-in content for skeleton rows while the first load is in flight.
    static func placeholder(_ index: Int) -> UnlockItem {
        UnlockItem(id: "placeholder-\(index)", coinName: "Loading token", symbol: "TKN",
                   date: .now, usdValue: 12_300_000, percentOfSupply: 1.2,
                   recipients: [], isConfirmed: true)
    }
}

struct ImpactBadge: View {
    let impact: UnlockImpact

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(impact.color)
                .frame(width: 6, height: 6)
            Text(impact.label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(impact.color)
        .lineLimit(1)
    }
}

struct UnlockRow: View {
    let item: UnlockItem
    let hasReminder: Bool
    var isWatched = false

    var body: some View {
        HStack(spacing: 12) {
            CoinBadge(symbol: item.symbol)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.symbol)
                        .font(.headline.weight(.bold))
                    if isWatched {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Brand.accent)
                    }
                    if !item.isConfirmed {
                        Text("Estimated")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Brand.hotPink.opacity(0.22), in: Capsule())
                            .foregroundStyle(Brand.hotPink)
                    }
                }
                HStack(spacing: 8) {
                    Text(item.coinName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let impact = item.impact {
                        ImpactBadge(impact: impact)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.date, format: .dateTime.month(.abbreviated).day())
                    .font(.subheadline.weight(.semibold))
                Text("\(item.usdValue.compactUSD) · \(item.percentOfSupply.percentText)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Brand.purple)
            }
            if hasReminder {
                Image(systemName: "bell.fill")
                    .foregroundStyle(Brand.accent)
                    .font(.footnote)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Screen 2: Detail

struct ImpactMeter: View {
    let impact: UnlockImpact

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { level in
                Capsule()
                    .fill(level <= impact.rawValue ? impact.color : Color.white.opacity(0.1))
                    .frame(height: 6)
            }
        }
    }
}

struct UnlockDetailView: View {
    let item: UnlockItem
    @Environment(\.modelContext) private var context
    @Query private var reminders: [Reminder]
    @Query private var watchedTokens: [WatchedToken]
    @State private var showSheet = false

    private var existing: Reminder? { reminders.first { $0.unlockID == item.id } }
    private var watch: WatchedToken? { watchedTokens.first { $0.symbol == item.symbol } }

    private func toggleWatch() {
        context.toggleWatch(symbol: item.symbol, coinName: item.coinName, existing: watch)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    CoinBadge(symbol: item.symbol, size: 72)
                    Text(item.coinName)
                        .font(.title2.weight(.bold))
                    Text(item.usdValue.compactUSD)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(Brand.accent)
                    Text("\(item.percentOfSupply.percentText) of supply · \(item.date, style: .relative)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let impact = item.impact {
                        ImpactBadge(impact: impact)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(impact.color.opacity(0.15), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .playfulCardRow()

            Section {
                LabeledContent("Date") {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Countdown") {
                    Text(item.date, style: .relative)
                        .foregroundStyle(Brand.hotPink)
                }
                LabeledContent("Status") {
                    Text(item.isConfirmed ? "Confirmed" : "Estimated")
                        .foregroundStyle(item.isConfirmed ? Brand.purple : Brand.hotPink)
                }
                if let schedule = item.schedule {
                    LabeledContent("Type", value: schedule.label)
                }
            }
            .playfulCardRow()

            if let impact = item.impact, let days = item.daysOfVolume, let volume = item.volume24hUSD {
                Section("Market impact") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(impact.label)
                            .font(.headline)
                            .foregroundStyle(impact.color)
                        ImpactMeter(impact: impact)
                        Text(impact.explanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Same as", value: days.tradingTimeText)
                    LabeledContent("24h volume", value: volume.compactUSD)
                }
                .playfulCardRow()
            }

            Section("Size") {
                if let tokenAmount = item.tokenAmount {
                    LabeledContent("Tokens", value: "\(tokenAmount.compactNumber) \(item.symbol)")
                }
                LabeledContent("Value", value: item.usdValue.compactUSD)
                if let price = item.priceUSD {
                    LabeledContent("Price") {
                        HStack(spacing: 6) {
                            Text(price.priceText)
                            if let change = item.priceChange24h {
                                Text(change.signedPercentText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(change >= 0 ? Color.green : Color.red)
                            }
                        }
                    }
                }
                LabeledContent("Share of total supply", value: item.percentOfSupply.percentText)
                if let circulating = item.percentOfCirculating {
                    LabeledContent("Share of circulating") {
                        Text(circulating.percentText)
                            .foregroundStyle(circulating >= 5 ? Brand.hotPink : .secondary)
                    }
                }
            }
            .playfulCardRow()

            Section("Who receives it") {
                ForEach(item.recipients, id: \.self) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(r.name)
                            Spacer()
                            Text(String(format: "%.0f%%", r.percent))
                                .fontWeight(.semibold)
                                .foregroundStyle(Brand.pink)
                        }
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Brand.softAccent)
                                        .frame(width: max(8, geo.size.width * CGFloat(r.percent / 100)))
                                }
                        }
                        .frame(height: 8)
                    }
                    .padding(.vertical, 4)
                }
            }
            .playfulCardRow()

            Section("Watchlist") {
                if let watch {
                    Picker("Alert me", selection: Binding(
                        get: { watch.alertOffsetMinutes },
                        set: { watch.alertOffsetMinutes = $0 })) {
                        ForEach(ReminderOffset.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    Text("You’ll get an alert before every upcoming \(item.symbol) unlock, not just this one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Remove from watchlist", role: .destructive, action: toggleWatch)
                } else {
                    Button(action: toggleWatch) {
                        Label("Watch \(item.symbol)", systemImage: "star")
                            .fontWeight(.semibold)
                    }
                    Text("Get an alert before every future \(item.symbol) unlock, not just this one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .playfulCardRow()

            Section {
                Button {
                    showSheet = true
                } label: {
                    Label(existing == nil ? "Remind me" : "Edit reminder",
                          systemImage: existing == nil ? "bell.fill" : "bell.badge.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(Brand.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                if let existing {
                    Text("Alerts: " + existing.offsetsMinutes.sorted()
                        .compactMap { ReminderOffset(rawValue: $0)?.label }
                        .joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .playfulScreen()
        .navigationTitle("\(item.symbol) · \(item.coinName)")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleWatch) {
                    Image(systemName: watch == nil ? "star" : "star.fill")
                        .foregroundStyle(Brand.accent)
                }
                .accessibilityLabel(watch == nil ? "Watch \(item.symbol)" : "Unwatch \(item.symbol)")
            }
        }
        .sheet(isPresented: $showSheet) {
            ReminderSheet(target: item.target, existing: existing)
        }
    }
}

// MARK: - Screen 3: Reminder sheet (add + edit)

struct ReminderSheet: View {
    let target: ReminderTarget
    let existing: Reminder?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>
    @State private var showDeniedAlert = false

    init(target: ReminderTarget, existing: Reminder?) {
        self.target = target
        self.existing = existing
        _selected = State(initialValue: Set(existing?.offsetsMinutes ?? [ReminderOffset.oneHour.rawValue]))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ReminderOffset.allCases) { option in
                        Toggle(option.label, isOn: Binding(
                            get: { selected.contains(option.rawValue) },
                            set: { isOn in
                                if isOn { selected.insert(option.rawValue) }
                                else { selected.remove(option.rawValue) }
                            }))
                    }
                } header: {
                    Text("\(target.symbol) unlocks " + target.date.formatted(date: .abbreviated, time: .shortened))
                } footer: {
                    Text("You can pick more than one.")
                }

                if let existing {
                    Section {
                        Button("Delete reminder", role: .destructive) {
                            NotificationScheduler.cancel(unlockID: existing.unlockID)
                            context.delete(existing)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(existing == nil ? "Remind me" : "Edit reminder")
            .inlineNavigationTitle()
            .playfulScreen()
            .tint(Brand.pink)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(selected.isEmpty)
                }
            }
            .alert("Notifications are off", isPresented: $showDeniedAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("Your reminder is saved, but turn on notifications in Settings to get alerts.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let offsets = selected.sorted()
        let reminder: Reminder
        if let existing {
            existing.offsetsMinutes = offsets
            reminder = existing
        } else {
            reminder = Reminder(target: target, offsetsMinutes: offsets)
            context.insert(reminder)
        }

        Task {
            if await NotificationScheduler.requestAuthorization() {
                NotificationScheduler.schedule(reminder)
                dismiss()
            } else {
                showDeniedAlert = true
            }
        }
    }
}

// MARK: - Screen 4: Calendar + my reminders

struct CalendarDayMark: Equatable {
    var hasUnlock = false
    var hasReminder = false
}

struct MarkedMonthCalendar: View {
    @Binding var selectedDate: Date
    var marks: [Date: CalendarDayMark]

    @State private var visibleMonth: Date = .now

    private var calendar: Calendar { .current }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    shiftMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                Spacer()
                Text(visibleMonth, format: .dateTime.month(.wide).year())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Brand.accent)
                Spacer()
                Button {
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            // Eager Grid (not LazyVGrid): a lazy grid inside List reports 0 height,
            // then its real height, so the Reminders tab jumps / can crash on device.
            Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.purple)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(monthWeeks.enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(week, id: \.self) { date in
                            dayCell(date)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if !calendar.isDate(visibleMonth, equalTo: selectedDate, toGranularity: .month) {
                visibleMonth = selectedDate
            }
        }
        .onChange(of: selectedDate) { _, newValue in
            if !calendar.isDate(newValue, equalTo: visibleMonth, toGranularity: .month) {
                visibleMonth = newValue
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private var monthGrid: [Date] {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth))!
        let range = calendar.range(of: .day, in: .month, for: start)!
        let weekdayOfFirst = calendar.component(.weekday, from: start)
        let leading = (weekdayOfFirst - calendar.firstWeekday + 7) % 7

        var dates: [Date] = []
        if leading > 0 {
            for offset in stride(from: leading, through: 1, by: -1) {
                dates.append(calendar.date(byAdding: .day, value: -offset, to: start)!)
            }
        }
        for day in range {
            dates.append(calendar.date(byAdding: .day, value: day - 1, to: start)!)
        }
        while dates.count % 7 != 0 {
            dates.append(calendar.date(byAdding: .day, value: 1, to: dates.last!)!)
        }
        return dates.map { calendar.startOfDay(for: $0) }
    }

    private var monthWeeks: [[Date]] {
        let days = monthGrid
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0 ..< min($0 + 7, days.count)]) }
    }

    private func dayCell(_ date: Date) -> some View {
        let inMonth = calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let mark = marks[calendar.startOfDay(for: date)]

        return Button {
            selectedDate = date
            if !inMonth { visibleMonth = date }
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.body.weight(isSelected ? .bold : .regular))
                    .foregroundStyle(dayForeground(inMonth: inMonth, isSelected: isSelected))
                    .frame(width: 36, height: 36)
                    .background {
                        if isSelected {
                            Circle().fill(Brand.accent)
                        } else if isToday {
                            Circle().stroke(Brand.pink, lineWidth: 1.5)
                        }
                    }

                HStack(spacing: 3) {
                    if mark?.hasUnlock == true {
                        Circle()
                            .fill(isSelected ? Color.white : Brand.purple)
                            .frame(width: 5, height: 5)
                    }
                    if mark?.hasReminder == true {
                        Circle()
                            .fill(isSelected ? Color.white : Brand.hotPink)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(date, mark: mark))
    }

    private func dayForeground(inMonth: Bool, isSelected: Bool) -> Color {
        if isSelected { return .white }
        if !inMonth { return .secondary.opacity(0.45) }
        return .primary
    }

    private func accessibilityLabel(_ date: Date, mark: CalendarDayMark?) -> String {
        var parts = [date.formatted(date: .complete, time: .omitted)]
        if mark?.hasUnlock == true { parts.append("unlock") }
        if mark?.hasReminder == true { parts.append("reminder") }
        return parts.joined(separator: ", ")
    }

    private func shiftMonth(_ value: Int) {
        if let next = calendar.date(byAdding: .month, value: value, to: visibleMonth) {
            visibleMonth = next
        }
    }
}

struct CalendarView: View {
    @Environment(UnlocksViewModel.self) private var vm
    @Environment(\.modelContext) private var context
    @Query(sort: \Reminder.unlockDate) private var reminders: [Reminder]
    @Query(sort: \WatchedToken.symbol) private var watched: [WatchedToken]
    @State private var selectedDate = Date()

    private var reminderIDs: Set<String> { Set(reminders.map(\.unlockID)) }
    private var watchedSymbols: Set<String> { Set(watched.map(\.symbol)) }

    private var dayMarks: [Date: CalendarDayMark] {
        let cal = Calendar.current
        var marks: [Date: CalendarDayMark] = [:]
        for item in vm.items {
            let key = cal.startOfDay(for: item.date)
            marks[key, default: CalendarDayMark()].hasUnlock = true
            if watchedSymbols.contains(item.symbol) {
                marks[key, default: CalendarDayMark()].hasReminder = true
            }
        }
        for reminder in reminders {
            let key = cal.startOfDay(for: reminder.unlockDate)
            marks[key, default: CalendarDayMark()].hasReminder = true
        }
        return marks
    }

    private var unlocksOnSelectedDay: [UnlockItem] {
        vm.items.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MarkedMonthCalendar(selectedDate: $selectedDate, marks: dayMarks)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowInsets(EdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24))
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .padding(.horizontal, 16) // Added spacing here too
                        .padding(.vertical, 4)
                )
                .listRowSeparator(.hidden)

                Section(header: Text(selectedDate.formatted(date: .complete, time: .omitted))) {
                    if unlocksOnSelectedDay.isEmpty {
                        Text("No unlocks on this day").foregroundStyle(.secondary)
                            .playfulCardRow()
                    } else {
                        ForEach(unlocksOnSelectedDay) { item in
                            NavigationLink(value: item) {
                                UnlockRow(item: item, hasReminder: reminderIDs.contains(item.id),
                                          isWatched: watchedSymbols.contains(item.symbol))
                            }
                            .playfulCardRow()
                        }
                    }
                }

                Section("Watchlist") {
                    if watched.isEmpty {
                        Text("Tap the star on any unlock to get alerts for every unlock of that token.")
                            .foregroundStyle(.secondary)
                            .playfulCardRow()
                    } else {
                        ForEach(watched) { token in
                            Group {
                                if let next = nextUnlock(of: token.symbol) {
                                    NavigationLink(value: next) { watchRow(token) }
                                } else {
                                    watchRow(token)
                                }
                            }
                            .playfulCardRow()
                            .swipeActions {
                                Button("Unwatch", role: .destructive) {
                                    context.delete(token)
                                }
                            }
                        }
                    }
                }

                Section("All reminders") {
                    if reminders.isEmpty {
                        Text("Open an unlock and tap “Remind me”.").foregroundStyle(.secondary)
                            .playfulCardRow()
                    } else {
                        ForEach(reminders) { reminder in
                            NavigationLink(value: unlockItem(for: reminder)) {
                                reminderRow(reminder)
                            }
                            .playfulCardRow()
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    NotificationScheduler.cancel(unlockID: reminder.unlockID)
                                    context.delete(reminder)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .playfulScreen()
            .navigationTitle("My Reminders")
            .navigationDestination(for: UnlockItem.self) { UnlockDetailView(item: $0) }
        }
    }

    private func reminderRow(_ reminder: Reminder) -> some View {
        HStack(spacing: 12) {
            CoinBadge(symbol: reminder.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.symbol).font(.headline.weight(.bold))
                Text(reminder.unlockDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(reminder.offsetsMinutes.sorted()
                .map(shortOffset)
                .joined(separator: " · "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.pink)
        }
        .padding(.vertical, 4)
    }

    private func shortOffset(_ minutes: Int) -> String {
        minutes >= 1440 ? "\(minutes / 1440)d" : minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    private func nextUnlock(of symbol: String) -> UnlockItem? {
        vm.items.first { $0.symbol == symbol && $0.date > .now }
    }

    private func watchRow(_ token: WatchedToken) -> some View {
        let next = nextUnlock(of: token.symbol)
        return HStack(spacing: 12) {
            CoinBadge(symbol: token.symbol)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(token.symbol).font(.headline.weight(.bold))
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Brand.accent)
                }
                if let next {
                    HStack(spacing: 8) {
                        Text("Next \(next.date.formatted(.dateTime.month(.abbreviated).day())) · \(next.usdValue.compactUSD)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let impact = next.impact {
                            ImpactBadge(impact: impact)
                        }
                    }
                } else {
                    Text("No upcoming unlocks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(shortOffset(token.alertOffsetMinutes))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.pink)
        }
        .padding(.vertical, 4)
    }

    /// Prefer the live unlock from the list so detail has recipients; fall back
    /// to the snapshot stored on the reminder.
    private func unlockItem(for reminder: Reminder) -> UnlockItem {
        if let item = vm.items.first(where: { $0.id == reminder.unlockID }) {
            return item
        }
        return UnlockItem(
            id: reminder.unlockID,
            coinName: reminder.coinName,
            symbol: reminder.symbol,
            date: reminder.unlockDate,
            usdValue: reminder.usdValue,
            percentOfSupply: reminder.percentOfSupply,
            recipients: [],
            isConfirmed: true
        )
    }
}
