import Testing
@testable import DefragKit

/// La carte racontée par zones à VoiceOver.
@Suite("Carte par zones")
struct MapZoneTests {

    private static func shade(_ category: ClusterCategory, fill: Double = 1, contiguous: Bool = false) -> ClusterShade {
        ClusterShade(category: category.rawValue, fill: UInt8((fill * 255).rounded()), contiguous: contiguous)
    }

    @Test("Quatre zones dans l'ordre du volume, chacune dite en une phrase")
    func fourZones() {
        let shades = Array(repeating: Self.shade(.application, contiguous: true), count: 10)
            + Array(repeating: Self.shade(.document), count: 10)
            + Array(repeating: Self.shade(.free, fill: 0), count: 10)
            + Array(repeating: Self.shade(.swap), count: 5) + Array(repeating: Self.shade(.free, fill: 0), count: 5)
        let zones = MapZone.zones(of: shades)
        #expect(zones.map(\.name) == ["début du disque", "deuxième quart", "troisième quart", "fin du disque"])
        #expect(zones[0].description == "début du disque, 100\u{00A0}% occupé, surtout des applications rangées")
        #expect(zones[1].description == "deuxième quart, 100\u{00A0}% occupé, surtout des documents en morceaux")
        #expect(zones[2].description == "troisième quart, vide")
        #expect(zones[3].description == "fin du disque, 50\u{00A0}% occupé, surtout le fichier d'échange")
    }

    @Test("La catégorie qui pèse le plus l'emporte, au remplissage près")
    func dominantByWeight() {
        // Trois blocs de temporaires à moitié pleins pèsent moins que deux
        // blocs de système pleins.
        let shades = [Self.shade(.churn, fill: 0.5), Self.shade(.churn, fill: 0.5), Self.shade(.churn, fill: 0.5),
                      Self.shade(.system, contiguous: true), Self.shade(.system, contiguous: true)]
        let zone = MapZone.zones(of: shades, count: 1)[0]
        #expect(zone.dominant == .system)
        #expect(zone.dominantIsContiguous)
        #expect(abs(zone.occupied - 0.7) < 0.01)
        #expect(zone.description == "tout le disque, 70\u{00A0}% occupé, surtout du système rangé")
    }

    @Test("Une carte plus courte que les zones n'en invente pas")
    func tinyMap() {
        #expect(MapZone.zones(of: []).isEmpty)
        let zones = MapZone.zones(of: [Self.shade(.document), Self.shade(.free, fill: 0)])
        #expect(zones.count == 2)
        #expect(zones[1].description == "deuxième quart, vide")
    }

    @Test("Chaque catégorie se dit")
    func everyCategorySpeaks() {
        for category in ClusterCategory.allCases {
            #expect(!category.spokenContent(contiguous: true).isEmpty)
            #expect(!category.spokenContent(contiguous: false).isEmpty)
        }
    }
}
