import AppKit
import PreviewCore
import UniformTypeIdentifiers
import WebKit

enum HTMLPreviewResourceURL {
    static let host = "workspace"

    static func documentURL(for relativePath: String?) -> URL? {
        guard let relativePath,
              let normalized = normalize(relativePath) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = HTMLPreviewDocument.resourceScheme
        components.host = host
        components.path = "/\(normalized)"
        return components.url
    }

    static func relativePath(from url: URL) -> String? {
        guard url.scheme == HTMLPreviewDocument.resourceScheme,
              url.host == host,
              let encodedPath = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              )?.percentEncodedPath,
              let decodedPath = encodedPath.removingPercentEncoding else {
            return nil
        }
        return normalize(
            String(decodedPath.drop(while: { $0 == "/" }))
        )
    }

    private static func normalize(_ path: String) -> String? {
        guard !path.isEmpty, !path.contains("\0") else {
            return nil
        }
        var components: [Substring] = []
        for component in path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            let folded = component.lowercased()
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    return nil
                }
                components.removeLast()
            default:
                guard folded != "%2e",
                      folded != "%2e%2e",
                      !folded.contains("%2f"),
                      !folded.contains("%5c"),
                      !component.contains("\\") else {
                    return nil
                }
                components.append(component)
            }
        }
        guard !components.isEmpty else {
            return nil
        }
        return components.joined(separator: "/")
    }
}

@MainActor
private final class HTMLPreviewResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let loadResource: (@MainActor (String) async throws -> Data)?
    private var loadingTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let maximumResourceByteCount = 100 * 1_024 * 1_024

    init(loadResource: (@MainActor (String) async throws -> Data)?) {
        self.loadResource = loadResource
    }

    func webView(
        _ webView: WKWebView,
        start urlSchemeTask: any WKURLSchemeTask
    ) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let relativePath = HTMLPreviewResourceURL.relativePath(from: url),
              let loadResource else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }

        loadingTasks[identifier] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                let data = try await loadResource(relativePath)
                guard !Task.isCancelled,
                      self.loadingTasks[identifier] != nil else {
                    return
                }
                guard data.count <= self.maximumResourceByteCount else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                let pathExtension = (relativePath as NSString).pathExtension
                let type = UTType(filenameExtension: pathExtension)
                let mimeType = type?.preferredMIMEType
                    ?? "application/octet-stream"
                let encoding = mimeType.hasPrefix("text/") ? "utf-8" : nil
                let response = URLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: encoding
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                self.loadingTasks.removeValue(forKey: identifier)
            } catch {
                guard !Task.isCancelled,
                      self.loadingTasks.removeValue(forKey: identifier) != nil else {
                    return
                }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        stop urlSchemeTask: any WKURLSchemeTask
    ) {
        loadingTasks.removeValue(
            forKey: ObjectIdentifier(urlSchemeTask)
        )?.cancel()
    }
}

/// A static, workspace-confined HTML preview. JavaScript and persistent
/// website data are disabled, CSP blocks all network-capable content, and
/// local resources are served only through the workspace's bounded loader.
@MainActor
public final class HTMLPreviewViewController: NSViewController, WKNavigationDelegate {
    let webView: WKWebView

    private let securedHTML: String
    private let documentURL: URL?
    private let documentRelativePath: String?
    private let isWorkspaceTrusted: () -> Bool
    private let openLocalRelativePath: ((String) -> Void)?
    private let confirmBeforeOpening: @MainActor (URL) -> Bool
    private let openExternalURL: (URL) -> Void
    private let resourceSchemeHandler: HTMLPreviewResourceSchemeHandler
    private var allowedInitialNavigation = false

    public init(
        data: Data,
        documentRelativePath: String?,
        loadLocalResource: (@MainActor (String) async throws -> Data)?,
        isWorkspaceTrusted: @escaping () -> Bool,
        openLocalRelativePath: ((String) -> Void)?,
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool,
        openExternalURL: @escaping (URL) -> Void = {
            _ = NSWorkspace.shared.open($0)
        }
    ) {
        securedHTML = HTMLPreviewDocument.securedHTML(from: data) ?? ""
        self.documentRelativePath = documentRelativePath.flatMap {
            HTMLPreviewResourceURL.documentURL(for: $0).flatMap(
                HTMLPreviewResourceURL.relativePath(from:)
            )
        }
        documentURL = HTMLPreviewResourceURL.documentURL(
            for: documentRelativePath
        )
        self.isWorkspaceTrusted = isWorkspaceTrusted
        self.openLocalRelativePath = openLocalRelativePath
        self.confirmBeforeOpening = confirmBeforeOpening
        self.openExternalURL = openExternalURL

        let resourceSchemeHandler = HTMLPreviewResourceSchemeHandler(
            loadResource: loadLocalResource
        )
        self.resourceSchemeHandler = resourceSchemeHandler

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.setURLSchemeHandler(
            resourceSchemeHandler,
            forURLScheme: HTMLPreviewDocument.resourceScheme
        )
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.setAccessibilityLabel(
            previewUIStrings.string(
                "HTML preview",
                comment: "Accessibility label for the rendered HTML preview"
            )
        )
        view = webView
        webView.loadHTMLString(securedHTML, baseURL: documentURL)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (
            WKNavigationActionPolicy
        ) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if !allowedInitialNavigation,
           navigationAction.navigationType == .other,
           navigationAction.targetFrame?.isMainFrame != false {
            allowedInitialNavigation = true
            decisionHandler(.allow)
            return
        }

        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.cancel)
            return
        }
        if let relativePath = HTMLPreviewResourceURL.relativePath(from: url) {
            if relativePath == documentRelativePath, url.fragment != nil {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            openLocalRelativePath?(relativePath)
            return
        }

        decisionHandler(.cancel)
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
              isWorkspaceTrusted() || confirmBeforeOpening(url) else {
            return
        }
        openExternalURL(url)
    }
}
