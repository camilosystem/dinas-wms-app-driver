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

    /// Base compartida de la app, en Application Support.
    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
        let dbURL = folder.appendingPathComponent("dinas-driver.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        return try AppDatabase(dbQueue)
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

        return migrator
    }
}
