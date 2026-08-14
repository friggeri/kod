import AppKit

/// A read-only `NSTextView` and the `NSScrollView` that hosts it,
/// already wired together by `makeReadOnlyScrollingTextView(wrapsLines:)`.
///
/// Deliberately not `Sendable`: both members are main-actor AppKit
/// views, and the type carries that isolation with it.
@MainActor
public struct ReadOnlyScrollingTextView {
    public let scrollView: NSScrollView
    public let textView: NSTextView
}

/// Applies Kod's shared read-only text presentation to `textView` and
/// installs it as `scrollView`'s document view.
///
/// This is the configuration every non-editing text surface in the app
/// uses (the Git diff viewer, the inline diff popover, and the Markdown
/// preview today; more `KodUI` targets later), kept in one place so
/// "read-only" cannot drift between them:
///
/// - Content is never editable and always selectable — read-only means
///   the text cannot be *changed*, not that it cannot be read or copied
///   (the same contract `CodeViewport` states for the source viewport).
/// - The text view resizes vertically with its content, and
///   horizontally only when lines do not wrap.
/// - When `wrapsLines` is `true`, the text container tracks the view's
///   width and the horizontal scroller is suppressed; when it is
///   `false`, the container is unbounded horizontally and the
///   horizontal scroller is shown.
///
/// Callers may override individual properties afterwards (for example a
/// tighter `textContainerInset`); this only establishes the shared
/// baseline.
@MainActor
public func configureReadOnlyScrollingTextView(
    _ textView: NSTextView,
    in scrollView: NSScrollView,
    wrapsLines: Bool
) {
    textView.isEditable = false
    textView.isSelectable = true
    let contentSize = NSSize(
        width: max(scrollView.contentSize.width, 1),
        height: max(scrollView.contentSize.height, 1)
    )
    textView.frame = NSRect(origin: .zero, size: contentSize)
    textView.minSize = NSSize(width: 0, height: contentSize.height)
    textView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = !wrapsLines
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
        width: wrapsLines ? contentSize.width : CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = wrapsLines
    textView.textContainerInset = NSSize(width: 10, height: 8)
    scrollView.documentView = textView
    scrollView.hasHorizontalScroller = !wrapsLines
}

/// Builds a new read-only text surface: a fresh `NSTextView` configured
/// by `configureReadOnlyScrollingTextView(_:in:wrapsLines:)` inside a
/// fresh, Auto Layout-ready `NSScrollView`, with the read-only role
/// description assistive technologies announce.
///
/// Existing call sites that already own their text view keep calling
/// `configureReadOnlyScrollingTextView(_:in:wrapsLines:)` directly; this
/// is the constructor for new read-only surfaces.
@MainActor
public func makeReadOnlyScrollingTextView(wrapsLines: Bool) -> ReadOnlyScrollingTextView {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    configureReadOnlyScrollingTextView(textView, in: scrollView, wrapsLines: wrapsLines)
    textView.setAccessibilityRoleDescription(
        KodUIStringCatalog.components.string(
            .readOnlyTextAccessibilityRoleDescription,
            comment: "Role description announced for a read-only text area"
        )
    )
    return ReadOnlyScrollingTextView(scrollView: scrollView, textView: textView)
}
