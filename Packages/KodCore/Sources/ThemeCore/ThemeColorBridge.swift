import TextDecorationModel

/// `ThemeColor` is defined in `TextDecorationModel` so the parser, the LSP
/// transport, and any other non-presentation target can describe colored
/// decoration runs without depending on the theme schema. `ThemeCore` owns
/// the theme *schema* that is built out of those colors, so it re-exposes
/// the type under its historical name: existing `import ThemeCore` clients
/// keep compiling unchanged, and new code that only needs colors can
/// `import TextDecorationModel` instead.
public typealias ThemeColor = TextDecorationModel.ThemeColor
