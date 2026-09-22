import Observation
import StoreKit
import SwiftUI // PurchaseAction

/// Les pourboires : trois achats consommables qui ne débloquent rien.
///
/// Copié du fichier de référence commun aux apps du développeur (dépôt
/// `donations`). Les produits `<bundle>.tip.small|medium|large` sont créés dans
/// App Store Connect ; `Support/Tips.storekit` les reprend pour le simulateur.
///
/// Il n'y a rien à livrer ni à restaurer : un achat vérifié est fini tout de
/// suite, et l'app dit merci. Aucun serveur, aucune donnée gardée.
@MainActor
@Observable
final class TipJar {
    enum State: Equatable {
        case idle
        case purchasing(Product.ID)
        /// « Demander l'autorisation d'acheter » : un parent doit approuver ;
        /// l'achat arrivera plus tard par `Transaction.updates`.
        case pending
        case thanked
        case failed
    }

    /// Les identifiants suivent le bundle, pour que ce fichier se copie tel quel.
    static let productIDs: [Product.ID] = {
        let bundle = Bundle.main.bundleIdentifier ?? ""
        return ["small", "medium", "large"].map { "\(bundle).tip.\($0)" }
    }()

    /// Triés par prix croissant.
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    /// Vrai si le store n'a rien rendu (hors ligne, produits pas encore validés…).
    private(set) var isUnavailable = false
    var state: State = .idle

    private var updates: Task<Void, Never>?

    /// À appeler au lancement de l'app, pas à l'ouverture de l'écran : StoreKit
    /// y renvoie les transactions restées ouvertes (achat interrompu, Ask to Buy
    /// approuvé plus tard) et elles doivent être finies.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                guard let self, Self.productIDs.contains(transaction.productID),
                      transaction.revocationDate == nil else { continue }
                self.state = .thanked
            }
        }
    }

    func load() async {
        guard products.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Self.productIDs)
                .sorted { $0.price < $1.price }
        } catch {
            products = []
        }
        isUnavailable = products.isEmpty
    }

    /// `purchase` vient de `@Environment(\.purchase)` : StoreKit y trouve la
    /// scène où présenter la feuille de paiement.
    func buy(_ product: Product, with purchase: PurchaseAction) async {
        state = .purchasing(product.id)
        do {
            switch try await purchase(product) {
            case .success(.verified(let transaction)):
                await transaction.finish()
                state = .thanked
            case .success(.unverified):
                // Non vérifié : ni fini ni remercié ; StoreKit le représentera.
                state = .failed
            case .pending:
                state = .pending
            case .userCancelled:
                state = .idle
            @unknown default:
                state = .idle
            }
        } catch {
            state = .failed
        }
    }
}
