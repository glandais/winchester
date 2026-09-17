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
    private var cursor = 0
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
            fat = Simulator(allocator: allocator, catalog: compiled.catalog)
        case .ntfs:
            let allocator = DiskGenerator.ntfsAllocator(for: spec)
            initialSystemExtents = allocator.metadataExtents
            ntfs = Simulator(allocator: allocator, catalog: compiled.catalog)
        }
    }

    /// Le jour du prochain événement à rejouer, `nil` quand l'histoire est finie.
    public var nextDay: UInt32? {
        cursor < events.count ? events[cursor].day : nil
    }

    public var isFinished: Bool { cursor >= events.count }

    /// Nombre d'événements de l'histoire, et combien sont déjà rejoués.
    public var eventCount: Int { events.count }
    public var playedEvents: Int { cursor }

    /// Rejoue les événements du jour `day`, en racontant chacun.
    ///
    /// - Parameter body: reçoit l'événement et ce qu'il a changé ; rendre
    ///   `false` arrête le rejeu **avant** l'événement suivant, qui reste à
    ///   jouer.
    /// - Returns: `false` si `body` a interrompu la journée.
    @discardableResult
    public func play(day: UInt32,
                     _ body: (TimedEvent, SimulationStep) throws -> Bool) rethrows -> Bool {
        while cursor < events.count, events[cursor].day == day {
            let timed = events[cursor]
            cursor += 1
            let step = fat != nil ? fat!.step(timed) : ntfs!.step(timed)
            if step.failed { failedWrites += 1 }
            if try !body(timed, step) { return false }
        }
        return true
    }

    /// L'événement suivant, sans le jouer.
    public var peek: TimedEvent? {
        cursor < events.count ? events[cursor] : nil
    }

    /// Rejoue sans rien raconter jusqu'à la fin du jour `day` inclus.
    public func skip(through day: UInt32) {
        while cursor < events.count, events[cursor].day <= day {
            let failed = fat != nil ? fat!.replay(events[cursor]) : ntfs!.replay(events[cursor])
            if failed { failedWrites += 1 }
            cursor += 1
        }
    }

    // MARK: - L'état du disque

    public var catalog: FileCatalog { fat?.catalog ?? ntfs!.catalog }
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
