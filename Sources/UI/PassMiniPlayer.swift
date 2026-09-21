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
    /// L'app revient d'arrière-plan : le bandeau dit où en est la passe — la
    /// maquette 17 —, jusqu'à ce qu'on l'ouvre.
    let returned: Bool
    let onOpen: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let engine = model.engine
            if engine.isPlaying || engine.isBuffering || engine.currentTime > 0 {
                bar(engine)
            }
        }
    }

    private func bar(_ engine: WinchesterEngine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = notice(engine) {
                Text(notice)
                    .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(engine.interruption == nil ? Theme.write : Theme.read)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            row(engine)
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
        .accessibilityHint("miniplayer.hint")
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// « EN COURS · RETOUR D'ARRIÈRE-PLAN », ou la raison d'une pause subie.
    private func notice(_ engine: WinchesterEngine) -> String? {
        if let interruption = engine.interruption {
            return String(localized: "miniplayer.interrupted",
                          defaultValue: "INTERRUPTED AT \(Format.duration(interruption.time).uppercased()) · \(interruption.label.uppercased())",
                          comment: "Bandeau de la passe : instant de l'interruption, puis sa raison")
        }
        guard returned else { return nil }
        let state = engine.isFinished
            ? String(localized: "pass.state.finished", defaultValue: "FINISHED")
            : engine.isPlaying || engine.isBuffering
                ? String(localized: "pass.state.running", defaultValue: "RUNNING")
                : String(localized: "pass.state.paused", defaultValue: "PAUSED")
        return String(localized: "miniplayer.returned",
                      defaultValue: "\(state) · BACK FROM THE BACKGROUND")
    }

    private func row(_ engine: WinchesterEngine) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.activityLED ? Theme.read : Color.white.opacity(0.10))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.label.title)
                    .font(.dynamic(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(detail(engine))
                    .font(.dynamic(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                if engine.isFinished { model.restart() }
                engine.toggle()
            } label: {
                Image(systemName: engine.isPlaying || engine.isBuffering ? "pause.fill" : "play.fill")
                    .font(.dynamic(size: 17))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(engine.isPlaying || engine.isBuffering ? "transport.pause" : "transport.play")
        }
    }

    /// La phase et le temps écouté ; l'avancement d'abord, au retour, puisque
    /// c'est ce qu'on vient chercher.
    private func detail(_ engine: WinchesterEngine) -> String {
        var parts: [String] = []
        if (returned || engine.interruption != nil), let progress = model.defragProgress {
            parts.append(Format.percent(progress))
        }
        parts.append(model.phase?.label ?? "—")
        parts.append(engine.currentTime.clockString)
        return parts.joined(separator: " · ")
    }
}

extension View {
    /// Pose le bandeau de la passe en bas de l'écran, s'il y a une passe et
    /// qu'on ne la regarde pas déjà.
    func passMiniPlayer(model: SimulationModel, isShown: Bool, returned: Bool = false,
                        onOpen: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if isShown { PassMiniPlayer(model: model, returned: returned, onOpen: onOpen) }
        }
    }
}
