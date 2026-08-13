import Foundation

public enum LibghosttyEmbeddedResourcesLocator {
    /// A place the emitted libghostty `share` tree can live, relative to a
    /// candidate root. The compiled terminfo entry is the sentinel proving
    /// the tree is a real resource bundle rather than a same-named directory.
    private struct Layout {
        let resources: [String]
        let terminfoSentinel: [String]

        init(prefix: [String]) {
            resources = prefix + ["ghostty"]
            terminfoSentinel = prefix + ["terminfo", "78", "xterm-ghostty"]
        }
    }

    private static let layouts = [
        // Repo-local bootstrap output.
        Layout(prefix: [".build", "libghostty", "source", "zig-out", "share"]),
        // Packaged Ghosthub.app bundle.
        Layout(prefix: ["Contents", "Resources"]),
    ]

    public static func configureEnvironmentIfNeeded(
        executablePath: String = ProcessInfo.processInfo.arguments.first ?? "",
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> URL? {
        if let existing = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
           !existing.isEmpty {
            return URL(fileURLWithPath: existing, isDirectory: true)
        }

        guard let resourcesURL = resolveResourcesDirectory(
            executablePath: executablePath,
            currentDirectoryPath: currentDirectoryPath
        ) else {
            return nil
        }

        setenv("GHOSTTY_RESOURCES_DIR", resourcesURL.path, 1)
        return resourcesURL
    }

    static func resolveResourcesDirectory(
        executablePath: String,
        currentDirectoryPath: String
    ) -> URL? {
        let roots = candidateRoots(
            executablePath: executablePath,
            currentDirectoryPath: currentDirectoryPath
        )

        for root in roots {
            for layout in layouts {
                let resourcesURL = root.appendingPathComponents(layout.resources)
                let terminfoURL = root.appendingPathComponents(layout.terminfoSentinel)
                guard FileManager.default.fileExists(atPath: resourcesURL.path),
                      FileManager.default.fileExists(atPath: terminfoURL.path)
                else { continue }
                return resourcesURL
            }
        }

        return nil
    }

    static func candidateRoots(
        executablePath: String,
        currentDirectoryPath: String
    ) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()

        func appendAncestors(of path: String) {
            guard !path.isEmpty else { return }

            var currentURL = URL(fileURLWithPath: path, isDirectory: true)
            if !path.hasSuffix("/") {
                currentURL.deleteLastPathComponent()
            }

            while true {
                let standardized = currentURL.standardizedFileURL.path
                if seen.insert(standardized).inserted {
                    roots.append(currentURL)
                }

                let parent = currentURL.deletingLastPathComponent()
                if parent.path == currentURL.path {
                    break
                }
                currentURL = parent
            }
        }

        appendAncestors(of: executablePath)
        appendAncestors(of: currentDirectoryPath + "/")

        return roots
    }
}

private extension URL {
    func appendingPathComponents(_ components: [String]) -> URL {
        components.reduce(self) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }
}
