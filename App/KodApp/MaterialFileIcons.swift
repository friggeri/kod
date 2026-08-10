import AppKit
import os

private let materialFileIconLog = Logger(
    subsystem: "com.kodapp.Kod",
    category: "material-file-icons"
)

enum MaterialFileIconError: Error, CustomStringConvertible {
    case missingManifest
    case unsupportedSchemaVersion(Int)

    var description: String {
        switch self {
        case .missingManifest:
            "The bundled Material file icon manifest is missing."
        case let .unsupportedSchemaVersion(version):
            "Unsupported Material file icon manifest schema version \(version)."
        }
    }
}

struct MaterialFileIconManifest: Decodable {
    struct AppearanceOverrides: Decodable {
        let fileExtensions: [String: String]
        let fileNames: [String: String]
    }

    let schemaVersion: Int
    let sourceVersion: String
    let defaultIcon: String
    let iconDefinitions: [String: String]
    let fileExtensions: [String: String]
    let fileNames: [String: String]
    let light: AppearanceOverrides

    static func bundled(in bundle: Bundle) throws -> Self {
        guard let url = bundle.url(
            forResource: "material-file-icons",
            withExtension: "json",
            subdirectory: "MaterialIcons"
        ) else {
            throw MaterialFileIconError.missingManifest
        }

        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == 1 else {
            throw MaterialFileIconError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        return manifest
    }

    func iconIdentifier(forFileName fileName: String, isLight: Bool) -> String {
        let relativePath = fileName.hasPrefix("./")
            ? String(fileName.dropFirst(2))
            : fileName
        let displayName = (relativePath as NSString).lastPathComponent
        for candidate in [relativePath, displayName] {
            if let identifier = fileNameIdentifier(for: candidate, isLight: isLight) {
                return identifier
            }
            let lowercasedCandidate = candidate.lowercased()
            if lowercasedCandidate != candidate,
               let identifier = fileNameIdentifier(
                   for: lowercasedCandidate,
                   isLight: isLight
               ) {
                return identifier
            }
        }

        let components = displayName.split(separator: ".", omittingEmptySubsequences: false)
        if components.count > 1 {
            for index in components.indices.dropFirst() {
                let candidate = components[index...].joined(separator: ".")
                guard !candidate.isEmpty else {
                    continue
                }
                if let identifier = fileExtensionIdentifier(
                    for: candidate,
                    isLight: isLight
                ) {
                    return identifier
                }
                let lowercasedCandidate = candidate.lowercased()
                if lowercasedCandidate != candidate,
                   let identifier = fileExtensionIdentifier(
                       for: lowercasedCandidate,
                       isLight: isLight
                   ) {
                    return identifier
                }
            }
        }

        return defaultIcon
    }

    private func fileNameIdentifier(for name: String, isLight: Bool) -> String? {
        (isLight ? light.fileNames[name] : nil) ?? fileNames[name]
    }

    private func fileExtensionIdentifier(
        for fileExtension: String,
        isLight: Bool
    ) -> String? {
        (isLight ? light.fileExtensions[fileExtension] : nil)
            ?? fileExtensions[fileExtension]
    }
}

@MainActor
final class MaterialFileIconProvider {
    static let shared = MaterialFileIconProvider()

    static var resourceBundle: Bundle {
        Bundle(for: MaterialFileIconProvider.self)
    }

    private let bundle: Bundle
    private let manifest: MaterialFileIconManifest?
    private var imageCache: [String: NSImage] = [:]
    private var reportedMissingIcons: Set<String> = []

    private init(bundle: Bundle? = nil) {
        let resolvedBundle = bundle ?? Self.resourceBundle
        self.bundle = resolvedBundle
        do {
            manifest = try MaterialFileIconManifest.bundled(in: resolvedBundle)
        } catch {
            manifest = nil
            materialFileIconLog.error(
                "Unable to load bundled Material file icons: \(String(describing: error), privacy: .public)"
            )
        }
    }

    func image(forFileName fileName: String, appearance: NSAppearance) -> NSImage {
        guard let manifest else {
            return fallbackImage()
        }

        let isLight = appearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        let identifier = manifest.iconIdentifier(forFileName: fileName, isLight: isLight)
        if let image = materialImage(identifier: identifier, manifest: manifest) {
            return image
        }

        reportMissingIcon(identifier)
        if identifier != manifest.defaultIcon,
           let image = materialImage(identifier: manifest.defaultIcon, manifest: manifest) {
            return image
        }
        reportMissingIcon(manifest.defaultIcon)
        return fallbackImage()
    }

    private func materialImage(
        identifier: String,
        manifest: MaterialFileIconManifest
    ) -> NSImage? {
        guard let assetName = manifest.iconDefinitions[identifier],
              assetName == (assetName as NSString).lastPathComponent,
              assetName.hasSuffix(".svg") else {
            return nil
        }
        if let cached = imageCache[assetName] {
            return cached
        }
        guard let url = bundle.url(
            forResource: assetName,
            withExtension: nil,
            subdirectory: "MaterialIcons/icons"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.isTemplate = false
        imageCache[assetName] = image
        return image
    }

    private func reportMissingIcon(_ identifier: String) {
        guard reportedMissingIcons.insert(identifier).inserted else {
            return
        }
        materialFileIconLog.error(
            "The bundled Material file icon '\(identifier, privacy: .public)' is missing or invalid."
        )
    }

    private func fallbackImage() -> NSImage {
        NSImage(
            systemSymbolName: "doc.text",
            accessibilityDescription: nil
        ) ?? NSImage()
    }
}

@MainActor
class MaterialFileIconView: NSImageView {
    var fileName: String? {
        didSet {
            guard oldValue != fileName else {
                return
            }
            refreshImage()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if fileName != nil {
            refreshImage()
        }
    }

    private func refreshImage() {
        guard let fileName else {
            image = nil
            return
        }
        image = MaterialFileIconProvider.shared.image(
            forFileName: fileName,
            appearance: effectiveAppearance
        )
    }
}
