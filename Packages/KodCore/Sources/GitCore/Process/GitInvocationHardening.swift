import Foundation

/// The exhaustive allow-list of Git subcommands GitCore may ever invoke.
/// Every case is read-only. There is deliberately no `.add`, `.commit`,
/// `.checkout`, `.reset`, `.push`, `.pull`, `.fetch`, `.merge`, `.rebase`,
/// `.stash`, `.clean`, `.gc`, `.remote`, `.submodule`, `.branch` (creating
/// or deleting), `.tag` (creating or deleting), `.config --replace-all`,
/// `.worktree` (add/remove), `.reflog expire`, or `.filter-branch` case —
/// so constructing a mutating invocation from `GitReadOnlyCommand` is
/// structurally impossible, independent of any argument-level review.
/// Mirrors the same allow-list discipline `LanguageClientOutboundMethod`
/// uses for outbound LSP methods (see `MutationGuardTests`).
public enum GitReadOnlyCommand: String, CaseIterable, Sendable {
    case status
    case diff
    case blame
    case revParse = "rev-parse"
    case symbolicRef = "symbolic-ref"
    case catFile = "cat-file"
    case lsFiles = "ls-files"
    case logCommand = "log"
    case show
}

/// Builds one hardened Git invocation: a fixed global-flag prefix (applied
/// identically to every command, regardless of caller) followed by the
/// read-only subcommand and its arguments, plus a minimal, explicit
/// environment that disables every optional/interactive/network/hook/
/// lock/pager/color/replacement-object behavior SPEC 9.2 requires.
///
/// None of this is ever assembled into (or passed through) a shell
/// string: `Process.arguments` receives this exact array element-by-
/// element, so none of these values are re-parsed, glob-expanded, or
/// otherwise reinterpreted the way `/bin/sh -c` would.
public enum GitInvocationHardening {
    /// Global flags placed before the subcommand, in this fixed order.
    /// `-c` overrides here take precedence over both the user's and the
    /// repository's `.git/config`, so a hostile or unusual repository
    /// config (e.g. a checked-in `core.pager` or `diff.external`) can
    /// never re-enable a helper, hook, or lock Kod has disabled.
    public static let globalArgumentPrefix: [String] = [
        "--no-pager",
        "--no-optional-locks",
        "--no-replace-objects",
        "-c", "core.pager=cat",
        "-c", "color.ui=false",
        "-c", "color.advice=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "diff.external=",
        "-c", "interactive.diffFilter=",
        "-c", "protocol.allow=never",
        "-c", "advice.detachedHead=false",
        "-c", "advice.statusHints=false",
        "-c", "core.editor=/usr/bin/true",
        "-c", "core.askPass=/usr/bin/true",
        "-c", "credential.helper="
    ]

    /// A minimal, explicit environment — never the inherited full parent
    /// environment — so no ambient `GIT_SSH_COMMAND`, proxy, credential,
    /// or `PATH` override a user's shell happens to have set can affect
    /// the invocation. `home` is passed through only so global gitconfig
    /// and `safe.directory` resolution keep working; it is never used to
    /// build a path that gets shell-evaluated.
    public static func environment(home: String?) -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/true",
            "SSH_ASKPASS": "/usr/bin/true",
            "GIT_SSH_COMMAND": "/usr/bin/false",
            "GIT_SSH": "/usr/bin/false",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_PAGER": "cat",
            "GIT_EDITOR": "/usr/bin/true",
            "LC_ALL": "C",
            "LANG": "C"
        ]
        if let home {
            environment["HOME"] = home
        }
        return environment
    }

    /// Assembles the complete, fixed argument array for one read-only
    /// invocation: global prefix, the allow-listed command, then its
    /// arguments verbatim.
    public static func arguments(for command: GitReadOnlyCommand, arguments: [String]) -> [String] {
        globalArgumentPrefix + [command.rawValue] + arguments
    }
}

/// Why a caller-supplied revision string was refused before it could
/// reach `Process.arguments`.
public enum GitRevisionArgumentError: Error, Equatable, Sendable {
    /// Empty, or nothing but whitespace.
    case empty
    /// Begins with `-`, so Git would parse it as an option (or as the
    /// `--` separator) instead of as a revision, silently changing the
    /// meaning of the whole invocation.
    case leadingOption(String)
    /// Contains whitespace, an ASCII control character, or NUL — none of
    /// which Git accepts in a revision name, and any of which would make
    /// the argument's interpretation ambiguous.
    case invalidCharacter(String)
    /// Longer than any real revision name; refused rather than passed on.
    case tooLong(count: Int)
}

/// Validates a caller-supplied revision *before* it is placed in an
/// argument array.
///
/// Nothing in GitCore ever builds a shell string, so a revision cannot
/// inject a second command — but `Process.arguments` still lets a value
/// starting with `-` be re-read by Git itself as an option (`--reverse`,
/// `--output=…`, or a bare `--`), which would change what the invocation
/// does even though every element was passed separately. Kod's read-only
/// guarantee is structural, so it refuses such a revision outright rather
/// than relying on argument ordering to defuse it.
public enum GitRevisionArgument {
    /// Generous upper bound: far longer than any ref name, short SHA, or
    /// `HEAD@{…}` form Kod ever produces.
    public static let maximumLength = 512

    /// Returns `revision` unchanged when it is safe to pass as a single
    /// Git revision argument, or throws describing why it is not.
    public static func validated(_ revision: String) throws -> String {
        guard !revision.isEmpty, revision.contains(where: { !$0.isWhitespace }) else {
            throw GitRevisionArgumentError.empty
        }
        guard revision.utf8.count <= maximumLength else {
            throw GitRevisionArgumentError.tooLong(count: revision.utf8.count)
        }
        guard !revision.hasPrefix("-") else {
            throw GitRevisionArgumentError.leadingOption(revision)
        }
        let hasInvalidCharacter = revision.unicodeScalars.contains { scalar in
            scalar.properties.isWhitespace
                || scalar.value < 0x20
                || scalar.value == 0x7F
        }
        guard !hasInvalidCharacter else {
            throw GitRevisionArgumentError.invalidCharacter(revision)
        }
        return revision
    }
}
