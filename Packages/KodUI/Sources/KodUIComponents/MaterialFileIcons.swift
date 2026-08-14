import AppKit
import os

private let materialFileIconLog = Logger(
    subsystem: "com.kodapp.KodUIComponents",
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

    /// Loads the manifest this package ships as a resource. `bundle` is
    /// always `Bundle.module` in production: the manifest and its SVGs
    /// are `KodUIComponents` resources, so they are never looked up in
    /// `Bundle.main` (which belongs to whichever app links this target)
    /// and never located by probing the filesystem.
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

/// What `MaterialFileIconProvider` resolved a file name to: a real
/// bundled Material asset, or the one documented generic fallback.
enum MaterialFileIconResolution {
    case material(assetName: String, image: NSImage)
    case genericFallback(image: NSImage)

    var image: NSImage {
        switch self {
        case let .material(_, image), let .genericFallback(image):
            image
        }
    }

    var assetName: String? {
        switch self {
        case let .material(assetName, _):
            assetName
        case .genericFallback:
            nil
        }
    }
}

/// Maps a workspace-relative file name to its Material icon, using the
/// pinned manifest and SVG assets this package ships as resources.
///
/// Resolution order is the manifest's: exact file name (relative path,
/// then last path component, then their lowercased forms), then the
/// longest-to-shortest compound extension, then the manifest's own
/// `defaultIcon`. If — and only if — the manifest itself is missing or
/// a mapped asset cannot be loaded, the provider falls back to the
/// generic system document symbol (`doc.text`) and logs the offending
/// identifier once. That single fallback is the only silent path, and
/// it is deliberately visible in `MaterialFileIconResolution`.
@MainActor
public final class MaterialFileIconProvider {
    public static let shared = MaterialFileIconProvider()

    /// The SF Symbol used when no bundled Material asset is usable.
    static let genericFallbackSymbolName = "doc.text"

    private let bundle: Bundle
    private let manifest: MaterialFileIconManifest?
    private var imageCache: [String: NSImage] = [:]
    private var reportedMissingIcons: Set<String> = []

    init(bundle: Bundle = .module) {
        self.bundle = bundle
        do {
            manifest = try MaterialFileIconManifest.bundled(in: bundle)
        } catch {
            manifest = nil
            materialFileIconLog.error(
                "Unable to load bundled Material file icons: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Test seam: builds a provider around an explicit manifest (which
    /// may be `nil`, or may name assets the bundle does not contain) so
    /// the fallback paths can be exercised without corrupting the real
    /// bundled resources.
    init(manifest: MaterialFileIconManifest?, bundle: Bundle) {
        self.bundle = bundle
        self.manifest = manifest
    }

    public func image(forFileName fileName: String, appearance: NSAppearance) -> NSImage {
        resolution(
            forFileName: fileName,
            isLight: AppKitAppearanceBridge.isLight(appearance)
        ).image
    }

    func resolution(forFileName fileName: String, isLight: Bool) -> MaterialFileIconResolution {
        guard let manifest else {
            return .genericFallback(image: Self.genericFallbackImage())
        }

        let identifier = manifest.iconIdentifier(forFileName: fileName, isLight: isLight)
        if let resolved = materialResolution(identifier: identifier, manifest: manifest) {
            return resolved
        }

        reportMissingIcon(identifier)
        if identifier != manifest.defaultIcon,
           let resolved = materialResolution(identifier: manifest.defaultIcon, manifest: manifest) {
            return resolved
        }
        reportMissingIcon(manifest.defaultIcon)
        return .genericFallback(image: Self.genericFallbackImage())
    }

    private func materialResolution(
        identifier: String,
        manifest: MaterialFileIconManifest
    ) -> MaterialFileIconResolution? {
        guard let assetName = manifest.iconDefinitions[identifier],
              assetName == (assetName as NSString).lastPathComponent,
              assetName.hasSuffix(".svg") else {
            return nil
        }
        if let cached = imageCache[assetName] {
            return .material(assetName: assetName, image: cached)
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
        return .material(assetName: assetName, image: image)
    }

    private func reportMissingIcon(_ identifier: String) {
        guard reportedMissingIcons.insert(identifier).inserted else {
            return
        }
        materialFileIconLog.error(
            "The bundled Material file icon '\(identifier, privacy: .public)' is missing or invalid."
        )
    }

    private static func genericFallbackImage() -> NSImage {
        NSImage(
            systemSymbolName: genericFallbackSymbolName,
            accessibilityDescription: nil
        ) ?? NSImage()
    }
}

/// An `NSImageView` that shows the Material icon for `fileName` and
/// re-resolves it when the effective appearance changes (the manifest
/// carries light-appearance overrides for a subset of icons).
///
/// Open rather than `final`: the editor tab bar subclasses it purely to
/// opt out of hit-testing.
@MainActor
open class MaterialFileIconView: NSImageView {
    public var fileName: String? {
        didSet {
            guard oldValue != fileName else {
                return
            }
            refreshImage()
        }
    }

    open override func viewDidChangeEffectiveAppearance() {
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
