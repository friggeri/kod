import Foundation

/// Builds the fixed `rg --json` argument array for a `SearchQuery`.
///
/// This is a pure function precisely so it can be unit-tested without
/// launching a process, and so `WorkspaceTextSearcher` never assembles or
/// interprets a shell string: every argument here is passed to `Process`
/// as a discrete array element.
public enum RipgrepArguments {
    /// Kod always forces `.git` out of results, even when the caller asks
    /// to include otherwise-ignored files, matching `WorkspaceScanner`'s
    /// unconditional `.git` exclusion.
    public static let forcedExcludeGlob = "!/.git/**"

    public static func build(for query: SearchQuery) -> [String] {
        var arguments: [String] = [
            "--json",
            "--line-number",
            "--no-heading",
            "--color=never",
            "--no-config",
            // Deterministic, path-ordered streaming: results always arrive
            // grouped and ordered by relative path, which both keeps the
            // Search sidebar's file grouping stable across runs and makes
            // ordering behavior testable.
            "--sort=path",
            // Ripgrep only honors .gitignore/.ignore by default when it
            // detects an actual VCS repository (a `.git` directory). SPEC
            // 8.2 requires ignore-file behavior for any workspace, Git or
            // not, so this is unconditional rather than tied to any option.
            "--no-require-git"
        ]

        if !query.options.matchCase {
            arguments.append("--ignore-case")
        }
        if query.options.wholeWord {
            arguments.append("--word-regexp")
        }
        if !query.options.useRegex {
            arguments.append("--fixed-strings")
        }
        if query.options.includeHidden {
            arguments.append("--hidden")
        }
        if query.options.includeIgnored {
            arguments.append("--no-ignore")
        }

        for glob in query.options.includeGlobs {
            arguments.append(contentsOf: ["--glob", glob])
        }
        for glob in query.options.excludeGlobs {
            arguments.append(contentsOf: ["--glob", "!\(glob)"])
        }
        // Appended last so it always wins over any earlier glob (ripgrep,
        // like .gitignore, resolves conflicting globs last-match-wins).
        arguments.append(contentsOf: ["--glob", forcedExcludeGlob])

        arguments.append(contentsOf: ["-e", query.pattern])
        arguments.append("--")
        // "." rather than the absolute root path: ripgrep anchors a
        // leading-`/` `--glob` pattern (like the forced `.git` exclusion
        // above) to the search argument's own root, and that anchor only
        // lines up reliably with `Process.currentDirectoryURL` (also set to
        // `query.root`) when the search argument is the relative root ".".
        // Passing the absolute path here instead measurably breaks
        // root-anchored exclude globs.
        arguments.append(".")
        return arguments
    }
}
