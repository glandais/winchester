import Foundation

/// Une passe qui se calcule sur son propre fil, quelques secondes en avance sur
/// l'écoute.
///
/// Le producteur — planificateur, simulateur, repères — ne s'arrête jamais de
/// lui-même : une passe de 1995 sur un volume de 6 Go se planifie en moins
/// d'une seconde et s'écoute pendant plus d'une heure. C'est donc l'écoute qui le tient
/// en laisse. Chaque paquet produit est déposé ici, et le fil s'endort dès
/// qu'il a pris `horizon` secondes d'avance sur ce que l'écoute a réclamé ; il
/// se réveille quand elle vient chercher la suite.
///
/// L'avance n'est pas là pour la mémoire — quelques secondes de passe pèsent
/// quelques centaines de kilo-octets — mais pour absorber les à-coups du
/// planificateur : un tri de JkDefrag calcule parfois longtemps sans rien
/// émettre, et l'audio ne doit pas en manquer pendant ce temps.
///
/// **Abandonner une session n'interrompt pas le planificateur**, qui n'a aucun
/// point d'arrêt prévu. Le fil est libéré, le producteur voit `isCancelled` et
/// cesse de simuler quoi que ce soit : le planificateur termine son calcul à
/// vide, ce qui coûte au pire quelques secondes de processeur sur les plus
/// grosses passes de la galerie.
final class PassSession: @unchecked Sendable {

    /// Ce que le producteur voit de la session.
    final class Outlet: @unchecked Sendable {
        fileprivate weak var session: PassSession?
        private let cancelled = Locked(false)

        fileprivate init(session: PassSession) {
            self.session = session
        }

        /// L'écoute a abandonné la passe : plus rien de ce qui sera produit ne
        /// sera lu.
        var isCancelled: Bool { cancelled.value }

        fileprivate func cancel() { cancelled.value = true }

        /// Dépose un paquet, et attend si l'écoute est trop loin derrière.
        func deliver(_ batch: PassBatch) {
            guard !isCancelled, let session else { return }
            session.accept(batch, outlet: self)
        }
    }

    typealias Work = @Sendable (Outlet) -> Void

    let horizon: Double

    private let condition = NSCondition()
    private var inbox = PassBatch()
    private var listened = 0.0
    private var finished = false
    private let work: Work
    private var outlet: Outlet!
    private var started = false

    init(horizon: Double = 8, work: @escaping Work) {
        self.horizon = horizon
        self.work = work
        self.outlet = Outlet(session: self)
    }

    deinit {
        outlet.cancel()
        condition.broadcast()
    }

    /// Lance le producteur. Il avance aussitôt jusqu'à l'horizon, écoute ou
    /// pas : c'est ce qui permet de lancer la lecture sans attendre.
    func start() {
        condition.lock()
        defer { condition.unlock() }
        guard !started else { return }
        started = true
        let outlet = self.outlet!
        let work = self.work
        let thread = Thread {
            work(outlet)
        }
        // Les stratégies recopient des volumes entiers sur la pile ; la pile de
        // 512 Ko d'un fil secondaire n'y suffirait pas toujours.
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.name = "Winchester.pass"
        thread.start()
    }

    /// Abandonne la passe : le producteur est réveillé s'il attendait, et tout
    /// ce qu'il livrera désormais est jeté.
    func cancel() {
        outlet.cancel()
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// Emporte tout ce qui a été produit, et dit jusqu'où l'écoute est arrivée.
    func drain(listenedThrough time: Double) -> PassBatch {
        condition.lock()
        defer { condition.unlock() }
        listened = max(listened, time)
        let taken = inbox
        inbox = PassBatch()
        inbox.clock = taken.clock
        inbox.cueWatermark = taken.cueWatermark
        condition.broadcast()
        return taken
    }

    /// Le producteur a-t-il livré son dernier paquet ?
    var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }

    fileprivate func accept(_ batch: PassBatch, outlet: Outlet) {
        condition.lock()
        defer { condition.unlock() }
        inbox.append(batch)
        if batch.end != nil {
            finished = true
            return
        }
        while !outlet.isCancelled && batch.clock > listened + horizon {
            condition.wait()
        }
    }
}

/// Une valeur partagée entre deux fils, sans cérémonie.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
