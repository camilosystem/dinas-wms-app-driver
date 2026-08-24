import Foundation
import GRDB

/// Punto de acceso a la base local SQLite (GRDB) de la app de DRIVER.
///
/// Encapsula el `DatabaseQueue` y define las migraciones del DESPACHO. Offline-first: la ruta
/// se descarga entera y vive aquí; lo que registra el driver va a `pending_actions` y se
/// sincroniza cuando hay red.
struct AppDatabase {
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    // MARK: - Fábricas

    /// Base POR USUARIO, en Application Support. ★ Aislamiento estructural: cada driver tiene
    /// su propio archivo → NUNCA ve la ruta de otro. En la calle eso no es confusión: es
    /// entregar en la dirección equivocada. No depende de limpiar cache al cambiar de sesión.
    static func makeForUser(_ username: String?) throws -> AppDatabase {
        let fm = FileManager.default
        let folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
        let dbURL = folder.appendingPathComponent(filename(forUser: username))
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        return try AppDatabase(dbQueue)
    }

    /// Nombre de archivo por usuario, saneado (solo `[a-z0-9_-]`). `nil`/vacío → "invitado".
    static func filename(forUser username: String?) -> String {
        let raw = (username ?? "").lowercased()
        let safe = String(raw.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return "dinas-driver-\(safe.isEmpty ? "_guest" : safe).sqlite"
    }

    /// Base en memoria, para tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    // MARK: - Migraciones
    //
    // Disciplina: una migración liberada es INMUTABLE; los cambios de esquema van en una
    // migración NUEVA al final. Aditivas y preservan datos.

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_dispatch") { db in
            // Cabecera de la ruta descargada (una sola fila). downloaded_at marca que ya
            // descargó y puede trabajar offline.
            try db.create(table: "route") { t in
                t.primaryKey("truck_id", .text)
                t.column("truck_name", .text)
                t.column("status", .text).notNull()
                t.column("downloaded_at", .datetime).notNull()
                t.column("started_at", .datetime)
                t.column("total_stops", .integer).notNull().defaults(to: 0)
                t.column("total_orders", .integer).notNull().defaults(to: 0)
                t.column("pending_orders", .integer).notNull().defaults(to: 0)
            }

            // Paradas en el orden del admin (stop_number). Sin FK: el reemplazo del snapshot
            // borra explícitamente (evita sorpresas de cascada).
            try db.create(table: "driver_stops") { t in
                t.column("truck_id", .text).notNull()
                t.column("stop_number", .integer).notNull().defaults(to: 0)
                t.column("client_code", .text).notNull()
                t.column("client_name", .text).notNull().defaults(to: "")
                t.column("address", .text)
                t.column("city", .text)
                t.column("zip_code", .text)
                t.column("phone", .text)
                t.primaryKey(["truck_id", "client_code"])
            }

            // Pedidos a entregar (líneas/pallets como JSON). delivery_status lo fija el server.
            try db.create(table: "driver_orders") { t in
                t.primaryKey("order_uuid", .text)
                t.column("truck_id", .text).notNull()
                t.column("client_code", .text).notNull()
                t.column("order_number", .text).notNull().defaults(to: "")
                t.column("total_amount", .double).notNull().defaults(to: 0)
                t.column("total_units", .double).notNull().defaults(to: 0)
                t.column("pallet_labels", .text).notNull().defaults(to: "[]")
                t.column("is_incomplete_delivery", .boolean).notNull().defaults(to: false)
                t.column("delivery_status", .text)
                t.column("lines", .text).notNull().defaults(to: "[]")
            }

            // Cola de acciones (offline). occurred_at = hora real en la calle (verbatim al replay).
            try db.create(table: "pending_actions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("truck_id", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("order_uuid", .text)
                t.column("order_reason", .text)
                t.column("rejected_items", .text)      // JSON
                t.column("note", .text)
                t.column("occurred_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("error_message", .text)
            }

            // Preferencia LOCAL de orden de paradas (device-only, nunca se sincroniza).
            try db.create(table: "local_stop_order") { t in
                t.column("truck_id", .text).notNull()
                t.column("client_code", .text).notNull()
                t.column("local_index", .integer).notNull().defaults(to: 0)
                t.primaryKey(["truck_id", "client_code"])
            }
        }

        // ★ v0.15.0 — RETORNO de producto (Bloque 4B). Catálogo para buscar offline + campos del
        // retorno en la cola. La FOTO no va en SQLite: la cola guarda su RUTA en disco (photo_path).
        migrator.registerMigration("v2_returns") { db in
            try db.create(table: "catalog_items") { t in
                t.primaryKey("item_code", .text)
                t.column("item_name", .text).notNull().defaults(to: "")
            }
            try db.alter(table: "pending_actions") { t in
                t.add(column: "client_code", .text)
                t.add(column: "return_items", .text)       // JSON
                t.add(column: "client_reference", .text)
                t.add(column: "photo_path", .text)          // ruta al JPEG en disco
            }
        }

        // ★ v0.15.0 — idempotencia del retorno: uuid generado al crear, estable en reintentos.
        migrator.registerMigration("v3_return_uuid") { db in
            try db.alter(table: "pending_actions") { t in
                t.add(column: "return_uuid", .text)
            }
        }

        // ★ v0.16.0 — PAGOS en ruta (Bloque 4C). Registro LOCAL DURABLE (fuente de la caja): el
        // pago se guarda al instante y no se pierde; el envío se sincroniza aparte. Un pago es
        // dinero → nada se borra: anular deja el rastro (is_voided/void_reason).
        migrator.registerMigration("v4_payments") { db in
            try db.create(table: "payments") { t in
                t.primaryKey("payment_uuid", .text)
                t.column("truck_id", .text).notNull()
                t.column("client_code", .text).notNull()
                t.column("client_name", .text).notNull().defaults(to: "")
                t.column("amount", .double).notNull().defaults(to: 0)
                t.column("payment_type", .text).notNull()
                t.column("check_number", .text)
                t.column("note", .text)
                t.column("photo_path", .text)          // cheque: ruta al JPEG en disco
                t.column("occurred_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("is_voided", .boolean).notNull().defaults(to: false)
                t.column("void_reason", .text)
                t.column("voided_at", .datetime)
                t.column("create_synced", .boolean).notNull().defaults(to: false)
                t.column("void_synced", .boolean).notNull().defaults(to: false)
            }
        }

        // ★ v0.45.0 — RECOGIDAS (una solicitud de crédito convertida en parada de recogida). Se
        // guardan en la descarga para bastarse offline. En pending_actions: `pickup_for_request_uuid`
        // marca que un PRODUCT_RETURN es en realidad la recogida de esa solicitud (y sirve de marca
        // local anti-doble-registro); `pickup_not_collected_reason` es el motivo de la acción nueva
        // PICKUP_NOT_COLLECTED.
        migrator.registerMigration("v5_pickups") { db in
            try db.create(table: "driver_pickups") { t in
                t.primaryKey("request_uuid", .text)
                t.column("truck_id", .text).notNull()
                t.column("client_code", .text).notNull()
                t.column("reason", .text)
                t.column("pickup_note", .text)
                t.column("pickup_status", .text).notNull().defaults(to: "EN_CAMION")
                t.column("expected_items", .text).notNull().defaults(to: "[]")   // JSON
            }
            try db.alter(table: "pending_actions") { t in
                t.add(column: "pickup_for_request_uuid", .text)
                t.add(column: "pickup_not_collected_reason", .text)
            }
        }

        // ★ Pagos: rechazo permanente. Sin esto, un pago rechazado por el servidor se reintenta en
        // cada sync (para siempre) y se muestra como "pendiente" — el driver cierra el día creyendo
        // que se registró. Marcar el rechazo detiene el reintento y la caja lo distingue de pendiente.
        migrator.registerMigration("v6_pago_rechazado") { db in
            try db.alter(table: "payments") { t in
                t.add(column: "create_rejected_reason", .text)
                t.add(column: "void_rejected_reason", .text)
            }
        }

        // ★ v0.70.0 (Dr1) — facturas que el cliente dice pagar, como lista (JSON). NOT NULL con
        // default "[]": vacío = no anotó ninguna (legítimo), nunca ausente.
        migrator.registerMigration("v7_invoice_doc_nums") { db in
            try db.alter(table: "payments") { t in
                t.add(column: "invoice_doc_nums", .text).notNull().defaults(to: "[]")
            }
        }

        return migrator
    }
}
