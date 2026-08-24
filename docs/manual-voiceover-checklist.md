# Manual VoiceOver and accessibility verification checklist (Phase 11)

This checklist covers the parts of Kod's accessibility, keyboard, and
appearance support that **cannot be verified by an automated agent** in
this environment. `Scripts/verify-phase 11` deliberately never launches
`KodAppUITests`, `XCUIApplication`, AppleScript, or any other tooling that
drives the mouse/keyboard/Accessibility APIs as an automation client —
see that script's comments for why this is a permanent constraint, not a
temporary gap.

Everything below must be performed **by a human**, on a real Mac, with a
real VoiceOver session, before each release. Nothing in this document has
been executed by any automated process; do not treat prior headless test
runs (`CodeViewportAccessibilityTests`, `DiagnosticsCoreTests`, KodAppTests'
accessibility/keyboard-registry/zoom-appearance suites) as a substitute for
this checklist — they prove the underlying AppKit accessibility API
*contracts* (roles, labels, values, ranges, rotor item models) are
implemented correctly in isolation, not that a real screen-reader user can
actually complete Kod's primary workflows end to end.

## Setup

1. A clean build of the `Kod` scheme (`Release` configuration recommended,
   since it is what ships).
2. System Settings → Accessibility → VoiceOver turned on (⌘F5), or
   Accessibility Inspector's own "Enable VoiceOver" for a more forgiving
   debugging session.
3. A non-trivial test workspace containing: at least one file with a
   syntax error (for a diagnostic), at least one foldable region, at
   least one uncommitted Git change (added/modified/deleted), and a
   Markdown, image, and JSON file (for preview checks).

## 1. CodeViewport accessibility

- [ ] Navigate into the code viewport with VoiceOver and confirm it
      announces as a read-only text area (role + "read-only source code"
      role description), not as an editable text field.
- [ ] Use VoiceOver's rotor (VO-U) and confirm **Symbols**, **Diagnostics**,
      **References**, **Folds**, and **Git Changes** rotors are present
      whenever the corresponding data exists in the open file, and are
      *absent* (not empty/blank entries) when it does not.
- [ ] Move through the Diagnostics rotor and confirm each item announces
      severity + message, and activating an item moves the VoiceOver
      cursor/selection to the corresponding line.
- [ ] Move through the Symbols rotor and confirm each entry announces a
      real symbol kind (e.g. "function", "class") and name.
- [ ] Move through the Git Changes rotor and confirm each entry announces
      the change kind (added/modified/deleted) — never color-only.
- [ ] Select a range of text with VoiceOver's text navigation and confirm
      "read selected text"/interact-with-text gestures return exactly the
      selected source text, including across a line containing emoji or
      other multi-UTF-16-unit characters.
- [ ] Toggle a fold closed/open and confirm VoiceOver announces the
      collapsed/expanded state change on the Folds rotor entry.
- [ ] Confirm VoiceOver announces line numbers as you move by line
      (VO-Down/Up or line navigation), matching the visible gutter.

## 2. App shell accessibility

- [ ] Activity bar: confirm VoiceOver announces one "Activity" group above
      the sidebar content with
      Explorer, Search, Source Control, and Problems in that order.
      Each destination must announce "Selected" or "Not selected"; the current
      destination must remain distinguishable with Differentiate Without
      Color enabled.
- [ ] Activity bar keyboard behavior: Tab into the bar, move among all four
      destinations with arrow keys, and activate each with Space and Return.
      Activating the selected destination must move focus into its primary
      control rather than collapsing the sidebar.
- [ ] Collapse the sidebar with Toggle Sidebar, then invoke each Show/Search
      surface command from the menu or Command Palette. Confirm the whole
      activity-bar-and-content pane reappears and focus lands in the requested
      surface.
- [ ] Explorer: navigate the file tree with VoiceOver and confirm each row
      announces file/folder name and Git status (if any) as text, not
      just a colored badge.
- [ ] Tabs: confirm each open tab announces its file name and pinned/
      preview/dirty state, and that each tab's close button announces
      "Close <filename>" distinctly (not just "Close").
- [ ] Split groups: with two or more split groups open, confirm VoiceOver
      can distinguish which group is active.
- [ ] Problems panel: confirm each row announces severity as a word
      ("Error"/"Warning"/etc.), not color alone, plus file/line/message.
- [ ] Search panel: run a search, confirm results announce file/line/match
      text, and confirm a cancelled or truncated search state is announced
      (not just shown visually).
- [ ] Source Control panel: confirm each entry's change kind is announced
      as text.
- [ ] Workspace trust: confirm the banner is announced only on the first
      open, its dismiss button is last, and the status-bar trust indicator
      announces the current state and opens a labeled confirmation prompt.
- [ ] Status bar: confirm VoiceOver announces one "Workspace status" group.
      Verify branch or full detached-HEAD identity, Git change count and
      staged/unstaged/untracked/conflicted breakdown, language-server profile
      and lifecycle state, language, encoding, line endings, one-based line
      and column, UTF-16 selection count, and trust state whenever each value
      is available.
- [ ] Change branches and detach HEAD with an external Git client, introduce
      and remove working-tree changes, and trigger a failed Git refresh.
      Confirm the status bar updates after each refresh and says Git is
      unavailable on failure rather than announcing a clean repository.
- [ ] Exercise every language-server lifecycle state available in the test
      setup. Confirm the state icon is spoken as text and becomes an enabled
      remediation action only for actionable states, with a clear label and
      tooltip.
- [ ] Switch active editor splits and select text containing emoji. Confirm
      line/column and selection count follow only the active split and count
      the emoji in UTF-16 code units. Preview and full-diff tabs must retain
      file metadata without announcing a fabricated cursor; Quick Diff must
      report its visible cursor.
- [ ] Settings window: confirm the permanent sidebar is announced as one
      navigation list with Editor and Languages sections, cannot be collapsed,
      and every control has a meaningful label rather than a bare identifier
      or "button".
- [ ] Font settings: open the family popover, confirm search receives focus,
      navigate the filtered monospaced-family results, and verify the selected
      family and per-family operator previews are announced before activation.
- [ ] Change family, weight, size, ligatures, line height, and letter spacing.
      Confirm each value is announced, persists immediately, and updates an
      open editor without moving focus.
- [ ] Languages settings: navigate the shipped-language section and confirm
      each row announces its name and language-server status. Selecting a row
      must update the stable detail pane.
- [ ] In a selected language detail, confirm Syntax Only, Checking, Ready, and
      Not Installed are announced as text rather than color alone. Edit
      the multiline Command field (including a wrapped or newline-separated
      command) and, for a missing server, confirm Check Again, every copyable
      install command, and the official documentation link are keyboard
      reachable.
- [ ] Diff/blame viewers: confirm added/removed/modified line markers are
      announced as text, and blame annotations announce author/date/
      commit summary.
- [ ] Previews: open a Markdown, image, and JSON/plist file; confirm the
      window-toolbar Source/Preview toggle, zoom controls, transparency toggle, and
      remote-image opt-in are all announced with their current state.

## 3. Keyboard-only workflow

Unplug the mouse/trackpad (or simply do not touch it) and, using only the
keyboard:

- [ ] Open a workspace, use Quick Open to jump to a file, use Find in File
      and Go to Line, open the Problems/Search sidebars, open a
      diff/blame view, and toggle a preview — confirm every step is
      reachable via a discoverable menu command or a documented shortcut,
      with visible focus at every stop (never a focus state that only a
      sighted color-highlight communicates).
- [ ] Confirm every command exercised above also exists as a real, enabled
      native menu item (Menu Bar), not just a raw keyboard shortcut.

## 4. Zoom, motion, and contrast

- [ ] In Settings → Font, increase the font size to its maximum (300%-plus
      of the default) and confirm the code viewport, its line-number
      gutter, and the Settings UI itself do not clip or truncate content.
- [ ] In System Settings → Accessibility, enable "Reduce Motion" and
      confirm Kod's own transitions (panel show/hide, etc.) become
      immediate/non-animated.
- [ ] Enable "Increase Contrast" and confirm Kod's bundled high-contrast
      themes are offered/preferred and meet a visibly higher contrast bar.
- [ ] Enable "Differentiate Without Color" and confirm diff markers and
      diagnostic severities remain distinguishable (via the text labels
      already covered above, and any additional shape/icon cues).
- [ ] Change the system accent color and confirm Kod's selection/highlight
      colors follow it rather than a hardcoded blue.
- [ ] Enable Reduce Transparency and switch between light, dark, and
      increased-contrast appearances. Confirm the activity bar and 30-point
      status bar remain legible, with a visible focus outline and native
      monochrome status foregrounds.

## 5. Localization infrastructure sanity check

- [ ] With a Debug build, use Xcode's "Pseudolocalization" scheme option
      (Edit Scheme → Run → Options → Application Language →
      "Double-Length Pseudolanguage") at the 640-point minimum window width.
      Confirm the centered status bar preserves branch, Git, file type/LSP
      icon, cursor, and trust; hides line endings and then encoding as needed;
      and middle-truncates the branch while its full value remains available
      as help/tooltip text.

---

Record the date, macOS version, and Kod build/commit tested against each
time this checklist is run, and file any finding as a normal issue —
this document intentionally has no digital sign-off mechanism, since its
entire purpose is to require an actual human accessibility pass.
