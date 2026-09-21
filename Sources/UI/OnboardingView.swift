import SwiftUI
import DiskCore

/// L'accueil d'une première ouverture — maquette 01, en trois écrans : ce
/// qu'on entend, ce que montre la carte, et mettre un casque.
///
/// Rien n'y est à régler qu'on ne retrouve ailleurs : le dernier écran propose
/// les vibrations, et renvoie à « Son et vibrations » pour le reste.
struct OnboardingView: View {

    /// Vrai une fois l'accueil quitté ; les Réglages le remettent à faux pour
    /// le revoir.
    static let seenKey = "onboardingSeen"

    let engine: WinchesterEngine
    /// Appelé quand on quitte l'accueil, par « Passer » comme par le dernier
    /// bouton.
    let onFinish: () -> Void

    @State private var page = 0
    @State private var hapticsEnabled: Bool

    init(engine: WinchesterEngine, onFinish: @escaping () -> Void) {
        self.engine = engine
        self.onFinish = onFinish
        _hapticsEnabled = State(initialValue: engine.hapticsEnabled)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < 2 {
                        Button("onboarding.skip", action: onFinish)
                            .font(.dynamic(size: 15))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 20)

                TabView(selection: $page) {
                    sounds.tag(0)
                    map.tag(1)
                    headphones.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots
                    .padding(.bottom, 16)

                Button {
                    if page < 2 {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page < 2 ? "onboarding.continue" : "onboarding.listen")
                        .font(.dynamic(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.read))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Theme.read : Color.white.opacity(0.18))
                    .frame(width: index == page ? 18 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "onboarding.page",
                                   defaultValue: "Screen \(page + 1) of 3",
                                   comment: "Étiquette d'accessibilité des points de page de l'accueil"))
    }

    // MARK: - Les trois écrans

    private var sounds: some View {
        screen(title: "onboarding.sounds.title", lead: "onboarding.sounds.lead") {
            item("arrow.left.and.right", Theme.read, "onboarding.sounds.seek.title",
                 "onboarding.sounds.seek.text")
            item("arrow.uturn.backward", Theme.write, "onboarding.sounds.return.title",
                 "onboarding.sounds.return.text")
            item("circle.dotted", Theme.arm, "onboarding.sounds.hum.title",
                 "onboarding.sounds.hum.text")
        }
    }

    private var map: some View {
        screen(title: "onboarding.map.title", lead: "onboarding.map.lead") {
            swatchItem([Theme.categoryColor(.document, contiguous: true), Theme.categoryColor(.document)],
                       "onboarding.map.shades.title", "onboarding.map.shades.text")
            swatchItem([Theme.read, Theme.write],
                       "onboarding.map.trace.title", "onboarding.map.trace.text")
            swatchItem([Theme.categoryColor(.free)],
                       "onboarding.map.free.title", "onboarding.map.free.text")
        }
    }

    private var headphones: some View {
        screen(title: "onboarding.headphones.title", lead: "onboarding.headphones.lead") {
            HStack {
                Spacer()
                Image(systemName: "headphones")
                    .font(.dynamic(size: 64, weight: .light))
                    .foregroundStyle(Theme.read)
                    .accessibilityHidden(true)
                Spacer()
            }
            .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 6) {
                if engine.supportsHaptics {
                    Toggle(isOn: $hapticsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("onboarding.haptics.title")
                                .font(.dynamic(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("onboarding.haptics.text")
                                .font(.dynamic(size: 12))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .tint(Theme.read)
                    .onChange(of: hapticsEnabled) { _, enabled in
                        engine.hapticsEnabled = enabled
                        engine.mix.save(to: .standard)
                    }
                } else {
                    Text("onboarding.haptics.title")
                        .font(.dynamic(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("onboarding.haptics.unavailable")
                        .font(.dynamic(size: 12))
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()

            Text("onboarding.headphones.later")
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
        }
    }

    // MARK: - Composants

    private func screen<Content: View>(title: LocalizedStringKey, lead: LocalizedStringKey,
                                     @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.dynamic(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Text(lead)
                    .font(.dynamic(size: 16))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func item(_ systemImage: String, _ color: Color, _ title: LocalizedStringKey,
                      _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.dynamic(size: 20, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.dynamic(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(text)
                    .font(.dynamic(size: 14))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func swatchItem(_ colors: [Color], _ title: LocalizedStringKey,
                            _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(spacing: 3) {
                ForEach(colors.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(colors[index])
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.dynamic(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(text)
                    .font(.dynamic(size: 14))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
