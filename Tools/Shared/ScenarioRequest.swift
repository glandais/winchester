import Foundation
import DiskCore

/// Fréquence d'échantillonnage des rendus hors-ligne.
let sampleRate = 48_000.0

/// Le scénario que demandent les variables d'environnement, commun à
/// `RenderTrace` et à `RenderVideo`.
///
/// `SCENARIO` accepte l'identifiant d'une démo (`windowsBoot`, `defrag`) — dont
/// le disque est un profil de la galerie, généré comme les autres, avec l'outil
/// que la démo a choisi —, celui d'un profil de la galerie — le disque est alors
/// généré, et sa passe de défragmentation rendue sur le matériel que décrit sa
/// fiche — ou, préfixé de `boot:`, le **démarrage** de ce disque, qui ne refuse
/// aucun format.
///
/// `STRATEGY` force le défragmenteur simulé au lieu de laisser le format le
/// dater. C'est ainsi que se compare une passe UltraDefrag à celle de l'outil
/// d'époque sur exactement le même volume :
///
///     PLAN_ONLY=1 STRATEGY=ultraDefrag SCENARIO=famille-2007 /tmp/rendertrace /dev/null
///
/// Préfixé de `install:`, c'est l'**installation** du disque qui est rendue —
/// le jour 0 de son histoire, rejoué sur un volume vierge ; préfixé de `day:` et
/// suivi d'un numéro de jour, c'est une **journée d'usage** sur le disque tel
/// qu'il est ce jour-là.
///
///     SCENARIO=install:secretaire-1996 /tmp/rendertrace install1996.wav
///     SCENARIO=day:dev-1996:120 /tmp/rendertrace jour120.wav
///
/// `FULL_BLOCKS=1` lui fait déplacer par blocs pleins, comme le recollage
/// économe : XP, UltraDefrag et JkDefrag seulement.
///
/// `boot:` avec une `STRATEGY`, c'est le démarrage du disque **tel que cette
/// passe le laisse** — ce que fait l'app quand on démarre un disque rangé. La
/// passe est planifiée sans être simulée, et son bilan suit celui du
/// démarrage :
///
///     PLAN_ONLY=1 STRATEGY=smart SCENARIO=boot:dev-1999 /tmp/rendertrace /dev/null
enum ScenarioRequest {

    /// Ce qu'une demande produit : le scénario, et le disque installé quand
    /// c'est une installation — son bilan le réclame.
    struct Request {
        let scenario: Scenario
        var installed: InstalledDisk?
    }

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var fullBlocks: Bool { environment["FULL_BLOCKS"] != nil }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }

    static func strategy() -> (any DefragStrategy)? {
        guard let strategyID = environment["STRATEGY"] else { return nil }
        guard let found = DefragPlanner.strategy(named: strategyID) else {
            fail("stratégie inconnue : \(strategyID)\nconnues : \(DefragPlanner.all.map(\.id).joined(separator: ", "))")
        }
        guard fullBlocks else { return found }
        guard let full = DefragPlanner.withFullBlocks(found) else {
            fail("FULL_BLOCKS : \(strategyID) n'a pas l'option (windowsXP, ultraDefrag, jkDefrag…)")
        }
        return full
    }

    static func request() throws -> Request {
        let requested = environment["SCENARIO"] ?? ""
        let wantsBoot = requested.hasPrefix("boot:")
        let wantsInstall = requested.hasPrefix("install:")
        let wantsDay = requested.hasPrefix("day:")
        // `day:<profil>:<jour>`
        let dayParts = wantsDay ? requested.dropFirst(4).split(separator: ":", maxSplits: 1) : []
        let requestedDay = UInt32(dayParts.count > 1 ? String(dayParts[1]) : "") ?? 1
        let profileID = wantsBoot ? String(requested.dropFirst(5))
            : wantsInstall ? String(requested.dropFirst(8))
            : wantsDay ? String(dayParts.first ?? "")
            : requested

        if let kind = ScenarioKind(rawValue: requested) {
            return Request(scenario: try demo(kind))
        }
        guard let spec = (try? ScenarioLibrary.loadAll())?.first(where: { $0.id == profileID }) else {
            if requested.isEmpty { return Request(scenario: try demo(.windowsBoot)) }
            let known = ScenarioKind.allCases.map(\.rawValue) + ScenarioLibrary.identifiers
                + ScenarioLibrary.identifiers.map { "boot:\($0)" }
                + ScenarioLibrary.identifiers.map { "install:\($0)" }
                + ["day:<profil>:<jour>"]
            fail("scénario inconnu : \(requested)\nconnus : \(known.joined(separator: ", "))")
        }

        FileHandle.standardError.write("génération de \(spec.id)…\n".data(using: .utf8)!)
        if wantsDay {
            FileHandle.standardError.write("rejeu jusqu'au jour \(requestedDay)…\n".data(using: .utf8)!)
            let replay = HistoryReplay(spec)
            if requestedDay > 0 { replay.skip(through: requestedDay - 1) }
            return Request(scenario: try ScenarioBuilder.build(day: requestedDay, replay: replay))
        }
        if wantsInstall {
            let install = try DiskGenerator.install(spec)
            return Request(scenario: ScenarioBuilder.build(install: install), installed: install)
        }
        let disk = try DiskGenerator.generate(spec)
        if wantsBoot, let tool = strategy() {
            return try rangedBoot(disk, by: tool)
        }
        let scenario = wantsBoot
            ? ScenarioBuilder.build(boot: disk)
            : try ScenarioBuilder.build(generated: disk, using: strategy())
        return Request(scenario: scenario)
    }

    /// Le bilan de la dernière passe planifiée pour un démarrage rangé.
    nonisolated(unsafe) static var rangingPlan: DefragPlan?

    /// `boot:<profil>` avec une `STRATEGY` : le démarrage du disque que cette
    /// passe laisse — ce que fait l'app quand on démarre un disque rangé. La
    /// passe est planifiée sans être simulée ; seul le démarrage est rendu.
    private static func rangedBoot(_ disk: GeneratedDisk, by tool: any DefragStrategy) throws -> Request {
        let volume = try GeneratedVolumeBridge.volume(from: disk)
        let prepared = ScenarioBuilder.prepared(tool, for: disk)
        let plan = prepared.plan(volume: volume, into: OperationSink { _, _, _, _ in })
        rangingPlan = plan
        let places = Dictionary(plan.arrangement.map { ($0.id, $0.extents) },
                                uniquingKeysWith: { _, last in last })
        let ranged = disk.rearranged(extents: places)
        return Request(scenario: ScenarioBuilder.build(boot: ranged, rangedBy: tool.label))
    }

    /// Une démo : son disque du catalogue est généré ici comme n'importe quel
    /// profil de la galerie, puisque c'en est un.
    private static func demo(_ kind: ScenarioKind) throws -> Scenario {
        FileHandle.standardError.write("génération de \(kind.profileID)…\n".data(using: .utf8)!)
        return try ScenarioBuilder.build(kind, disk: ScenarioBuilder.disk(of: kind))
    }

    static func scenario() throws -> Scenario { try request().scenario }
}
