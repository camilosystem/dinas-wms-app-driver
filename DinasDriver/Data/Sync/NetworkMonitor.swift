import Foundation
import Network
import os

/// Estado de conectividad **con el middleware**, re-evaluado activamente.
///
/// Antes se alimentaba SOLO del `pathUpdateHandler` de `NWPathMonitor`, que reporta si el
/// dispositivo tiene una interfaz de red satisfecha — NO si el middleware responde. Eso
/// dejaba dos huecos: (1) middleware caído con WiFi arriba se veía "online"; (2) si el
/// monitor no entregaba el flanco de recuperación (típico en el simulador), `isOnline`
/// quedaba pegado en `false` hasta reiniciar la app.
///
/// Ahora la conectividad es un estado ACTIVO: se **sondea** el middleware (cualquier
/// respuesta HTTP = alcanzable; error de transporte = no) en tres disparadores:
///   1. flanco `.satisfied` de `NWPathMonitor` (cambió la red del dispositivo),
///   2. sondeo de respaldo mientras está offline (por si el middleware vuelve sin que
///      cambie la red del dispositivo),
///   3. `retry()` manual (botón "Reintentar conexión").
///
/// En bodega, al RECUPERAR la conexión (offline→online) dispara `onReconnect` para
/// reenviar el progreso de picking encolado (nada de trabajo se pierde en una caída).
/// Publica `isOnline` (y `isChecking` para el spinner del botón).
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    /// `true` mientras corre un sondeo (para el spinner del botón Reintentar).
    @Published private(set) var isChecking = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.dinas.driver.network")
    /// Sondeo de alcance al middleware. Devuelve `true` si respondió (alcanzable).
    private let probe: @Sendable () async -> Bool
    /// Solo en producción: reintento automático (NWPath + poll). En tests se dirige a mano.
    private let autoRetry: Bool
    /// Cada cuánto reintentar mientras está offline (respaldo del NWPath).
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    /// Se invoca al pasar de offline a online (para reenviar lo pendiente).
    private let onReconnect: () -> Void

    /// `autoStart: false` en tests, para dirigir el estado con `handle(online:)`/`check()`.
    /// `probe` por defecto asume alcanzable (tests que no ejercitan el sondeo).
    init(autoStart: Bool = true,
         pollInterval: Duration = .seconds(10),
         probe: @escaping @Sendable () async -> Bool = { true },
         onReconnect: @escaping () -> Void = {}) {
        self.probe = probe
        self.autoRetry = autoStart
        self.pollInterval = pollInterval
        self.onReconnect = onReconnect
        guard autoStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: queue)
    }

    // MARK: - Disparadores

    /// Cambió la ruta de red del dispositivo. Sin interfaz → offline directo; con interfaz
    /// NO asumimos alcance al middleware: sondeamos.
    private func pathChanged(satisfied: Bool) {
        if satisfied {
            Task { await self.check() }
        } else {
            setOnline(false)   // sin ninguna interfaz: definitivamente offline
        }
    }

    /// "Reintentar conexión" (botón). Fuerza un sondeo ahora mismo.
    func retry() async {
        await check()
    }

    /// Sondea el middleware y actualiza `isOnline` según el alcance REAL. Único punto de
    /// re-evaluación (lo llaman el NWPath, el poll y el botón).
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        let reachable = await probe()
        isChecking = false
        setOnline(reachable)
    }

    // MARK: - Estado

    private func setOnline(_ online: Bool) {
        let recovered = online && !isOnline   // transición offline → online
        if isOnline != online {
            isOnline = online
            AppLog.network.info("conectividad \(online ? "online" : "offline", privacy: .public)")
        }
        // Respaldo: mientras esté offline, reintenta solo; al volver, deja de sondear.
        if online { stopPolling() } else { startPolling() }
        if recovered { onReconnect() }   // reenvía lo pendiente al recuperar la red
    }

    /// Sondeo de respaldo mientras está offline (solo producción). Cubre el caso en que el
    /// middleware vuelve sin que la red del dispositivo cambie (NWPath no se dispara).
    private func startPolling() {
        guard autoRetry, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(10))
                guard let self, !Task.isCancelled, !self.isOnline else { break }
                await self.check()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Semilla de estado para tests (simula el flanco de `NWPathMonitor` sin sondeo).
    func handle(online: Bool) {
        setOnline(online)
    }

    deinit {
        monitor.cancel()
    }
}
