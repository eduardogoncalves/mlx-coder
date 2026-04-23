// Sources/AgentCore/AgentLoop+BuildCheck.swift
// Build checking logic for agent/coding mode.

import Foundation

extension AgentLoop {

    /// Perform automated build check after file modifications in agent/coding mode.
    /// This checks for build errors and attempts fixes if needed.
    func performBuildCheckIfNeeded(modifiedPaths: Set<String>) async {
        guard shouldRunBuildCheck(for: modifiedPaths) else {
            renderer.printStatus("⏭️  Skipping build check: only non-build files were modified")
            return
        }

        renderer.printStatus("🔧 Checking builds in agent/coding mode...")
        
        let success = await buildCheckManager.checkBeforeCommit(
            workspace: permissions.effectiveWorkspaceRoot,
            onProgress: { msg in
                // Progress updates from Ralph loop
                self.renderer.printStatus("  → \(msg)")
            },
            streamRenderer: renderer
        )
        
        if success {
            renderer.printStatus("✅ Build check passed - ready for commit!")
        } else {
            // Build check failed even after fix attempts - inform user
            renderer.printStatus("⚠️  Build has errors that need manual fixing")
            renderer.printStatus("Use build_check tool for detailed error information, then fix and commit.")
        }
    }

    func shouldRunBuildCheck(for modifiedPaths: Set<String>) -> Bool {
        modifiedPaths.contains { isBuildRelevantPath($0) }
    }

    func isBuildRelevantPath(_ path: String) -> Bool {
        let normalized = path.lowercased()
        let fileName = URL(fileURLWithPath: normalized).lastPathComponent
        let ext = URL(fileURLWithPath: normalized).pathExtension

        let buildRelevantExtensions: Set<String> = [
            "swift", "c", "cc", "cpp", "cxx", "h", "hpp", "hh", "m", "mm",
            "rs", "go", "java", "kt", "kts", "cs", "ts", "tsx", "js", "jsx",
            "py", "rb", "php", "scala"
        ]

        if buildRelevantExtensions.contains(ext) {
            return true
        }

        let buildRelevantFiles: Set<String> = [
            // Swift/C/C++
            "package.swift", "package.resolved", "makefile", "cmakelists.txt",

            // Node.js / TypeScript
            "package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml",
            "yarn.lock", "tsconfig.json", "tsconfig.base.json", "vite.config.js", "vite.config.ts",
            "webpack.config.js", "webpack.config.ts", "next.config.js", "next.config.mjs",
            "nuxt.config.js", "nuxt.config.ts", "rollup.config.js", "rollup.config.ts",
            "eslint.config.js", ".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json",

            // .NET / C#
            "global.json", "nuget.config", "directory.build.props", "directory.build.targets",

            // JVM / Rust / Go / Python
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
            "pom.xml", "cargo.toml", "cargo.lock", "go.mod", "go.sum",
            "requirements.txt", "pyproject.toml", "poetry.lock", "pdm.lock"
        ]

        if buildRelevantFiles.contains(fileName) {
            return true
        }

        // Project-level manifests that carry semantics through suffixes.
        if fileName.hasSuffix(".csproj") || fileName.hasSuffix(".vbproj") || fileName.hasSuffix(".fsproj") || fileName.hasSuffix(".sln") {
            return true
        }

        // Generic CI/build pipelines may impact build success.
        if fileName == "dockerfile" || fileName.hasPrefix("dockerfile.") {
            return true
        }

        return false
    }
}
