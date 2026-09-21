import Foundation
import MediaPlayer
import Combine

/// La passe sur l'écran verrouillé et dans le centre de contrôle : son titre,
/// l'outil, le temps écouté, et lecture/pause.
///
/// Pas de durée totale — elle n'existe pas avant la fin — ni de saut : le
/// centre de contrôle n'offre que ce que le transport de l'app offre déjà.
/// L'information n'est publiée qu'aux changements d'état ; entre deux, le
/// système fait avancer le temps écouté de lui-même.
@MainActor
final class NowPlaying {

    private let model: SimulationModel
    private var subscriptions: Set<AnyCancellable> = []

    init(model: SimulationModel) {
        self.model = model
        let engine = model.engine
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { engine.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                if engine.isPlaying || engine.isBuffering { engine.pause() } else { self?.play() }
            }
            return .success
        }
        for command in [center.nextTrackCommand, center.previousTrackCommand,
                        center.skipForwardCommand, center.skipBackwardCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = false
        }

        engine.$isPlaying.removeDuplicates()
            .combineLatest(model.$scenario.map(\.label.title).removeDuplicates(),
                           engine.$speed.removeDuplicates())
            .sink { [weak self] _ in
                // Publié après la mise à jour : `sink` voit la valeur avant
                // que le moteur ne l'ait rangée.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish() } }
            }
            .store(in: &subscriptions)
    }

    private func play() {
        let engine = model.engine
        if engine.isFinished { model.restart() }
        engine.play()
    }

    private func publish() {
        let engine = model.engine
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: model.label.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? engine.speed.rawValue : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        if let tool = model.defrag?.strategy.label ?? model.install?.osName
            ?? model.dayPlayback.map({ "Jour \($0.day), \($0.date)" }) ?? model.boot?.osName {
            info[MPMediaItemPropertyArtist] = tool
        }
        info[MPMediaItemPropertyAlbumTitle] = "Winchester"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
