import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Le *track skew*, et ce qu'il garantit : une lecture contiguë ne paie qu'une
/// latence, celle du début.
///
/// C'est la propriété qui définit un disque bien formaté, et c'est celle que le
/// modèle violait : la latence rotationnelle supposait le secteur 0 au même
/// angle sur toutes les pistes, tandis que le franchissement de piste, vingt
/// lignes plus bas, supposait l'inverse — un décalage angulaire parfait. Les
/// deux hypothèses se contredisaient, et l'arrondi flottant sur la somme des
/// durées faisait en plus perdre **un tour entier** au milieu d'une lecture
/// strictement contiguë, environ une fois sur trois.
///
/// Un Barracuda ATA IV y lisait un fichier contigu à 12,2 Mo/s en requêtes de
/// 64 Ko, contre 34,3 d'un seul bloc — quatre fois moins que la réalité, et
/// moins qu'un disque de 1998.
@Suite("Skew de piste")
struct TrackSkewTests {

    /// Le disque du catalogue le plus exigeant sur ce point : 7 200 tr/min, et
    /// des requêtes de démarrage de 64 Ko.
    private static func barracuda() -> (DriveGeometry, SeekModel) {
        let geometry = DriveGeometry.era(model: "Barracuda ATA IV",
                                         capacityBytes: 40_000_000_000,
                                         rpm: 7_200, year: 2001)
        let seek = SeekModel.calibrated(averageSeekMs: 8.9, trackToTrackMs: 0.95,
                                        cylinders: geometry.cylinders)
        return (geometry, seek)
    }

    private static func elapsed(_ geometry: DriveGeometry, _ seek: SeekModel,
                                drive: DriveInterface = .direct,
                                requests: [BlockRequest]) -> Double {
        var mechanics = DiskMechanics(geometry: geometry, seekModel: seek,
                                      spinUpAt: 0, spinUpDuration: 0, drive: drive)
        var events: [DiskEvent] = []
        var first = 0.0
        var last = 0.0
        for (index, request) in requests.enumerated() {
            let timing = mechanics.serve(request, events: &events).timing
            if index == 0 { first = timing.start }
            last = timing.end
        }
        return last - first
    }

    /// *N* requêtes contiguës doivent coûter exactement ce que coûte une
    /// requête de *N* fois la taille, à la latence initiale près — qui est la
    /// même des deux côtés, puisque les deux partent du même LBA au même
    /// instant.
    ///
    /// Ce test échouait d'un facteur 3.
    @Test("Découper une lecture contiguë ne coûte rien",
          arguments: [8, 16, 64, 128])
    func splittingAContiguousReadIsFree(chunks: Int) {
        let (geometry, seek) = Self.barracuda()
        let start = geometry.lba(ofFraction: 0.1)
        let sectorsPerChunk = 128          // 64 Ko

        let split = (0..<chunks).map { index in
            BlockRequest(issueTime: 0, lba: start + index * sectorsPerChunk,
                         sectorCount: sectorsPerChunk, isWrite: false, phaseIndex: 0)
        }
        let whole = [BlockRequest(issueTime: 0, lba: start,
                                  sectorCount: chunks * sectorsPerChunk,
                                  isWrite: false, phaseIndex: 0)]

        let cut = Self.elapsed(geometry, seek, requests: split)
        let single = Self.elapsed(geometry, seek, requests: whole)
        #expect(abs(cut - single) < 1e-9,
                "\(chunks) requêtes de 64 Ko : \(cut) s contre \(single) s d'un bloc")
    }

    /// La même propriété, sur le disque qu'on écoute.
    ///
    /// Le test précédent la vérifie sans tampon, sur une mécanique qui ne coûte
    /// rien entre deux commandes. Aucun scénario ne sert plus ce disque-là : tous
    /// passent `.era(year:)`, et chaque commande y coûte 0,2 ms. Ce coût fait
    /// manquer à la requête suivante le secteur qui passe ; c'est la **lecture
    /// anticipée** qui le rend — la tête a continué de lire pendant que l'hôte
    /// envoyait la commande, et la requête est servie par le tampon à mesure que
    /// les secteurs arrivent. Découper une lecture contiguë ne coûte alors
    /// **rien**, commandes comprises : elles se paient pendant que la tête lit.
    @Test("Avec le tampon d'époque, découper une lecture contiguë ne coûte rien",
          arguments: [8, 16, 64, 128])
    func splittingIsFreeWithTheEraDrive(chunks: Int) {
        let (geometry, seek) = Self.barracuda()
        let drive = DriveInterface.era(year: 2001)
        #expect(drive.readAhead && drive.commandOverhead > 0)
        let (cut, single) = Self.splitAndWhole(geometry, seek, drive: drive, chunks: chunks)
        #expect(abs(cut - single) < 1e-9,
                "\(chunks) requêtes de 64 Ko : \(cut) s contre \(single) s d'un bloc")
    }

    /// Et sans la lecture anticipée, le même disque paie davantage que ses
    /// commandes : le secteur manqué, attendu une fraction de tour — de 1,4 à
    /// 2,2 ms par requête, quand la commande en coûte 0,2, la lecture sans
    /// latence en rattrapant une part. C'est ce qui donne son sens au test
    /// précédent : il échouerait si la lecture anticipée cessait de couvrir la
    /// commande.
    @Test("Sans lecture anticipée, chaque requête contiguë attend son secteur",
          arguments: [8, 16, 64, 128])
    func withoutReadAheadEachRequestWaits(chunks: Int) {
        let (geometry, seek) = Self.barracuda()
        let drive = DriveInterface.era(year: 2001).with(readAhead: false)
        let (cut, single) = Self.splitAndWhole(geometry, seek, drive: drive, chunks: chunks)
        let perRequest = (cut - single) / Double(chunks - 1)
        #expect(perRequest > 5 * drive.commandOverhead,
                "\(chunks) requêtes : \(perRequest * 1_000) ms de plus par requête")
    }

    /// *N* requêtes de 64 Ko contiguës, et la requête unique de même taille,
    /// sur un disque neuf de chaque côté.
    private static func splitAndWhole(_ geometry: DriveGeometry, _ seek: SeekModel,
                                      drive: DriveInterface, chunks: Int) -> (Double, Double) {
        let start = geometry.lba(ofFraction: 0.1)
        let sectorsPerChunk = 128
        let split = (0..<chunks).map { index in
            BlockRequest(issueTime: 0, lba: start + index * sectorsPerChunk,
                         sectorCount: sectorsPerChunk, isWrite: false, phaseIndex: 0)
        }
        let whole = [BlockRequest(issueTime: 0, lba: start,
                                  sectorCount: chunks * sectorsPerChunk,
                                  isWrite: false, phaseIndex: 0)]
        return (elapsed(geometry, seek, drive: drive, requests: split),
                elapsed(geometry, seek, drive: drive, requests: whole))
    }

    /// Et le débit obtenu est celui de la piste, pas un tiers de celle-ci.
    @Test("Une lecture contiguë de 4 Mo tient le débit de sa zone")
    func contiguousReadHoldsTrackThroughput() {
        let (geometry, seek) = Self.barracuda()
        let start = geometry.lba(ofFraction: 0.1)
        let sectors = 8 * 1_024            // 4 Mo

        let requests = stride(from: 0, to: sectors, by: 128).map { offset in
            BlockRequest(issueTime: 0, lba: start + offset, sectorCount: 128,
                         isWrite: false, phaseIndex: 0)
        }
        let elapsed = Self.elapsed(geometry, seek, requests: requests)
        let bytes = Double(sectors * DriveGeometry.bytesPerSector)
        let achieved = bytes / elapsed / 1_000_000

        let cylinder = geometry.position(ofLBA: start).cylinder
        let sustained = geometry.sustainedMBs(cylinder: cylinder)
        // Le franchissement de piste reste payé — c'est un vrai coût mécanique,
        // et c'est tout ce qui doit séparer le débit obtenu du débit de piste.
        #expect(achieved > sustained * 0.75,
                "\(achieved) Mo/s pour une piste à \(sustained) Mo/s")
        print(String(format: "  4 Mo en requêtes de 64 Ko : %.1f Mo/s, piste à %.1f Mo/s", achieved, sustained))
    }

    /// `AccessCost` est le second consommateur du modèle de coût, et il ne
    /// facture aucune attente rotationnelle au franchissement de piste. C'était,
    /// jusqu'ici, une hypothèse muette et contraire à celle de `DiskMechanics` ;
    /// depuis le skew, c'est la même, et ce test est là pour que les deux ne
    /// divergent plus en silence.
    @Test("Les deux modèles de coût facturent le même transfert")
    func bothCostModelsAgree() {
        let (geometry, seek) = Self.barracuda()
        let cost = AccessCost(geometry: geometry, seekModel: seek,
                              addressing: ClusterAddressing(dataStartLBA: 0, sectorsPerCluster: 8))

        for fraction in [0.01, 0.3, 0.7, 0.95] {
            let start = geometry.lba(ofFraction: fraction)
            let sectors = 4 * 1_024

            // `DiskMechanics`, latence initiale déduite : elle est le seul poste
            // que `transferTime` ne décrit pas.
            var mechanics = DiskMechanics(geometry: geometry, seekModel: seek,
                                          spinUpAt: 0, spinUpDuration: 0)
            var events: [DiskEvent] = []
            let request = BlockRequest(issueTime: 0, lba: start, sectorCount: sectors,
                                       isWrite: false, phaseIndex: 0)
            let timing = mechanics.serve(request, events: &events).timing
            let transferred = timing.end - timing.start
                - mechanics.stats.seekSeconds - mechanics.stats.rotationSeconds

            let reference = cost.transferTime(startLBA: start, sectors: sectors)
            #expect(abs(transferred - reference) < 1e-9,
                    "à \(fraction) : \(transferred) s contre \(reference) s")
        }
    }

    /// Le skew n'est pas un correctif d'arrondi déguisé : il vaut exactement ce
    /// que coûte le franchissement qu'il compense, et c'est ainsi que ces
    /// disques étaient formatés.
    @Test("Le skew vaut le franchissement qu'il compense")
    func skewMatchesTheCrossingItPaysFor() {
        let (geometry, seek) = Self.barracuda()
        let skew = geometry.skew(seekModel: seek)
        let revolution = geometry.revolutionDuration

        #expect(abs(skew.track * revolution - seek.duration(distance: 1)) < 1e-12)
        #expect(abs(skew.head * revolution - seek.headSwitchDuration) < 1e-12)

        // Continuité d'une tête à l'autre, puis d'un cylindre au suivant : dans
        // les deux cas, l'angle gagné est exactement celui que le plateau
        // parcourt pendant le franchissement.
        let head0 = DriveGeometry.Position(cylinder: 100, head: 0, sector: 0)
        let head1 = DriveGeometry.Position(cylinder: 100, head: 1, sector: 0)
        let next = DriveGeometry.Position(cylinder: 101, head: 0, sector: 0)
        func gap(_ a: DriveGeometry.Position, _ b: DriveGeometry.Position) -> Double {
            let d = geometry.angleOf(b, skew: skew) - geometry.angleOf(a, skew: skew)
            return d - d.rounded(.down)
        }
        #expect(abs(gap(head0, head1) - skew.head) < 1e-9)

        let last = DriveGeometry.Position(cylinder: 100, head: geometry.heads - 1, sector: 0)
        #expect(abs(gap(last, next) - skew.track) < 1e-9)
    }
}
