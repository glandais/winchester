import StoreKit
import SwiftUI

/// La feuille « Laisser un pourboire », ouverte par « Soutenir Winchester » dans
/// les Réglages.
///
/// Trois achats consommables qui ne débloquent rien (chantier 38). Les noms et
/// les prix viennent du store, dans la langue et la devise de l'acheteur : le
/// catalogue n'en porte aucun.
struct TipSheet: View {

    let tipJar: TipJar
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("tip.header")
                            .font(.dynamic(size: 13))
                            .foregroundStyle(Theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        tips
                        status
                    }
                    .padding(16)
                }
            }
            .navigationTitle("tip.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.ok") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(Theme.read)
        .task { await tipJar.load() }
    }

    @ViewBuilder
    private var tips: some View {
        if tipJar.isLoading && tipJar.products.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .panel()
        } else if tipJar.isUnavailable {
            VStack(alignment: .leading, spacing: 10) {
                Text("tip.unavailable")
                    .font(.dynamic(size: 13))
                    .foregroundStyle(Theme.dim)
                Button("tip.retry") {
                    Task { await tipJar.load() }
                }
                .font(.dynamic(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        } else {
            VStack(spacing: 0) {
                ForEach(tipJar.products) { product in
                    if product.id != tipJar.products.first?.id {
                        Divider().overlay(Theme.stroke)
                    }
                    row(product)
                }
            }
            .panel()
        }
    }

    private func row(_ product: Product) -> some View {
        Button {
            Task { await tipJar.buy(product, with: purchase) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cup.and.saucer")
                    .font(.dynamic(size: 15))
                    .foregroundStyle(Theme.write)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Text(verbatim: product.displayName)
                    .font(.dynamic(size: 15))
                    .foregroundStyle(Theme.text)
                Spacer()
                if tipJar.state == .purchasing(product.id) {
                    ProgressView()
                } else {
                    Text(verbatim: product.displayPrice)
                        .font(.dynamic(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.read)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
    }

    @ViewBuilder
    private var status: some View {
        switch tipJar.state {
        case .thanked:
            Label("tip.thanks", systemImage: "heart.fill")
                .font(.dynamic(size: 15, weight: .semibold))
                .foregroundStyle(Theme.write)
        case .pending:
            note("tip.pending")
        case .failed:
            note("tip.failed")
        case .idle, .purchasing:
            EmptyView()
        }
    }

    private func note(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.dynamic(size: 12))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isPurchasing: Bool {
        if case .purchasing = tipJar.state { true } else { false }
    }
}
