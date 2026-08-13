import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubTmux

enum TmuxPresentationStyleResolver {
    static func resolve(
        preferences: TerminalAppearancePreferences,
        resolvedColors: TerminalResolvedColors?
    ) -> TmuxPresentationStyle? {
        if let spec = preferences.theme.spec {
            return TmuxPresentationStyle(
                foreground: spec.foreground.hexRGB,
                background: spec.background.hexRGB
            )
        }
        // Follow ghostty.conf. Pinning libghostty's resolved colors onto the
        // panes cannot improve on the colors the terminal already renders,
        // and costs exactness wherever the tmux client lacks RGB support, so
        // the panes are left alone and `resolvedColors` is not needed.
        return .followingTerminal
    }
}
