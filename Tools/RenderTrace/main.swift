import Foundation
import DiskCore
import AVFAudio

// Rendu hors-ligne de la trace complète dans un WAV.
//
//   ./Tools/build-render.sh
//   /tmp/rendertrace sortie.wav              # scénario de démarrage
//   SCENARIO=defrag /tmp/rendertrace out.wav # passe de défragmentation
//
// `SCENARIO` accepte aussi l'identifiant d'un profil de la galerie : le disque
// est alors généré, converti en volume FAT16, et sa passe rendue sur le
// matériel que décrit sa fiche. Préfixé de `boot:`, c'est le **démarrage** de
// ce disque qui est rendu — celui-là ne refuse aucun format. `STRATEGY` et
// `FULL_BLOCKS` choisissent le défragmenteur (voir `ScenarioRequest`).
//
//   SCENARIO=dev-1993 /tmp/rendertrace dev1993.wav
//   SCENARIO=boot:dev-1993 /tmp/rendertrace boot1993.wav
//
// Préfixé de `install:`, c'est l'**installation** du disque qui est rendue :
// le jour 0 de son histoire, rejoué sur un volume vierge.
//
//   SCENARIO=install:secretaire-1996 /tmp/rendertrace install1996.wav
//
// Préfixé de `day:` et suivi d'un numéro de jour, c'est une **journée d'usage**
// qui est rendue : démarrage, séances, arrêt, sur le disque tel qu'il est ce
// jour-là.
//
//   SCENARIO=day:dev-1996:120 /tmp/rendertrace jour120.wav
//
//   SPINDLE_GAIN=0 /tmp/rendertrace tete-seule.wav
//   TRANSIENT_GAIN=0 /tmp/rendertrace rotation-seule.wav
//
// Permet d'auditionner et de régler le synthé sans passer par le simulateur.
//
// La passe est rendue **au fil de l'eau**, comme l'application l'écoute : le
// son est mixé à mesure qu'elle se planifie, écrit sur disque dès qu'il est
// définitif, et rien d'autre qu'une fenêtre de quelques secondes ne reste en
// mémoire. C'est ce qui permet de rendre une passe de plusieurs heures.

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "winchester.wav"
let requested = ScenarioRequest.environment["SCENARIO"] ?? ""

// `life:<profil>` ne rend aucun son : il fait défiler la vie du disque et dit
// ce qu'elle laisse, journée par journée. C'est la vue d'ensemble dont une
// écoute ne donne qu'un jour.
if requested.hasPrefix("life:") {
    let id = String(requested.dropFirst(5))
    guard let spec = (try? ScenarioLibrary.loadAll())?.first(where: { $0.id == id }) else {
        FileHandle.standardError.write("profil inconnu : \(id)\n".data(using: .utf8)!)
        exit(1)
    }
    let started = Date()
    let life = DiskLife(spec: spec)
    var lines: [String] = []
    while !life.isFinished {
        for digest in life.advance(days: 30) {
            let notable = digest.landmark != nil
            guard notable || digest.day % 90 == 0 else { continue }
            lines.append(String(format: "  %5d  %@  %3d %% plein  %6d fichiers  %5d en morceaux  %6d Mo  %@%@",
                                Int(digest.day), digest.date as NSString,
                                Int(digest.fill * 100), digest.fileCount, digest.fragmentedFiles,
                                digest.bytesWritten / 1_000_000,
                                digest.activities.map(\.label).joined(separator: ", ") as NSString,
                                digest.landmark.map { "  ← \($0.label)" } ?? ""))
        }
    }
    FileHandle.standardError.write(("""
    profil        : \(spec.displayName)
    jours         : \(life.digests.count), \(life.landmarks.count) à écouter
    défilement    : \(String(format: "%.1f", Date().timeIntervalSince(started))) s

    """ + lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    exit(0)
}

// `disk:<profil>` ne rend aucun son non plus : il génère le volume et dit ce
// qu'il contient — l'histogramme du nombre d'extents par fichier, dans les
// colonnes de `FILESYSTEM_EXPERT_REVIEW.md` §2, les répertoires, et ce que la
// génération a coûté. La durée est la meilleure de `GEN_REPEAT` générations
// (trois par défaut) : c'est elle que paie l'ouverture de l'application.
if requested.hasPrefix("disk:") {
    let id = String(requested.dropFirst(5))
    guard let spec = (try? ScenarioLibrary.loadAll())?.first(where: { $0.id == id }) else {
        FileHandle.standardError.write("profil inconnu : \(id)\n".data(using: .utf8)!)
        exit(1)
    }
    let repeats = max(Int(ScenarioRequest.environment["GEN_REPEAT"] ?? "") ?? 3, 1)
    var best = Double.infinity
    var generated: GeneratedDisk?
    for _ in 0..<repeats {
        let started = Date()
        generated = try DiskGenerator.generate(spec)
        best = min(best, Date().timeIntervalSince(started))
    }
    FileHandle.standardError.write(describeDisk(generated!, generation: best).data(using: .utf8)!)
    exit(0)
}

let request = try ScenarioRequest.request()
let scenario = request.scenario

// Une passe sur un volume d'époque réellement dimensionné dure des heures, et
// son rendu pèse des gigaoctets. `PLAN_ONLY` s'arrête au bilan : c'est tout ce
// qu'il faut pour vérifier un planificateur.
let planOnly = ScenarioRequest.environment["PLAN_ONLY"] != nil
let spindleGain = Float(ScenarioRequest.environment["SPINDLE_GAIN"] ?? "") ?? 0.20
let transientGain = Float(ScenarioRequest.environment["TRANSIENT_GAIN"] ?? "") ?? 1.0

let tally = Tally()
let rawPath = outputPath + ".raw"
let mixer = planOnly ? nil : StreamingMixer(character: scenario.setup.character, rawPath: rawPath,
                                            spindleGain: spindleGain, transientGain: transientGain)

guard let end = scenario.produce(batchRequests: 4_096, batchSeconds: 5, deliver: { batch in
    tally.consume(batch)
    mixer?.consume(batch)
}) else { exit(1) }
mixer?.close()

let geometry = scenario.geometry
let spans = scenario.spans(of: end)
let throughput = tally.throughput(duration: end.duration)

FileHandle.standardError.write("""
scénario      : \(scenario.label.title) — \(geometry.model)
requêtes      : \(end.requestCount)
seeks         : \(end.stats.seekCount) (moy. \(end.stats.averageSeekDistance) cyl.)
\(end.stats.recalibrations > 0 ? String(format: "recalibrations : %d, %.1f s d'attente\n", end.stats.recalibrations, end.stats.recalibrationSeconds) : "")lu / écrit    : \(end.stats.bytesRead / 1_000_000) / \(end.stats.bytesWritten / 1_000_000) Mo
\(scenario.setup.drive.buffer == nil ? "" : String(format: "tampon        : %d lectures servies, %.1f Mo lus d'avance ; %d écritures différées, posées en %d vidages\n", end.stats.bufferHits, Double(end.stats.readAheadSectors * DriveGeometry.bytesPerSector) / 1_000_000, end.stats.cachedWrites, end.stats.destageWrites))événements    : \(end.eventCount)
repères audio : \(tally.cues)
durée         : \(String(format: "%.1f", end.duration)) s
\(end.plan.map(describe) ?? "")
\(scenario.boot.map { describe($0, duration: end.duration) } ?? "")
\(ScenarioRequest.rangingPlan.map { "rangé par la passe :\n" + describe($0) } ?? "")
\(scenario.install.flatMap { playback in request.installed.map { describe(playback, installed: $0, geometry: geometry, duration: end.duration) } } ?? "")
\(scenario.dayPlayback.map { describe($0, stats: end.stats, duration: end.duration) } ?? "")
\(describePhases(spans, throughput: throughput))

""".data(using: .utf8)!)

// La ventilation du temps de la passe, pour qui cherche où il passe.
if ScenarioRequest.environment["STATS"] != nil {
    let s = end.stats
    FileHandle.standardError.write(String(format: """
    temps         : seek %.2f s, latence %.2f s, transfert %.2f s, pas de piste %.2f s, \
    calcul %.2f s, attente %.2f s, tampon %.2f s, lecture anticipée %.2f s

    """, s.seekSeconds, s.rotationSeconds, s.busySeconds, s.stepSeconds,
         s.thinkSeconds, s.waitSeconds, s.bufferSeconds, s.readAheadSeconds).data(using: .utf8)!)
}

guard let mixer else { exit(0) }

let frameCount = Int(end.duration * sampleRate) + 48_000

let rawFile = FileHandle(forReadingAtPath: rawPath)!
for span in spans {
    report(span.label, Int(span.start * sampleRate)..<Int(span.end * sampleRate),
           from: rawFile, frameCount: frameCount)
}

let normalize: Float = mixer.peak > 0.99 ? 0.99 / mixer.peak : 1
if normalize < 1 {
    FileHandle.standardError.write("écrêtage évité, gain \(normalize)\n".data(using: .utf8)!)
}

try writeWAV(to: outputPath, from: rawFile, frameCount: frameCount, gain: normalize)
try? rawFile.close()
try? FileManager.default.removeItem(atPath: rawPath)

FileHandle.standardError.write("\nécrit : \(outputPath)\n".data(using: .utf8)!)
