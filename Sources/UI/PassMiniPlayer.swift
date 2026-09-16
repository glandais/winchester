import SwiftUI
import DiskCore

/// Le bandeau de la passe en cours, posé au-dessus de la barre d'onglets
/// quand on n'est pas sur l'onglet **Passe**.
///
/// Il ne suit pas l'horloge du moteur : deux rafraîchissements par seconde
/// suffisent à un temps écoulé et à une phase, et l'écran qu'il recouvre n'a
/// pas à se redessiner soixante fois par seconde pour lui.
private struct PassMiniPlayer: View {

    let model: SimulationModel
    let onOpen: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let engine = model.engine
            if engine.isPlaying || engine.isBuffering || engine.currentTime > 0 {
                bar(engine)
            }
        }
    }

    private func bar(_ engine: DiskNoiseEngine) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.activityLED ? Theme.read : Color.white.opacity(0.10))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.label.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(model.phase?.label ?? "—") · \(engine.currentTime.clockString)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                if engine.isFinished { model.restart() }
                engine.toggle()
            } label: {
                Image(systemName: engine.isPlaying || engine.isBuffering ? "pause.fill" : "play.fill")
                    .font(.system(size: 17))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(engine.isPlaying || engine.isBuffering ? "Pause" : "Lecture")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Ouvre la passe")
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

extension View {
    /// Pose le bandeau de la passe en bas de l'écran, s'il y a une passe et
    /// qu'on ne la regarde pas déjà.
    func passMiniPlayer(model: SimulationModel, isShown: Bool, onOpen: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if isShown { PassMiniPlayer(model: model, onOpen: onOpen) }
        }
    }
}
