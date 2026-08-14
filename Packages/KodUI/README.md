# KodUI

KodUI owns stable AppKit presentation outside the `Kod` app-shell target.
Its products form this acyclic graph:

```text
KodUIComponents
├── SearchUI
├── PreviewUI
├── GitUI
└── EditorUI ──▶ PreviewUI
             └─▶ GitUI
```

Each feature target depends only on the KodCore products it imports.
No KodUI target imports `Kod`, `WorkspaceViewController`, `AppEnvironment`,
or an app coordinator. Workspace/session composition, language and Git
orchestration, and Quick Open/Command Palette panels remain in the app.
GitUI owns the immutable status-presentation index shared by its Source
Control view and the App shell's Explorer; only repository refresh
orchestration remains in `GitWorkspaceCoordinator`.

`AppearanceCenter` lives in `KodUIComponents` but is created and owned by
`AppEnvironment`; it observes the injected SettingsCore-backed theme and
font stores. Feature strings live in each target's own
`Resources/Localizable.xcstrings` and resolve through
`KodUIStringCatalog(Bundle.module)`, never `Bundle.main`.

Run the package's headless checks with:

```sh
swift test --package-path Packages/KodUI -Xswiftc -warnings-as-errors
```

`Scripts/verify-phase` runs this before the remaining `KodAppTests`.
