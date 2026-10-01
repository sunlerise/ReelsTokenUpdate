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
    init() {
        // Lets notifications show as banners while the app is open (handy for testing).
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Brand.pink)
        }
        .modelContainer(for: Reminder.self)
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

// MARK: - Domain types

struct Recipient: Hashable {
    let name: String
    let percent: Double // share of this unlock
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

/// Fake data. Dates are anchored to the start of today, so they stay stable
/// during the day. Swap this for a real service later without touching the UI.
/// All numbers are invented.
struct MockUnlockService: UnlockService {
    func fetchUnlocks() async throws -> [UnlockItem] {
        try await Task.sleep(for: .milliseconds(600)) // simulate network

        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        func at(_ days: Int, _ hour: Int) -> Date {
            let day = cal.date(byAdding: .day, value: days, to: today)!
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }

        let items: [UnlockItem] = [
            UnlockItem(id: "arb", coinName: "Arbitrum", symbol: "ARB", date: at(2, 14),
                       usdValue: 41_200_000, percentOfSupply: 2.1,
                       recipients: [Recipient(name: "Investors", percent: 52),
                                    Recipient(name: "Team", percent: 35),
                                    Recipient(name: "DAO treasury", percent: 13)],
                       isConfirmed: true),
            UnlockItem(id: "apt", coinName: "Aptos", symbol: "APT", date: at(5, 9),
                       usdValue: 48_000_000, percentOfSupply: 1.8,
                       recipients: [Recipient(name: "Core contributors", percent: 45),
                                    Recipient(name: "Investors", percent: 40),
                                    Recipient(name: "Community", percent: 15)],
                       isConfirmed: true),
            UnlockItem(id: "sui", coinName: "Sui", symbol: "SUI", date: at(9, 0),
                       usdValue: 130_000_000, percentOfSupply: 3.4,
                       recipients: [Recipient(name: "Series A/B investors", percent: 50),
                                    Recipient(name: "Mysten Labs", percent: 50)],
                       isConfirmed: true),
            UnlockItem(id: "tia", coinName: "Celestia", symbol: "TIA", date: at(14, 12),
                       usdValue: 22_500_000, percentOfSupply: 2.6,
                       recipients: [Recipient(name: "Early backers", percent: 60),
                                    Recipient(name: "Core contributors", percent: 40)],
                       isConfirmed: false),
            UnlockItem(id: "op", coinName: "Optimism", symbol: "OP", date: at(20, 0),
                       usdValue: 36_800_000, percentOfSupply: 2.3,
                       recipients: [Recipient(name: "Investors", percent: 55),
                                    Recipient(name: "Core contributors", percent: 45)],
                       isConfirmed: true),
            UnlockItem(id: "strk", coinName: "Starknet", symbol: "STRK", date: at(27, 15),
                       usdValue: 62_000_000, percentOfSupply: 4.1,
                       recipients: [Recipient(name: "Early contributors", percent: 50),
                                    Recipient(name: "Investors", percent: 50)],
                       isConfirmed: true),
            UnlockItem(id: "sei", coinName: "Sei", symbol: "SEI", date: at(35, 8),
                       usdValue: 18_400_000, percentOfSupply: 1.9,
                       recipients: [Recipient(name: "Private investors", percent: 70),
                                    Recipient(name: "Team", percent: 30)],
                       isConfirmed: false),
            UnlockItem(id: "zk", coinName: "ZKsync", symbol: "ZK", date: at(45, 10),
                       usdValue: 55_000_000, percentOfSupply: 3.9,
                       recipients: [Recipient(name: "Investors", percent: 49),
                                    Recipient(name: "Team", percent: 51)],
                       isConfirmed: true),
        ]
        return items.sorted { $0.date < $1.date }
    }
}

// MARK: - View model

@Observable
@MainActor
final class UnlocksViewModel {
    var items: [UnlockItem] = []
    var isLoading = false
    var errorMessage: String?

    private let service: UnlockService

    init(service: UnlockService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.fetchUnlocks()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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

            let content = UNMutableNotificationContent()
            content.title = "\(reminder.symbol) unlock \(ReminderOffset(rawValue: offset)?.leadText ?? "soon")"
            content.body = "\(reminder.usdValue.compactUSD) (\(reminder.percentOfSupply.percentText) of supply) unlocks "
                + reminder.unlockDate.formatted(date: .abbreviated, time: .shortened)
            content.sound = .default

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: identifier(reminder.unlockID, offset),
                content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Formatting helpers

extension Double {
    var compactUSD: String {
        // Currency + compact notation is iOS 18+. Abbreviate by hand for iOS 17.
        let absValue = abs(self)
        let (divisor, suffix): (Double, String) = {
            if absValue >= 1_000_000_000 { return (1_000_000_000, "B") }
            if absValue >= 1_000_000 { return (1_000_000, "M") }
            if absValue >= 1_000 { return (1_000, "K") }
            return (1, "")
        }()
        let number = (absValue / divisor).formatted(.number.precision(.fractionLength(0...1)))
        return "\(self < 0 ? "-" : "")$\(number)\(suffix)"
    }
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
        switch self.uppercased() {
        case "ARB": urlString = "https://assets.coingecko.com/coins/images/16547/large/arbitrum.png"
        case "APT": urlString = "https://assets.coingecko.com/coins/images/26455/large/aptos_round.png"
        case "SUI": urlString = "https://assets.coingecko.com/coins/images/26375/large/sui-ocean-square.png"
        case "TIA": urlString = "https://assets.coingecko.com/coins/images/31967/large/celestia-logo.png"
        case "OP":  urlString = "https://assets.coingecko.com/coins/images/25244/large/Optimism.png"
        case "STRK": urlString = "https://assets.coingecko.com/coins/images/35043/large/starknet.png"
        case "SEI": urlString = "https://assets.coingecko.com/coins/images/28205/large/Sei_Logo_-_Transparent.png"
        case "ZK":  urlString = "https://assets.coingecko.com/coins/images/36047/large/zksync.jpeg"
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
            subtitle: "Browse upcoming unlocks by week, month, or the really big ones. Confirmed dates and estimates are labeled so you know what’s solid."
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
            subtitle: "Set a reminder 15 minutes, 1 hour, or 1 day before. We’ll ping you so a surprise unlock doesn’t catch you off guard."
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
    }
}

// MARK: - Screen 1: Upcoming list

enum UnlockFilter: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case all = "All" // Замінили Big ($50M+) на логічне All
    var id: String { rawValue }
}

struct UpcomingView: View {
    @Environment(UnlocksViewModel.self) private var vm
    @Query private var reminders: [Reminder]
    @State private var filter: UnlockFilter = .month

    private var reminderIDs: Set<String> { Set(reminders.map(\.unlockID)) }

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
                                Text(option.rawValue)
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

                List(filtered) { item in
                    NavigationLink(value: item) {
                        UnlockRow(item: item, hasReminder: reminderIDs.contains(item.id))
                    }
                    .playfulCardRow()
                }
                .listStyle(.plain)
                .overlay {
                    if vm.isLoading && vm.items.isEmpty {
                        ProgressView()
                            .tint(Brand.pink)
                    } else if let error = vm.errorMessage, vm.items.isEmpty {
                        ContentUnavailableView("Couldn't load", systemImage: "wifi.slash",
                                               description: Text(error))
                    } else if filtered.isEmpty {
                        ContentUnavailableView("No unlocks", systemImage: "lock.open")
                    }
                }
                .refreshable { await vm.load() }
            }
            .playfulScreen()
            .navigationTitle("Token Unlocks")
            .navigationDestination(for: UnlockItem.self) { UnlockDetailView(item: $0) }
            .task { if vm.items.isEmpty { await vm.load() } }
        }
    }
}

struct UnlockRow: View {
    let item: UnlockItem
    let hasReminder: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoinBadge(symbol: item.symbol)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.symbol)
                        .font(.headline.weight(.bold))
                    if !item.isConfirmed {
                        Text("Estimated")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Brand.hotPink.opacity(0.22), in: Capsule())
                            .foregroundStyle(Brand.hotPink)
                    }
                }
                Text(item.coinName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

struct UnlockDetailView: View {
    let item: UnlockItem
    @Query private var reminders: [Reminder]
    @State private var showSheet = false

    private var existing: Reminder? { reminders.first { $0.unlockID == item.id } }

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
            }
            .playfulCardRow()

            Section("Size") {
                LabeledContent("Value", value: item.usdValue.compactUSD)
                LabeledContent("Share of supply", value: item.percentOfSupply.percentText)
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

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 8) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.purple)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthGrid, id: \.self) { date in
                    dayCell(date)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { visibleMonth = selectedDate }
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
        return dates
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
    @State private var selectedDate = Date()

    private var reminderIDs: Set<String> { Set(reminders.map(\.unlockID)) }

    private var dayMarks: [Date: CalendarDayMark] {
        let cal = Calendar.current
        var marks: [Date: CalendarDayMark] = [:]
        for item in vm.items {
            let key = cal.startOfDay(for: item.date)
            marks[key, default: CalendarDayMark()].hasUnlock = true
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
                                UnlockRow(item: item, hasReminder: reminderIDs.contains(item.id))
                            }
                            .playfulCardRow()
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
            .task { if vm.items.isEmpty { await vm.load() } }
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
                .map { $0 >= 1440 ? "\($0 / 1440)d" : $0 >= 60 ? "\($0 / 60)h" : "\($0)m" }
                .joined(separator: " · "))
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
