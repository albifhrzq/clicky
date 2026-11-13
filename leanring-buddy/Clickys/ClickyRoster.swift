//
//  ClickyRoster.swift
//  leanring-buddy
//

import Combine
import Foundation

public nonisolated enum ClickyAgentProp: String, Codable, CaseIterable, Sendable, Identifiable {
    case pencil
    case hammer
    case envelope
    case magnifier
    case paintbrush
    case paperPlane
    case cart
    case book
    case chart
    case musicNote
    case camera
    case clipboard
    case pan
    case globe
    case gear
    case lightbulb
    case heart
    case clock
    case mapPin
    case gift
    case trophy
    case key
    case flask
    case graduationCap
    case speechBubble
    case sparkle
    case star
    case bolt

    public var id: String { rawValue }

    public var systemImageName: String {
        switch self {
        case .pencil: return "pencil"
        case .hammer: return "hammer.fill"
        case .envelope: return "envelope.fill"
        case .magnifier: return "magnifyingglass"
        case .paintbrush: return "paintbrush.fill"
        case .paperPlane: return "paperplane.fill"
        case .cart: return "cart.fill"
        case .book: return "book.fill"
        case .chart: return "chart.bar.fill"
        case .musicNote: return "music.note"
        case .camera: return "camera.fill"
        case .clipboard: return "clipboard.fill"
        case .pan: return "frying.pan.fill"
        case .globe: return "globe"
        case .gear: return "gearshape.fill"
        case .lightbulb: return "lightbulb.fill"
        case .heart: return "heart.fill"
        case .clock: return "clock.fill"
        case .mapPin: return "mappin.and.ellipse"
        case .gift: return "gift.fill"
        case .trophy: return "trophy.fill"
        case .key: return "key.fill"
        case .flask: return "flask.fill"
        case .graduationCap: return "graduationcap.fill"
        case .speechBubble: return "bubble.left.fill"
        case .sparkle: return "sparkles"
        case .star: return "star.fill"
        case .bolt: return "bolt.fill"
        }
    }

    public static func defaultProp(forSlug slug: String) -> ClickyAgentProp {
        switch slug {
        case "research-buddy":
            return .magnifier
        case "shippy":
            return .hammer
        default:
            let allProps = ClickyAgentProp.allCases
            let stableHash = slug.unicodeScalars.reduce(0) { accumulator, scalar in
                (accumulator &* 31) &+ Int(scalar.value)
            }
            let index = abs(stableHash) % allProps.count
            return allProps[index]
        }
    }
}

public nonisolated struct ClickyProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String { slug }

    public let slug: String
    public var name: String
    public var roleText: String
    public var oneLiner: String
    public var baseHue: Double
    public var prop: ClickyAgentProp
    public let createdAt: Date
    public var introMessages: [String]
    public var suggestedAsks: [String]
    public var isArchived: Bool
    public let isStarterDefault: Bool

    public init(
        slug: String,
        name: String,
        roleText: String,
        oneLiner: String,
        baseHue: Double,
        prop: ClickyAgentProp,
        createdAt: Date = Date(),
        introMessages: [String] = [],
        suggestedAsks: [String] = [],
        isArchived: Bool = false,
        isStarterDefault: Bool = false
    ) {
        self.slug = slug
        self.name = name
        self.roleText = roleText
        self.oneLiner = oneLiner
        self.baseHue = baseHue
        self.prop = prop
        self.createdAt = createdAt
        self.introMessages = introMessages
        self.suggestedAsks = suggestedAsks
        self.isArchived = isArchived
        self.isStarterDefault = isStarterDefault
    }

    public var greeting: String {
        if let firstIntro = introMessages.first, !firstIntro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return firstIntro
        }
        return "Hey! I'm \(name), your \(roleText). What do you want to do?"
    }
}

public typealias CreatedClicky = ClickyRoster.StoredRoster.CreatedClicky

@MainActor
public final class ClickyRoster: ObservableObject {
    public nonisolated struct StoredRoster: Codable, Equatable, Sendable {
        public nonisolated struct CreatedClicky: Codable, Equatable, Identifiable, Sendable {
            public var id: String { slug }

            public let slug: String
            public var name: String
            public var roleText: String
            public var oneLiner: String
            public var baseHue: Double
            public var prop: ClickyAgentProp?
            public let createdAt: Date
            public var introMessages: [String]
            public var suggestedAsks: [String]
            public var firstAsksGeneratedAfterCreation: Bool

            enum CodingKeys: String, CodingKey {
                case slug
                case name
                case roleText
                case oneLiner
                case baseHue
                case prop
                case createdAt
                case introMessages
                case suggestedAsks
                case firstAsksGeneratedAfterCreation
            }

            public init(
                slug: String,
                name: String,
                roleText: String,
                oneLiner: String,
                baseHue: Double,
                prop: ClickyAgentProp? = nil,
                createdAt: Date = Date(),
                introMessages: [String] = [],
                suggestedAsks: [String] = [],
                firstAsksGeneratedAfterCreation: Bool = false
            ) {
                self.slug = slug
                self.name = name
                self.roleText = roleText
                self.oneLiner = oneLiner
                self.baseHue = baseHue
                self.prop = prop
                self.createdAt = createdAt
                self.introMessages = introMessages
                self.suggestedAsks = suggestedAsks
                self.firstAsksGeneratedAfterCreation = firstAsksGeneratedAfterCreation
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.slug = try container.decode(String.self, forKey: .slug)
                self.name = try container.decode(String.self, forKey: .name)
                self.roleText = try container.decode(String.self, forKey: .roleText)
                self.oneLiner = try container.decode(String.self, forKey: .oneLiner)
                self.baseHue = try container.decodeIfPresent(Double.self, forKey: .baseHue) ?? 0.55
                self.prop = try container.decodeIfPresent(ClickyAgentProp.self, forKey: .prop)
                self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
                self.introMessages = try container.decodeIfPresent([String].self, forKey: .introMessages) ?? []
                self.suggestedAsks = try container.decodeIfPresent([String].self, forKey: .suggestedAsks) ?? []
                self.firstAsksGeneratedAfterCreation = try container.decodeIfPresent(Bool.self, forKey: .firstAsksGeneratedAfterCreation) ?? false
            }
        }

        public nonisolated struct IdentityOverride: Codable, Equatable, Sendable {
            public var name: String?
            public var roleText: String?
            public var oneLiner: String?
            public var prop: ClickyAgentProp?

            public init(
                name: String? = nil,
                roleText: String? = nil,
                oneLiner: String? = nil,
                prop: ClickyAgentProp? = nil
            ) {
                self.name = name
                self.roleText = roleText
                self.oneLiner = oneLiner
                self.prop = prop
            }
        }

        public var overridesBySlug: [String: IdentityOverride]
        public var createdClickys: [CreatedClicky]
        public var archivedSlugs: [String]
        public var portraitAppearancesBySlug: [String: String]
        public var userCustomizedPortraitSlugs: [String]

        public init(
            overridesBySlug: [String: IdentityOverride] = [:],
            createdClickys: [CreatedClicky] = [],
            archivedSlugs: [String] = [],
            portraitAppearancesBySlug: [String: String] = [:],
            userCustomizedPortraitSlugs: [String] = []
        ) {
            self.overridesBySlug = overridesBySlug
            self.createdClickys = createdClickys
            self.archivedSlugs = archivedSlugs
            self.portraitAppearancesBySlug = portraitAppearancesBySlug
            self.userCustomizedPortraitSlugs = userCustomizedPortraitSlugs
        }
    }

    public static let shared = ClickyRoster()

    public static let rosterDefaultsKey = "clicky.roster.v1"
    public static let starterCastUnlockedDefaultsKey = "clicky.starterCast.unlockedByOnboarding.v1"
    public static let threadBindingsDefaultsKey = "clicky.starterAgents.threadBindings.v1"
    public static let lastSeenAtDefaultsKey = "clicky.starterAgents.lastSeenAt.v1"
    public static let manuallyUnreadDefaultsKey = "clicky.starterAgents.manuallyMarkedUnread.v1"
    public static let pinnedSlugsDefaultsKey = "clicky.starterAgents.pinnedSlugs.v1"

    public static let defaultStarterClickys: [ClickyProfile] = [
        ClickyProfile(
            slug: "research-buddy",
            name: "Research Buddy",
            roleText: "Researcher",
            oneLiner: "Digs into companies, markets, and competitors and hands you a tidy report.",
            baseHue: 0.58,
            prop: .magnifier,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            introMessages: [
                "Hey! I'm Research Buddy. Point me at a company, a market, or a competitor and I'll come back with a tidy report."
            ],
            suggestedAsks: [
                "Research my top three competitors and what they charge",
                "Find out who is winning in my space and why",
                "Put together a one page brief on this company"
            ],
            isArchived: false,
            isStarterDefault: true
        ),
        ClickyProfile(
            slug: "shippy",
            name: "Shippy",
            roleText: "Web builder",
            oneLiner: "Builds and ships websites and small web projects right on your Mac.",
            baseHue: 0.38,
            prop: .hammer,
            createdAt: Date(timeIntervalSince1970: 1_750_000_001),
            introMessages: [
                "Hey! I'm Shippy. Tell me what you want on the web and I'll build it and ship it, right here on your Mac."
            ],
            suggestedAsks: [
                "Build me a simple landing page for my idea",
                "Make a one page site with a waitlist form",
                "Ship a little web app that does one thing well"
            ],
            isArchived: false,
            isStarterDefault: true
        )
    ]

    private let defaults: UserDefaults
    private var storedRoster: StoredRoster

    @Published public private(set) var clickys: [ClickyProfile] = []
    @Published public private(set) var allClickys: [ClickyProfile] = []
    @Published public var isStarterCastUnlocked: Bool {
        didSet {
            defaults.set(isStarterCastUnlocked, forKey: Self.starterCastUnlockedDefaultsKey)
            rebuildResolvedRoster()
        }
    }
    @Published public private(set) var threadBindingsBySlug: [String: String] = [:]
    @Published public private(set) var lastSeenAtBySlug: [String: Date] = [:]
    @Published public private(set) var manuallyUnreadSlugs: Set<String> = []
    @Published public private(set) var threadOwnershipVersion: Int = 0
    @Published public private(set) var readStateVersion: Int = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storedRoster = Self.loadStoredRoster(from: defaults)
        self.isStarterCastUnlocked = defaults.object(forKey: Self.starterCastUnlockedDefaultsKey) as? Bool ?? true
        self.threadBindingsBySlug = defaults.dictionary(forKey: Self.threadBindingsDefaultsKey) as? [String: String] ?? [:]

        if let rawLastSeen = defaults.dictionary(forKey: Self.lastSeenAtDefaultsKey) as? [String: TimeInterval] {
            var restoredDates: [String: Date] = [:]
            for (slug, timestamp) in rawLastSeen {
                restoredDates[slug] = Date(timeIntervalSince1970: timestamp)
            }
            self.lastSeenAtBySlug = restoredDates
        }

        let unreadList = defaults.stringArray(forKey: Self.manuallyUnreadDefaultsKey) ?? []
        self.manuallyUnreadSlugs = Set(unreadList)

        rebuildResolvedRoster()
    }

    @discardableResult
    public func createClicky(
        name: String,
        roleText: String,
        oneLiner: String,
        baseHue: Double? = nil,
        prop: ClickyAgentProp? = nil,
        suggestedAsks: [String] = [],
        introMessages: [String] = [],
        slug: String? = nil,
        ensureWorkspace: Bool = true
    ) -> ClickyProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Clicky" : trimmedName
        let existingSlugs = Set(allClickys.map(\.slug))
        let resolvedSlug: String
        if let requestedSlug = slug?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedSlug.isEmpty,
           !existingSlugs.contains(requestedSlug) {
            resolvedSlug = Self.sanitizedSlug(from: requestedSlug, existingSlugs: existingSlugs)
        } else {
            resolvedSlug = Self.sanitizedSlug(from: resolvedName, existingSlugs: existingSlugs)
        }

        let resolvedHue = baseHue ?? Self.defaultHue(forSlug: resolvedSlug)
        let resolvedProp = prop ?? ClickyAgentProp.defaultProp(forSlug: resolvedSlug)
        let resolvedIntros = introMessages.isEmpty
            ? ["Hey! I'm \(resolvedName), your \(roleText). What do you want to do?"]
            : introMessages

        let created = StoredRoster.CreatedClicky(
            slug: resolvedSlug,
            name: resolvedName,
            roleText: roleText,
            oneLiner: oneLiner,
            baseHue: resolvedHue,
            prop: resolvedProp,
            createdAt: Date(),
            introMessages: resolvedIntros,
            suggestedAsks: suggestedAsks,
            firstAsksGeneratedAfterCreation: !suggestedAsks.isEmpty
        )

        storedRoster.createdClickys.removeAll { existing in existing.slug == resolvedSlug }
        storedRoster.createdClickys.append(created)
        storedRoster.archivedSlugs.removeAll { archivedSlug in archivedSlug == resolvedSlug }
        persistStoredRoster()
        rebuildResolvedRoster()

        let createdProfile = activeClicky(forSlug: resolvedSlug) ?? ClickyProfile(
            slug: resolvedSlug,
            name: resolvedName,
            roleText: roleText,
            oneLiner: oneLiner,
            baseHue: resolvedHue,
            prop: resolvedProp,
            createdAt: created.createdAt,
            introMessages: resolvedIntros,
            suggestedAsks: suggestedAsks,
            isArchived: false,
            isStarterDefault: false
        )

        if ensureWorkspace {
            ClickyWorkFolderFiles.shared.ensureClickyWorkspace(profile: createdProfile)
        }

        return createdProfile
    }

    public func archiveClicky(slug: String) {
        guard !storedRoster.archivedSlugs.contains(slug) else { return }
        storedRoster.archivedSlugs.append(slug)
        persistStoredRoster()
        rebuildResolvedRoster()
    }

    public func unarchiveClicky(slug: String) {
        guard storedRoster.archivedSlugs.contains(slug) else { return }
        storedRoster.archivedSlugs.removeAll { archivedSlug in archivedSlug == slug }
        persistStoredRoster()
        rebuildResolvedRoster()
    }

    public func activeClicky(forSlug slug: String) -> ClickyProfile? {
        clickys.first { profile in profile.slug == slug }
    }

    public func clicky(forSlug slug: String) -> ClickyProfile? {
        allClickys.first { profile in profile.slug == slug }
    }

    public func updateIdentity(
        slug: String,
        name: String? = nil,
        roleText: String? = nil,
        oneLiner: String? = nil,
        prop: ClickyAgentProp? = nil,
        suggestedAsks: [String]? = nil
    ) {
        if let createdIndex = storedRoster.createdClickys.firstIndex(where: { item in item.slug == slug }) {
            if let name { storedRoster.createdClickys[createdIndex].name = name }
            if let roleText { storedRoster.createdClickys[createdIndex].roleText = roleText }
            if let oneLiner { storedRoster.createdClickys[createdIndex].oneLiner = oneLiner }
            if let prop { storedRoster.createdClickys[createdIndex].prop = prop }
            if let suggestedAsks {
                storedRoster.createdClickys[createdIndex].suggestedAsks = suggestedAsks
                storedRoster.createdClickys[createdIndex].firstAsksGeneratedAfterCreation = !suggestedAsks.isEmpty
            }
        } else {
            var override = storedRoster.overridesBySlug[slug] ?? StoredRoster.IdentityOverride()
            if let name { override.name = name }
            if let roleText { override.roleText = roleText }
            if let oneLiner { override.oneLiner = oneLiner }
            if let prop { override.prop = prop }
            storedRoster.overridesBySlug[slug] = override
        }

        persistStoredRoster()
        rebuildResolvedRoster()
    }

    public func bindThread(_ threadID: String, toSlug slug: String) {
        threadBindingsBySlug[slug] = threadID
        defaults.set(threadBindingsBySlug, forKey: Self.threadBindingsDefaultsKey)
        threadOwnershipVersion &+= 1
    }

    public func unbindThread(forSlug slug: String) {
        guard threadBindingsBySlug.removeValue(forKey: slug) != nil else { return }
        defaults.set(threadBindingsBySlug, forKey: Self.threadBindingsDefaultsKey)
        threadOwnershipVersion &+= 1
    }

    public func slug(forThreadID threadID: String) -> String? {
        threadBindingsBySlug.first(where: { _, boundThreadID in boundThreadID == threadID })?.key
    }

    public func markRead(slug: String, at date: Date = Date()) {
        lastSeenAtBySlug[slug] = date
        manuallyUnreadSlugs.remove(slug)
        persistReadState()
    }

    public func markUnread(slug: String) {
        manuallyUnreadSlugs.insert(slug)
        persistReadState()
    }

    public func isUnread(slug: String, latestActivityAt: Date? = nil) -> Bool {
        if manuallyUnreadSlugs.contains(slug) {
            return true
        }
        guard let latestActivityAt else { return false }
        guard let lastSeenAt = lastSeenAtBySlug[slug] else { return true }
        return latestActivityAt > lastSeenAt
    }

    public func resetAllLocalClickys() {
        storedRoster = StoredRoster()
        threadBindingsBySlug = [:]
        lastSeenAtBySlug = [:]
        manuallyUnreadSlugs = []

        defaults.removeObject(forKey: Self.rosterDefaultsKey)
        defaults.removeObject(forKey: Self.threadBindingsDefaultsKey)
        defaults.removeObject(forKey: Self.lastSeenAtDefaultsKey)
        defaults.removeObject(forKey: Self.manuallyUnreadDefaultsKey)
        defaults.removeObject(forKey: Self.pinnedSlugsDefaultsKey)

        rebuildResolvedRoster()
        threadOwnershipVersion &+= 1
        readStateVersion &+= 1
    }

    public nonisolated static func sanitizedSlug(from rawName: String, existingSlugs: Set<String>) -> String {
        let lowercased = rawName.lowercased()
        var characters: [Character] = []
        var previousWasHyphen = false

        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                characters.append(Character(scalar))
                previousWasHyphen = false
            } else if !previousWasHyphen && !characters.isEmpty {
                characters.append("-")
                previousWasHyphen = true
            }
        }

        while characters.last == "-" {
            characters.removeLast()
        }

        let baseSlug = characters.isEmpty ? "clicky" : String(characters)
        if !existingSlugs.contains(baseSlug) {
            return baseSlug
        }

        var suffixNumber = 2
        while existingSlugs.contains("\(baseSlug)-\(suffixNumber)") {
            suffixNumber += 1
        }
        return "\(baseSlug)-\(suffixNumber)"
    }

    private nonisolated static func defaultHue(forSlug slug: String) -> Double {
        let hashValue = slug.unicodeScalars.reduce(0) { accumulator, scalar in
            (accumulator &* 33) &+ Int(scalar.value)
        }
        let normalized = Double(abs(hashValue) % 360) / 360.0
        return normalized
    }

    private static func loadStoredRoster(from defaults: UserDefaults) -> StoredRoster {
        guard let data = defaults.data(forKey: rosterDefaultsKey) else {
            return StoredRoster()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(StoredRoster.self, from: data) {
            return decoded
        }
        let fallbackDecoder = JSONDecoder()
        return (try? fallbackDecoder.decode(StoredRoster.self, from: data)) ?? StoredRoster()
    }

    private func persistStoredRoster() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let encoded = try? encoder.encode(storedRoster) {
            defaults.set(encoded, forKey: Self.rosterDefaultsKey)
        }
    }

    private func persistReadState() {
        var serializedDates: [String: TimeInterval] = [:]
        for (slug, date) in lastSeenAtBySlug {
            serializedDates[slug] = date.timeIntervalSince1970
        }
        defaults.set(serializedDates, forKey: Self.lastSeenAtDefaultsKey)
        defaults.set(Array(manuallyUnreadSlugs).sorted(), forKey: Self.manuallyUnreadDefaultsKey)
        readStateVersion &+= 1
    }

    private func rebuildResolvedRoster() {
        let archivedSet = Set(storedRoster.archivedSlugs)
        var resolved: [ClickyProfile] = []

        if isStarterCastUnlocked {
            for starter in Self.defaultStarterClickys {
                let override = storedRoster.overridesBySlug[starter.slug]
                let profile = ClickyProfile(
                    slug: starter.slug,
                    name: override?.name ?? starter.name,
                    roleText: override?.roleText ?? starter.roleText,
                    oneLiner: override?.oneLiner ?? starter.oneLiner,
                    baseHue: starter.baseHue,
                    prop: override?.prop ?? starter.prop,
                    createdAt: starter.createdAt,
                    introMessages: starter.introMessages,
                    suggestedAsks: starter.suggestedAsks,
                    isArchived: archivedSet.contains(starter.slug),
                    isStarterDefault: true
                )
                resolved.append(profile)
            }
        }

        for created in storedRoster.createdClickys {
            let override = storedRoster.overridesBySlug[created.slug]
            let resolvedProp = override?.prop ?? created.prop ?? ClickyAgentProp.defaultProp(forSlug: created.slug)
            let profile = ClickyProfile(
                slug: created.slug,
                name: override?.name ?? created.name,
                roleText: override?.roleText ?? created.roleText,
                oneLiner: override?.oneLiner ?? created.oneLiner,
                baseHue: created.baseHue,
                prop: resolvedProp,
                createdAt: created.createdAt,
                introMessages: created.introMessages,
                suggestedAsks: created.suggestedAsks,
                isArchived: archivedSet.contains(created.slug),
                isStarterDefault: false
            )
            resolved.append(profile)
        }

        self.allClickys = resolved
        self.clickys = resolved.filter { profile in !profile.isArchived }
    }
}
