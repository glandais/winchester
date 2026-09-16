import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Un fichier de test : sa catégorie, ses extents, et un nom — c'est le nom
/// qui fait d'un fichier un space hog.
private struct JKFile {
    let name: String
    let category: ClusterCategory
    let extents: [Extent]
}

/// Un volume dont on choisit le placement au cluster près.
private func jkVolume(clusterCount: Int, files: [JKFile], format: VolumeFormat = .fat16,
                      mftZone: Range<UInt32>? = nil,
                      systemExtents: [Extent] = []) -> DefragVolume {
    let partition = PartitionGeometry(startLBA: 0, clusterCount: clusterCount,
                                      clusterSectors: 8, format: format)
    let records = files.enumerated().map { position, file in
        DefragFile(id: UInt32(position), path: "\\\(file.name)", category: file.category,
                   walkOrder: position, extents: file.extents, isMovable: file.category != .swap)
    }
    return DefragVolume(partition: partition, files: records, mftZone: mftZone,
                        systemExtents: systemExtents)
}

/// Sans réserve d'espace libre, les zones se réduisent à ce qu'elles
/// contiennent : c'est ce qui permet de dérouler l'algorithme à la main.
private func jkRun(_ volume: DefragVolume,
                   _ configure: (inout JKDefragStrategy) -> Void = { _ in })
    -> (plan: DefragPlan, report: JKDefragStrategy.Report) {
    var strategy = JKDefragStrategy()
    strategy.freeSpacePercent = 0
    configure(&strategy)
    return strategy.run(volume: volume)
}

/// La première écriture de la passe : quel fichier, et où.
private func firstWrite(_ plan: DefragPlan) -> (start: Int, category: ClusterCategory)? {
    plan.mutations.first { $0.category != .free }.map { ($0.start, $0.category) }
}

/// Ce que JkDefrag fait d'un volume, et surtout **dans quel ordre** : c'est
/// l'ordre des déplacements, bien plus que leur nombre, qui distingue sa passe
/// des trois autres.
@Suite("Passe JkDefrag, mode 2")
struct JKDefragStrategyTests {

    /// Le trou de dix clusters, et au-dessus cinq fichiers de 9, 4, 6, 5 et 3.
    ///
    /// `FindHighestItem` prendrait le plus haut qui tient — celui de 3 clusters.
    /// `FindBestItem` descend depuis le fond et retient 3 puis 5 : il reste 2,
    /// rien ne tombe pile. Il rembobine sur 5, retient 5 puis 4 : reste 1.
    /// Il rembobine sur 6, retient 6, et 4 tombe pile. Il rend **6**, le
    /// premier de la combinaison — c'est lui qui part le premier dans le trou.
    private static func perfectFitVolume() -> DefragVolume {
        jkVolume(clusterCount: 100, files: [
            JKFile(name: "F0.DAT", category: .application, extents: [Extent(start: 0, length: 1)]),
            // trou de 10 : 1..<11
            JKFile(name: "B.DAT", category: .application, extents: [Extent(start: 11, length: 9)]),
            JKFile(name: "F1.DAT", category: .application, extents: [Extent(start: 20, length: 4)]),
            JKFile(name: "F2.DAT", category: .document, extents: [Extent(start: 30, length: 6)]),
            JKFile(name: "F3.DAT", category: .application, extents: [Extent(start: 40, length: 5)]),
            JKFile(name: "F4.DAT", category: .system, extents: [Extent(start: 50, length: 3)]),
        ])
    }

    @Test("Une combinaison exacte passe avant le fichier le plus haut")
    func perfectFitComesFirst() {
        let (plan, report) = jkRun(Self.perfectFitVolume())
        #expect(firstWrite(plan)?.start == 1)
        #expect(firstWrite(plan)?.category == .document, "c'est le fichier de 6 qui ouvre la combinaison")
        #expect(report.perfectFitsFound > 0)
        #expect(report.perfectFitsExhausted == 0)
        #expect(plan.evacuations == 0)
    }

    /// La borne de `FindBestItem` : l'original renonce au bout d'une
    /// demi-seconde, celle-ci au bout d'un nombre de visites. Sans budget, la
    /// recherche abandonne au premier rembobinage et c'est le fichier le plus
    /// haut qui tient qui part dans le trou.
    @Test("Sans budget de visites, c'est le plus haut qui tient qui comble le trou")
    func anExhaustedSearchFallsBackToHighestFit() {
        let (plan, report) = jkRun(Self.perfectFitVolume()) { $0.perfectFitVisits = 0 }
        #expect(firstWrite(plan)?.start == 1)
        #expect(firstWrite(plan)?.category == .system)
        #expect(report.perfectFitsExhausted > 0)
    }

    /// Trois zones : les répertoires, les fichiers ordinaires, les space hogs.
    /// Une archive posée en tête de volume est sous le début de sa zone —
    /// `Fixup` la renvoie derrière les fichiers ordinaires.
    @Test("Un space hog en tête de volume est renvoyé derrière les fichiers ordinaires")
    func spaceHogsGoToTheBack() {
        let (plan, report) = jkRun(jkVolume(clusterCount: 100, files: [
            JKFile(name: "SETUP.ZIP", category: .archive, extents: [Extent(start: 0, length: 10)]),
            JKFile(name: "A.DAT", category: .application, extents: [Extent(start: 10, length: 20)]),
            JKFile(name: "B.DAT", category: .application, extents: [Extent(start: 30, length: 20)]),
        ]))
        #expect(report.spaceHogs == 1)
        #expect(report.zones.spaceHogs == 40)
        #expect(report.moves[1] == 1, "c'est Fixup qui déplace l'archive")
        let archive = plan.mutations.first { $0.category == .archive }
        #expect((archive?.start ?? 0) >= 40)
        #expect(plan.filesMoved == 1)
    }

    /// Un fichier qu'aucun trou ne peut recevoir d'un tenant est recopié par
    /// tranches, chacune dans le plus grand trou du moment. Ici 12 clusters en
    /// trois morceaux de 4, et un seul trou de 10 : la première tranche
    /// emporte les deux premiers morceaux et la moitié du troisième.
    @Test("Faute de trou à sa taille, un fichier est recollé par tranches")
    func defragmentBySlices() {
        let files = [
            JKFile(name: "D.DAT", category: .document, extents: [
                Extent(start: 0, length: 4), Extent(start: 10, length: 4), Extent(start: 20, length: 4),
            ]),
            JKFile(name: "A.DAT", category: .application, extents: [Extent(start: 4, length: 6)]),
            JKFile(name: "B.DAT", category: .application, extents: [Extent(start: 14, length: 6)]),
            JKFile(name: "C.DAT", category: .application, extents: [Extent(start: 24, length: 16)]),
            JKFile(name: "E.DAT", category: .application, extents: [Extent(start: 50, length: 50)]),
        ]
        let (plan, report) = jkRun(jkVolume(clusterCount: 100, files: files))
        #expect(plan.before.fragments == 3)
        #expect(plan.after.fragments == 2, "trois morceaux devenus deux")
        #expect(report.moves[0] == 1)

        // Windows XP ne sait que recopier un fichier entier : il renonce.
        let xp = WindowsXPStrategy().plan(volume: jkVolume(clusterCount: 100, files: files))
        #expect(xp.after.fragments == 3)
    }

    /// La garde de `Defragment` : une tranche qui ne dépasse pas le morceau
    /// qu'elle emporterait ne recollerait rien, elle le couperait. Un trou de
    /// 3 clusters face à des morceaux de 4 : rien n'est tenté.
    @Test("Une tranche plus petite que le morceau qu'elle emporterait n'est pas tentée")
    func slicesNeverSplitAFragment() {
        let (plan, _) = jkRun(jkVolume(clusterCount: 100, files: [
            JKFile(name: "D.DAT", category: .document, extents: [
                Extent(start: 0, length: 4), Extent(start: 10, length: 4), Extent(start: 20, length: 4),
            ]),
            JKFile(name: "A.DAT", category: .application, extents: [Extent(start: 4, length: 6)]),
            JKFile(name: "B.DAT", category: .application, extents: [Extent(start: 14, length: 6)]),
            JKFile(name: "C.DAT", category: .application, extents: [Extent(start: 24, length: 73)]),
        ]))
        #expect(plan.filesMoved == 0)
        #expect(plan.operations.allSatisfy { $0.kind != .writeExtent })
    }

    /// `CalculateZones` : la réserve d'espace libre suit la zone des
    /// répertoires et celle des fichiers ordinaires, et la zone MFT compte
    /// comme de l'immobile là où elle commence.
    @Test("Les zones comptent la réserve d'espace libre et la zone MFT")
    func zonesCountReserveAndMftZone() {
        let volume = jkVolume(clusterCount: 1_000, files: [
            JKFile(name: "A.DAT", category: .application, extents: [Extent(start: 200, length: 100)]),
            JKFile(name: "B.CAB", category: .archive, extents: [Extent(start: 300, length: 50)]),
        ], format: .ntfs, mftZone: 5..<125)
        var strategy = JKDefragStrategy()
        strategy.freeSpacePercent = 1
        let report = strategy.run(volume: volume).report
        // Zone 0 : 120 clusters de zone MFT, plus 10 de réserve.
        #expect(report.zones.regular == 130)
        // Zone 1 : 100 clusters de fichiers ordinaires, plus 10 de réserve.
        #expect(report.zones.spaceHogs == 240)
        #expect(report.zones.end == 290)
    }

    /// Le piège de la comparaison stricte : une zone MFT qui commence
    /// **exactement** où finit la zone 0 est rangée dans la zone 1
    /// (`Start < ZoneEnd[0]`, `JkDefragLib.cpp:1984`). Elle ne pousse plus le
    /// début des fichiers ordinaires, mais celui des space hogs.
    @Test("Une zone MFT posée pile à la fin de la zone 0 compte dans la zone 1")
    func mftZoneOnTheBoundaryCountsInZoneOne() {
        let volume = jkVolume(clusterCount: 1_000, files: [
            JKFile(name: "A.DAT", category: .application, extents: [Extent(start: 200, length: 100)]),
            JKFile(name: "B.CAB", category: .archive, extents: [Extent(start: 300, length: 50)]),
        ], format: .ntfs, mftZone: 10..<130)
        var strategy = JKDefragStrategy()
        strategy.freeSpacePercent = 1
        let report = strategy.run(volume: volume).report
        #expect(report.zones.regular == 10)
        #expect(report.zones.spaceHogs == 240)
    }

    /// `MatchMask` : `*` et `?`, sans distinction de casse, sur le chemin
    /// complet — lettre de volume comprise.
    @Test("Les masques de space hogs se lisent comme ceux de JkDefrag")
    func spaceHogMasks() {
        #expect(JKDefragStrategy.matches(path: "\\WINDOWS\\Installer\\1a2b.msp",
                                         mask: "?:\\WINDOWS\\Installer\\*"))
        #expect(JKDefragStrategy.matches(path: "\\windows\\INSTALLER\\x", mask: "?:\\WINDOWS\\Installer\\*"))
        #expect(JKDefragStrategy.matches(path: "\\DOWNLOAD\\SETUP.ZIP", mask: "*.zip"))
        #expect(!JKDefragStrategy.matches(path: "\\DOWNLOAD\\SETUP.ZIPX", mask: "*.zip"))
        #expect(!JKDefragStrategy.matches(path: "\\WINDOWS\\SYSTEM\\A.DLL", mask: "*.zip"))

        let strategy = JKDefragStrategy()
        let clusterBytes = 4_096
        let limit = UInt32(strategy.spaceHogBytes / clusterBytes)
        let file = { (clusters: UInt32) in
            DefragFile(id: 0, path: "\\GAME\\DATA.PAK", category: .application, walkOrder: 0,
                       extents: [Extent(start: 0, length: clusters)], isMovable: true)
        }
        #expect(!strategy.isSpaceHog(file(limit), clusterBytes: clusterBytes))
        #expect(strategy.isSpaceHog(file(limit + 1), clusterBytes: clusterBytes))
    }

    /// Ce qu'aucune passe ne doit casser, sur un volume vieilli de deux ans :
    /// pas un cluster perdu ou dupliqué, rien dans la zone MFT, rien hors de la
    /// partition, et personne d'évacué.
    @Test("Une passe complète conserve le volume")
    func aFullPassPreservesTheVolume() {
        let partition = PartitionGeometry(startLBA: 0, sectors: 180_000_000 / 512,
                                          clusterSectors: 8, format: .fat16)
        let volume = VolumeFactory.agedWindows95(partition: partition, fill: 0.78).defragVolume()
        let (plan, report) = JKDefragStrategy().run(volume: volume)

        #expect(plan.before.fill == plan.after.fill, "des clusters se sont perdus ou dupliqués")
        #expect(plan.before.fileCount == plan.after.fileCount)
        #expect(plan.after.fragmentedFiles <= plan.before.fragmentedFiles)
        #expect(plan.evacuations == 0)
        #expect(plan.filesMoved > 0)
        #expect(report.perfectFitsExhausted == 0)

        let end = partition.lba(ofCluster: partition.clusterCount)
        for operation in plan.operations {
            #expect(operation.lba + operation.sectors <= end, "opération hors de la partition")
        }

        // Les écritures se suivent sans jamais recouvrir un occupant : chaque
        // cluster écrit est libre à cet instant.
        var occupied = [Bool](repeating: false, count: partition.clusterCount)
        for run in plan.initialRuns {
            for cluster in Int(run.start)..<Int(run.end) { occupied[cluster] = true }
        }
        // Les repeints d'un fichier recollé, portés par la validation, ne sont
        // pas des écritures : seules celles-ci ont à tomber sur du libre.
        for operation in plan.operations where operation.mutationCount > 0 && operation.kind == .writeExtent {
            let slice = plan.mutations[Int(operation.mutationStart)..<Int(operation.mutationStart + operation.mutationCount)]
            for mutation in slice where mutation.category != .free {
                for cluster in mutation.start..<(mutation.start + mutation.count) {
                    #expect(!occupied[cluster], "écriture sur un cluster occupé")
                    occupied[cluster] = true
                }
            }
            for mutation in slice where mutation.category == .free {
                for cluster in mutation.start..<(mutation.start + mutation.count) { occupied[cluster] = false }
            }
        }
    }

    /// Un volume NTFS dont la zone MFT est libre : aucun fichier n'y est posé,
    /// ni par `Defragment`, ni par `Fixup`, ni par `OptimizeVolume`.
    @Test("Aucune passe n'écrit dans la zone réservée à la MFT")
    func theMftZoneStaysEmpty() {
        var files: [JKFile] = []
        for index in 0..<40 {
            let base = 400 + UInt32(index) * 15
            files.append(JKFile(name: "F\(index).DAT", category: .document,
                                extents: [Extent(start: base, length: 4), Extent(start: base + 8, length: 4)]))
        }
        let (plan, _) = jkRun(jkVolume(clusterCount: 2_000, files: files, format: .ntfs,
                                       mftZone: 20..<380))
        #expect(plan.filesMoved > 0)
        for mutation in plan.mutations where mutation.category != .free {
            #expect(mutation.start >= 380 || mutation.start + mutation.count <= 20,
                    "un fichier a été écrit dans la zone MFT")
        }
    }

    /// Une MFT dont la zone a entièrement cédé n'est plus protégée que par la
    /// bitmap : ses clusters ne sont décrits par aucun fichier. Aucun outil ne
    /// doit y voir un trou — ici le seul trou du début du volume, là où les
    /// quatre passes aimeraient ranger.
    @Test("Aucun défragmenteur n'écrit sur la MFT")
    func nobodyWritesOverTheMft() {
        var files: [JKFile] = [
            JKFile(name: "BIG.DAT", category: .application, extents: [Extent(start: 100, length: 600)]),
        ]
        for index in 0..<20 {
            let base = 720 + UInt32(index) * 12
            files.append(JKFile(name: "F\(index).DAT", category: .document,
                                extents: [Extent(start: base, length: 3), Extent(start: base + 6, length: 3)]))
        }
        let mft = [Extent(start: 0, length: 1), Extent(start: 1, length: 60), Extent(start: 70, length: 20)]
        let volume = jkVolume(clusterCount: 1_000, files: files, format: .ntfs,
                              mftZone: 61..<61, systemExtents: mft)
        #expect(volume.bitmap.isFree(Extent(start: 61, length: 9)), "le trou entre deux morceaux de MFT reste un trou")

        for strategy in DefragPlanner.all {
            let plan = DefragPlanner.plan(volume: volume, using: strategy)
            for mutation in plan.mutations where mutation.category != .free {
                for extent in mft {
                    #expect(!(mutation.start < Int(extent.end) && mutation.start + mutation.count > Int(extent.start)),
                            "\(strategy.label) écrit sur la MFT")
                }
            }
        }
    }

    /// La bitmap tenait la MFT occupée, mais la carte ne lisait que les
    /// fichiers : l'écran montrait libres des clusters où personne n'a le
    /// droit d'écrire. Elle doit s'y voir au départ, et y être encore à la fin.
    @Test("La MFT se voit sur la carte, du début à la fin de la passe")
    func mftIsOnTheMap() {
        let files = (0..<20).map { index in
            JKFile(name: "F\(index).DAT", category: .document,
                   extents: [Extent(start: 200 + UInt32(index) * 12, length: 3),
                             Extent(start: 206 + UInt32(index) * 12, length: 3)])
        }
        let mft = [Extent(start: 0, length: 1), Extent(start: 1, length: 60), Extent(start: 70, length: 20)]
        let volume = jkVolume(clusterCount: 1_000, files: files, format: .ntfs,
                              mftZone: 61..<61, systemExtents: mft)
        let reserved = ClusterCategory.reserved.rawValue

        for strategy in DefragPlanner.all {
            let plan = DefragPlanner.plan(volume: volume, using: strategy)
            var map = [UInt8](repeating: ClusterCategory.free.rawValue, count: 1_000)
            for run in plan.initialRuns {
                for cluster in Int(run.start)..<Int(run.end) { map[cluster] = run.category }
            }
            #expect(map.filter { $0 == reserved }.count == 81, "\(strategy.label) : MFT absente au départ")
            for mutation in plan.mutations {
                for cluster in mutation.start..<min(mutation.start + mutation.count, map.count) {
                    map[cluster] = mutation.category.rawValue
                }
            }
            #expect(map.filter { $0 == reserved }.count == 81, "\(strategy.label) : MFT absente à la fin")
        }
    }

    /// JkDefrag est de 2008 : aucun disque de la galerie ne l'a connu, il ne
    /// s'obtient que sur demande.
    @Test("JkDefrag ne se choisit pas tout seul")
    func itIsNeverThePeriodTool() {
        #expect(DefragPlanner.strategy(for: .fat16).id == "windows95")
        #expect(DefragPlanner.strategy(for: .ntfs).id == "windowsXP")
        #expect(DefragPlanner.strategy(named: "jkDefrag")?.label == "JkDefrag 3.36")
    }
}
