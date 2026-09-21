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
        // Hors de l'app, `String(localized:)` ne trouve pas le catalogue dans
        // `Bundle.main` : ce sont les `defaultValue` anglais qui sortent, et
        // c'est bien la langue source qu'on vérifie ici.
        #expect(zones.map(\.name) == ["start of the disk", "second quarter", "third quarter", "end of the disk"])
        #expect(zones[0].description == "start of the disk, 100\u{00A0}% used, mostly tidy applications")
        #expect(zones[1].description == "second quarter, 100\u{00A0}% used, mostly documents in pieces")
        #expect(zones[2].description == "third quarter, empty")
        #expect(zones[3].description == "end of the disk, 50\u{00A0}% used, mostly the page file")
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
        #expect(zone.description == "the whole disk, 70\u{00A0}% used, mostly tidy system files")
    }

    @Test("Une carte plus courte que les zones n'en invente pas")
    func tinyMap() {
        #expect(MapZone.zones(of: []).isEmpty)
        let zones = MapZone.zones(of: [Self.shade(.document), Self.shade(.free, fill: 0)])
        #expect(zones.count == 2)
        #expect(zones[1].description == "second quarter, empty")
    }

    @Test("Chaque catégorie se dit")
    func everyCategorySpeaks() {
        for category in ClusterCategory.allCases {
            #expect(!category.spokenContent(contiguous: true).isEmpty)
            #expect(!category.spokenContent(contiguous: false).isEmpty)
        }
    }
}
