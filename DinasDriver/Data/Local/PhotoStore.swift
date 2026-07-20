import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Manejo de la FOTO de evidencia del retorno (★ v0.15.0). Reglas duras:
/// - Se REDIMENSIONA antes de guardar (~1024px lado mayor, calidad ~70% → 150-300KB). Una foto
///   de evidencia no necesita 12 MP, y en la calle con mala señal el tamaño lo es todo.
/// - Se guarda en el SISTEMA DE ARCHIVOS (Documents/returns), NO en SQLite. La cola guarda la
///   RUTA al archivo, no los bytes.
/// - Se BORRA al sincronizar (si no, el teléfono se llena tras semanas de retornos).
struct PhotoStore {
    let folder: URL

    init(folder: URL? = nil) {
        if let folder {
            self.folder = folder
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.folder = docs.appendingPathComponent("returns", isDirectory: true)
        }
    }

    /// Redimensiona (lado mayor ≤ `maxPixel`) y recomprime a JPEG `quality`. Usa ImageIO
    /// (thumbnail: no decodifica la imagen completa) → cross-platform y eficiente. Respeta la
    /// orientación EXIF.
    static func resizedJPEG(from imageData: Data, maxPixel: Int = 1024,
                            quality: CGFloat = 0.7) -> Data? {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, thumb,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Redimensiona y guarda en disco; devuelve la RUTA. `imageData` = la foto cruda de la cámara.
    func saveResized(from imageData: Data) throws -> String {
        guard let jpeg = Self.resizedJPEG(from: imageData) else {
            throw PhotoError.cannotProcess
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        try jpeg.write(to: url)
        return url.path
    }

    /// Lee el JPEG y lo devuelve en base64 (SIN prefijo data-uri), para el POST.
    func base64(atPath path: String) throws -> String {
        try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
    }

    /// Borra el archivo (tras sincronizar). Silencioso si ya no está.
    func delete(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    enum PhotoError: Error { case cannotProcess }
}
