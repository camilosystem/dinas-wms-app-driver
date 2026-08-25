import Foundation

// Lógica PURA de la custodia del dinero (Dr2), separada de la vista para poder testearla y para
// dejar por escrito las tres decisiones que el bloque existe para proteger.

/// Resultado de declarar/deshacer. Distingue los 409 con significado propio del contrato para que
/// la vista diga la palabra correcta (no un "error" genérico).
enum HandoverOutcome: Equatable {
    case ok(RemotePayment)
    /// Declarar: el pago está anulado (409). No hay dinero detrás.
    case anulado
    /// Deshacer: la oficina ya lo metió en un depósito (409). Ya no es del driver.
    case enDeposito
    /// Deshacer: no estaba declarado como entregado (409).
    case noDeclarado
    /// Sin red / no se pudo hablar con el servidor. La declaración es una acción en línea.
    case sinRed
    /// Otro error del servidor, con su mensaje si lo trae.
    case error(String?)

    /// Mapea un `APIError` de una acción de custodia a un resultado con significado.
    /// `isUndo` cambia cómo se lee un 409 (anulado al declarar vs depósito/no-declarado al deshacer).
    static func from(_ error: Error, isUndo: Bool) -> HandoverOutcome {
        guard let api = error as? APIError else { return .sinRed }
        switch api {
        case .unauthorized:
            return .error(nil)
        case let .server(status, message):
            if status == 409 {
                if !isUndo { return .anulado }
                // Deshacer: el mensaje del servidor distingue depósito de "no estaba declarado".
                let m = (message ?? "").lowercased()
                if m.contains("depós") || m.contains("depos") || m.contains("deposit") { return .enDeposito }
                return .noDeclarado
            }
            return .error(message)
        case .missingBaseURL, .notImplemented:
            return .sinRed
        }
    }
}

enum Custody {

    /// Los pagos de "Mi caja" a mostrar. **Deliberadamente NO se filtran por el camión activo.**
    ///
    /// Es su CAJA, no la caja de una ruta: un pago viejo sin declarar de una ruta ya cerrada sigue
    /// siendo del driver, y filtrarlo por el camión activo escondería justo el dinero que hay que
    /// perseguir. El servidor ya devuelve todo lo no declarado cruzando rutas; la app NO debe
    /// volver a acotarlo. El parámetro existe para dejar claro que se IGNORA a propósito (y para que
    /// el test de sabotaje muerda si alguien lo empieza a usar para filtrar).
    static func cashPayments(_ cash: DriverCash, activeTruckID: String?) -> [RemotePayment] {
        // `activeTruckID` se ignora a propósito. Ver la nota de arriba.
        _ = activeTruckID
        return cash.payments
    }
}

/// Textos del flujo de declaración. ⚠️ El driver DECLARA que entregó, NO hay acuse de recibo: nadie
/// en bodega confirma nada. Están acá (y no inline en la vista) para que un test pueda prohibir que
/// alguien los cambie por un lenguaje de "entrega confirmada".
enum CustodyCopy {
    /// Verbo del botón: DECLARAR. Nunca "Entregar" a secas (implicaría una transacción verificada).
    static let declareButton = "Declarar entregado en bodega"
    /// El aviso que evita que alguien crea que del otro lado alguien confirma.
    static let declareDisclaimer =
        "Estás DECLARANDO que entregaste este dinero en bodega. Nadie lo confirma del otro lado: "
        + "queda sobre tu palabra."
    /// Deshacer se permite y no se puede tapar.
    static let undoButton = "Deshacer la declaración"
    static let undoDisclaimer =
        "Deshacer queda registrado con su hora y suma al conteo de la oficina, aunque el estado "
        + "vuelva a como estaba. No se puede tapar."

    /// ¿El texto habla de DECLARAR y no de una entrega confirmada por bodega? (guardia del test).
    static func esLenguajeDeDeclaracion(_ text: String) -> Bool {
        let t = text.lowercased()
        let declara = t.contains("declar")
        let niegaAcuse = t.contains("nadie lo confirma") || t.contains("sobre tu palabra")
        return declara && niegaAcuse
    }
}

/// Tiempo relativo para la custodia. ★ v0.81.0: el delta entre `occurred_at` y `recorded_at` (y por
/// lo tanto entre `occurred_at` y AHORA) NO tiene signo ni tamaño garantizados. Un "hace X" puede
/// dar horas, días, o **un futuro de cuarenta segundos** por un reloj adelantado. Ese futuro NO se
/// recorta a cero: taparlo cambiaría un dato sospechoso por uno plausible. Se dice "en Xs" y basta.
enum RelativeCustodyTime {

    /// Texto relativo honesto de `date` respecto de `now`. Futuro → "en …"; pasado → "hace …".
    /// Nunca colapsa un futuro a "ahora"/"hace 0" (salvo el empate exacto, que sí es "ahora mismo").
    static func text(_ date: Date, now: Date) -> String {
        let secs = date.timeIntervalSince(now)   // > 0 = futuro (sospechoso, no se oculta)
        if secs == 0 { return "ahora mismo" }
        let future = secs > 0
        let mag = abs(secs)
        let unit = magnitude(mag)
        return future ? "en \(unit)" : "hace \(unit)"
    }

    private static func magnitude(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 24 { return "\(h) h" }
        let d = h / 24
        return "\(d) d"
    }
}
