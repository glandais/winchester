import Foundation

/// La vie d'un disque, rejouée jour après jour.
///
/// `DiskGenerator.generate` rejoue toute l'histoire d'un trait et ne rend que
/// l'arrivée. Ceci rejoue la même histoire — même compilateur, mêmes tirages,
/// même allocateur — mais une journée à la fois, et dit pour chaque événement
/// ce qu'il a fait au disque. On peut aussi sauter des journées sans les
/// raconter : c'est le même rejeu, sans le compte rendu.
///
/// Rien n'est gardé de ce qui a été joué : `dev-2007` compte 2,7 millions
/// d'événements, et qui écoute une journée n'a besoin que d'elle.
public final class HistoryReplay: @unchecked Sendable {

    public let spec: ProfileSpec
    /// Les étapes de l'installation du jour 0.
    public let installSteps: [InstallStep]
    /// Ce que le système de fichiers occupait avant le premier fichier.
    public let initialSystemExtents: [Extent]
    /// Jours couverts par l'histoire, jour 0 compris.
    public let dayCount: UInt32

    private let events: [TimedEvent]
    /// Un seul des deux existe. Deux optionnels plutôt qu'une énumération :
    /// sortir un simulateur d'un `case` pour le muter le recopie, bitmap et
    /// catalogue compris, à chaque événement ; `fat!.step` le mute en place.
    private var fat: Simulator<FATAllocator>?
    private var ntfs: Simulator<NTFSAllocator>?
    /// Premier événement pas encore confié au simulateur.
    private var cursor = 0
    /// Événements finis.
    private var played = 0
    public private(set) var failedWrites = 0

    public init(_ spec: ProfileSpec, manifests: [AppManifest] = AppLibrary.all) {
        let compiled = ScenarioCompiler.compile(spec, manifests: manifests)
        self.spec = spec
        self.installSteps = compiled.installSteps
        self.events = compiled.timeline.events
        self.dayCount = max(compiled.timeline.dayCount, spec.timeline.dayCount + 1)
        switch spec.fileSystem.type {
        case .fat16, .vfat, .fat32:
            let allocator = DiskGenerator.fatAllocator(for: spec)
            initialSystemExtents = allocator.metadataExtents
            fat = Simulator(allocator: allocator, catalog: compiled.catalog,
                            concurrent: DiskGenerator.runsProgramsConcurrently(spec),
                            directories: DiskGenerator.directoryFormat(for: spec))
        case .ntfs:
            let allocator = DiskGenerator.ntfsAllocator(for: spec)
            initialSystemExtents = allocator.metadataExtents
            ntfs = Simulator(allocator: allocator, catalog: compiled.catalog,
                             concurrent: DiskGenerator.runsProgramsConcurrently(spec),
                             directories: DiskGenerator.directoryFormat(for: spec))
        }
    }

    /// Le jour du prochain événement à rejouer, `nil` quand l'histoire est finie.
    public var nextDay: UInt32? {
        if let pending = simulatorPending { return pending.day }
        return cursor < events.count ? events[cursor].day : nil
    }

    public var isFinished: Bool { cursor >= events.count && !hasPending }

    /// Nombre d'événements de l'histoire, et combien sont déjà rejoués.
    public var eventCount: Int { events.count }
    public var playedEvents: Int { played }

    private var hasPending: Bool { fat?.hasPendingEvents ?? ntfs!.hasPendingEvents }
    /// Un événement de la tranche en cours, s'il en reste.
    private var simulatorPending: TimedEvent? {
        hasPending ? (fat?.nextPendingEvent ?? ntfs!.nextPendingEvent) : nil
    }

    /// Confie au simulateur la tranche suivante du jour `day`, s'il n'en a pas
    /// déjà une en cours.
    private func loadIfNeeded(day: UInt32) -> Bool {
        if hasPending { return true }
        guard cursor < events.count, events[cursor].day == day else { return false }
        if fat != nil { cursor = fat!.load(events, from: cursor) } else { cursor = ntfs!.load(events, from: cursor) }
        return true
    }

    /// Joue jusqu'au prochain événement fini de la tranche en cours.
    private func next(reporting: Bool) -> (timed: TimedEvent, step: SimulationStep?)? {
        let done = fat != nil ? fat!.next(reporting: reporting) : ntfs!.next(reporting: reporting)
        if done != nil { played += 1 }
        return done
    }

    /// Rejoue les événements du jour `day`, en racontant chacun.
    ///
    /// - Parameter body: reçoit l'événement et ce qu'il a changé ; rendre
    ///   `false` arrête le rejeu **avant** l'événement suivant, qui reste à
    ///   jouer.
    /// - Returns: `false` si `body` a interrompu la journée.
    ///
    /// Les événements sont racontés dans l'ordre où ils **finissent** : deux
    /// programmes qui écrivent en même temps (`Simulator.next`) peuvent finir
    /// dans l'autre ordre que celui où ils ont commencé.
    @discardableResult
    public func play(day: UInt32,
                     _ body: (TimedEvent, SimulationStep) throws -> Bool) rethrows -> Bool {
        while loadIfNeeded(day: day) {
            guard let done = next(reporting: true) else { continue }
            let step = done.step ?? SimulationStep()
            if step.failed { failedWrites += 1 }
            if try !body(done.timed, step) { return false }
        }
        return true
    }

    /// Les événements d'un jour, sans les jouer. Il doit être le jour courant.
    public func events(of day: UInt32) -> ArraySlice<TimedEvent> {
        precondition(!hasPending, "une tranche du jour est déjà en cours")
        var end = cursor
        while end < events.count, events[end].day == day { end += 1 }
        return events[cursor..<end]
    }

    /// Ce que le jour va écrire, tel que son histoire l'annonce : de quoi
    /// mesurer un avancement avant de l'avoir joué.
    public func writtenBytes(of day: UInt32) -> Int {
        var total = 0
        for timed in events(of: day) {
            switch timed.event {
            case let .create(file):
                total += Int(file.bytes)
            case let .replaceViaTemporary(_, bytes):
                total += Int(bytes)
            case let .append(id, bytes):
                total += max(Int(bytes) - Int(catalog[id]?.logicalSize ?? 0), 0)
            case let .rewrite(id):
                total += Int(catalog[id]?.logicalSize ?? 0)
            case .truncate, .delete, .defragment:
                break
            }
        }
        return total
    }

    /// L'événement suivant, sans le jouer.
    public var peek: TimedEvent? {
        simulatorPending ?? (cursor < events.count ? events[cursor] : nil)
    }

    /// Rejoue sans rien raconter jusqu'à la fin du jour `day` inclus.
    public func skip(through day: UInt32) {
        while let next = nextDay, next <= day {
            _ = loadIfNeeded(day: next)
            let before = fat?.failedWriteCount ?? ntfs!.failedWriteCount
            while self.next(reporting: false) != nil {}
            failedWrites += (fat?.failedWriteCount ?? ntfs!.failedWriteCount) - before
        }
    }

    // MARK: - L'état du disque

    public var catalog: FileCatalog { fat?.catalog ?? ntfs!.catalog }
    /// Ce que le système de fichiers occupe pour lui-même à cet instant : la
    /// MFT a pu grandir depuis le premier jour.
    public var systemExtents: [Extent] {
        fat?.allocator.metadataExtents ?? ntfs!.allocator.metadataExtents
    }
    public var bitmap: ClusterBitmap { fat?.allocator.bitmap ?? ntfs!.allocator.bitmap }

    /// Le disque tel qu'il est à cet instant de l'histoire. Les mesures sont
    /// recalculées sur tout le catalogue : à ne pas demander à chaque image.
    public func snapshot() -> GeneratedDisk {
        let days = nextDay ?? dayCount
        if let fat {
            return DiskGenerator.disk(spec: spec, simulator: fat, failedWrites: failedWrites, dayCount: days)
        }
        return DiskGenerator.disk(spec: spec, simulator: ntfs!, failedWrites: failedWrites, dayCount: days)
    }
}
