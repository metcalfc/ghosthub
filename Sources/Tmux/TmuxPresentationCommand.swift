/// How Ghosthub styles tmux panes.
///
/// A fixed palette pins pane colors, which also decides how tmux answers a
/// pane's OSC 10/11 queries; tmux otherwise answers them from the first
/// attached client, which can describe another terminal's theme. Pinning is
/// wrong for a palette that is by definition the attached terminal's own:
/// tmux renders a pinned color through the client's capabilities, so a client
/// without RGB support repaints the pane in the nearest 256-color
/// approximation instead of the exact color the terminal already shows.
public struct TmuxPresentationStyle: Equatable, Sendable {
    public struct PaneColors: Equatable, Sendable {
        public let foreground: String
        public let background: String

        var tmuxStyle: String {
            "fg=\(foreground),bg=\(background)"
        }
    }

    /// Colors to pin onto panes, or `nil` to leave panes rendering in the
    /// attached terminal's own colors.
    public let paneColors: PaneColors?

    public init(foreground: String, background: String) {
        paneColors = PaneColors(
            foreground: foreground,
            background: background
        )
    }

    private init(paneColors: PaneColors?) {
        self.paneColors = paneColors
    }

    /// Applies Ghosthub's session chrome and clears any pane colors it
    /// previously pinned, so panes keep exactly the colors the attached
    /// terminal renders.
    public static let followingTerminal = TmuxPresentationStyle(
        paneColors: nil
    )
}

public struct TmuxPresentationCommand: Equatable, Sendable {
    package static let identityMismatchMarker =
        "GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH"

    public let sessionName: String
    public let socketName: String?
    public let style: TmuxPresentationStyle

    public init(
        sessionName: String,
        socketName: String?,
        style: TmuxPresentationStyle
    ) {
        self.sessionName = sessionName
        self.socketName = socketName
        self.style = style
    }

    public func applyCommand(
        tmuxPath: String,
        expectedIdentity: TmuxSessionIdentity
    ) -> String {
        strictCommand(
            tmuxPath: tmuxPath,
            expectedIdentity: expectedIdentity
        )
    }

    func appendingOptions(to arguments: [String]) -> [String] {
        var result = arguments
        for (option, value) in sessionOptions {
            result += [
                ";", "set-option", "-t", target, option, value,
            ]
        }
        for option in windowOptions {
            result += [";", "set-option", "-w"]
                + option.flags
                + ["-t", target]
                + option.arguments
        }
        return result
    }

    /// Tmux interaction remains user-owned. These style resets only make tmux
    /// chrome and terminal default-color queries resolve through Ghosthub's
    /// current colors.
    func bestEffortCommand(tmuxPath: String) -> String {
        var commands = sessionOptions.map { option, value in
            let command = tmuxArguments(
                tmuxPath,
                "set-option", "-t", target, option, value
            ).map(shellQuotedCommandArgument).joined(separator: " ")
            return "\(command) >/dev/null 2>&1 || :"
        }
        let listWindows = tmuxArguments(
            tmuxPath,
            "list-windows", "-t", target, "-F", "#{window_id}"
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        let setWindowOptions = windowOptions.map { option in
            let commandPrefix = tmuxArguments(
                tmuxPath,
                ["set-option", "-w"] + option.flags + ["-t"]
            ).map(shellQuotedCommandArgument).joined(separator: " ")
            let optionArguments = option.arguments
                .map(shellQuotedCommandArgument)
                .joined(separator: " ")
            return "\(commandPrefix) \"$ghosthub_window\" "
                + "\(optionArguments) "
                + ">/dev/null 2>&1 || :"
        }.joined(separator: "; ")
        commands.append(
            "\(listWindows) 2>/dev/null | "
                + "while IFS= read -r ghosthub_window; do "
                + "\(setWindowOptions); done"
        )
        return commands.joined(separator: "; ")
    }

    private func strictCommand(
        tmuxPath: String,
        expectedIdentity: TmuxSessionIdentity
    ) -> String {
        var commands = sessionOptions.map { option, value in
            identityCheckedCommand(
                tmuxPath: tmuxPath,
                expectedIdentity: expectedIdentity,
                mutation: tmuxCommand(
                    "set-option", "-t", expectedIdentity.sessionID,
                    option, value
                )
            )
        }
        let listWindows = identityCheckedCommand(
            tmuxPath: tmuxPath,
            expectedIdentity: expectedIdentity,
            mutation: tmuxCommand(
                "list-windows", "-t", expectedIdentity.sessionID,
                "-F", "#{window_id}"
            )
        )
        commands.append("ghosthub_windows=\"$(\(listWindows))\"")
        let mismatch = shellQuotedCommandArgument(Self.identityMismatchMarker)
        commands.append(
            "if [ \"$ghosthub_windows\" = \(mismatch) ]; then "
                + "printf '%s\\n' \"$ghosthub_windows\"; exit 0; fi"
        )
        let setWindowOptions = windowOptions.map { option in
            identityCheckedCommand(
                tmuxPath: tmuxPath,
                expectedIdentity: expectedIdentity,
                shellTarget: "$ghosthub_window",
                mutation: tmuxCommand(
                    ["set-option", "-w"] + option.flags + option.arguments
                )
            )
        }.joined(separator: " && ")
        commands.append(
            "for ghosthub_window in $ghosthub_windows; do { "
                + "\(setWindowOptions); } || exit $?; done"
        )
        return commands.joined(separator: " && ")
    }

    private func identityCheckedCommand(
        tmuxPath: String,
        expectedIdentity: TmuxSessionIdentity,
        shellTarget: String? = nil,
        mutation: String
    ) -> String {
        let argumentsBeforeTarget = tmuxArguments(
            tmuxPath,
            "if-shell", "-F", "-t"
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        let checkedTarget = if let shellTarget {
            "\"\(shellTarget)\""
        } else {
            shellQuotedCommandArgument(target)
        }
        let argumentsAfterTarget = [
            expectedIdentity.formatCondition,
            mutation,
            "display-message -p "
                + shellQuotedCommandArgument(Self.identityMismatchMarker),
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return "\(argumentsBeforeTarget) \(checkedTarget) \(argumentsAfterTarget)"
    }

    private func tmuxCommand(_ arguments: String...) -> String {
        tmuxCommand(arguments)
    }

    private func tmuxCommand(_ arguments: [String]) -> String {
        arguments.map(shellQuotedCommandArgument).joined(separator: " ")
    }

    private var target: String {
        // A trailing colon makes tmux interpret `=name:` as an exact session
        // target instead of accepting a session-name prefix.
        "=\(sessionName):"
    }

    private var sessionOptions: [(String, String)] {
        [
            ("status-style", "reverse"),
            ("message-style", "reverse"),
            ("message-command-style", "reverse"),
        ]
    }

    /// One `set-option -w` Ghosthub issues per window. Flags precede the
    /// target so that unsetting keeps tmux's argument order.
    private struct WindowOption {
        let flags: [String]
        let arguments: [String]

        static func set(_ name: String, _ value: String) -> WindowOption {
            WindowOption(flags: [], arguments: [name, value])
        }

        static func unset(_ name: String) -> WindowOption {
            WindowOption(flags: ["-u"], arguments: [name])
        }
    }

    private var windowOptions: [WindowOption] {
        guard let paneColors = style.paneColors else {
            // Clearing is not the same as skipping: a session styled by an
            // earlier launch, or by a built-in theme before the user chose to
            // follow the terminal, keeps those colors pinned until something
            // unsets them.
            return [
                .unset("window-style"),
                .unset("window-active-style"),
            ]
        }
        return [
            .set("window-style", paneColors.tmuxStyle),
            .set("window-active-style", paneColors.tmuxStyle),
        ]
    }

    private func tmuxArguments(
        _ tmuxPath: String,
        _ arguments: String...
    ) -> [String] {
        tmuxArguments(tmuxPath, arguments)
    }

    private func tmuxArguments(
        _ tmuxPath: String,
        _ arguments: [String]
    ) -> [String] {
        var result = [tmuxPath]
        if let socketName, !socketName.isEmpty {
            result.append(contentsOf: ["-L", socketName])
        }
        return result + arguments
    }
}
