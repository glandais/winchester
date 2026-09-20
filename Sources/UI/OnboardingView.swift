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
                        Button("Passer", action: onFinish)
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
                    Text(page < 2 ? "Continuer" : "Écouter un disque")
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
        .accessibilityLabel("Écran \(page + 1) sur 3")
    }

    // MARK: - Les trois écrans

    private var sounds: some View {
        screen(title: "Ce qu'on entend",
             lead: "Trois sons, produits en direct par la mécanique simulée.") {
            item("arrow.left.and.right", Theme.read, "Le seek",
                 "Le bras saute d'un cylindre à l'autre.")
            item("arrow.uturn.backward", Theme.write, "Le retour au bord",
                 "Un « clac » franc : le bras revient au début de la partition réécrire la FAT, à chaque fichier.")
            item("circle.dotted", Theme.arm, "Le ronronnement",
                 "La rotation, en continu, sous tout le reste.")
        }
    }

    private var map: some View {
        screen(title: "Ce que montre la carte",
             lead: "Un bloc vaut quelques dizaines de clusters. Il change de couleur à l'instant où son écriture s'entend.") {
            swatchItem([Theme.categoryColor(.document, contiguous: true), Theme.categoryColor(.document)],
                       "Même couleur, deux teintes",
                       "Plus sombre : rangé d'un seul tenant. Plus clair : en morceaux.")
            swatchItem([Theme.read, Theme.write],
                       "Ambre et turquoise",
                       "Ambre quand on lit, turquoise quand on écrit. La trace s'efface en un tiers de seconde.")
            swatchItem([Theme.categoryColor(.free)],
                       "Gris foncé : libre",
                       "Les trous entre les fichiers sont ce qui fragmente les suivants.")
        }
    }

    private var headphones: some View {
        screen(title: "Mettez un casque",
             lead: "Le haut-parleur de l'iPhone efface le grave de la rotation et les transitoires du bras. "
                + "Au casque, un seek court et une pleine course ne sonnent pas pareil.") {
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
                            Text("Vibrations")
                                .font(.dynamic(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("Les transitoires du bras dans la main")
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
                    Text("Vibrations")
                        .font(.dynamic(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Indisponibles sur cet appareil. Le son n'en dépend pas.")
                        .font(.dynamic(size: 12))
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()

            Text("Tout se règle plus tard dans « Son et vibrations ».")
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
        }
    }

    // MARK: - Composants

    private func screen<Content: View>(title: String, lead: String,
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

    private func item(_ systemImage: String, _ color: Color, _ title: String, _ text: String) -> some View {
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

    private func swatchItem(_ colors: [Color], _ title: String, _ text: String) -> some View {
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
