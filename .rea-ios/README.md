# ZEUS Browser analysis runner

This branch analyzes `cobrapk8ggg-netizen/Ios` at commit
`0542beb72680458cac6fcf365c1247324b4b2402`. It does not build this repository's
frontend or backend.

The macOS job opens and extracts the original ZIP using REA 6.7.0 over stdio
MCP, checks extracted hashes, reads the original plist files, and analyzes seven
static JavaScript excerpts. Excerpt provenance and excluded dynamic Swift
interpolation are retained in the results.

XcodeGen creates a separate project around the original Swift files, with
Kingfisher 8.6.2 and iOS 18.1. This is a build harness, not a byte-for-byte
reproduction of an original signed release. The Swift Playgrounds manifest is
retained as evidence and excluded from compilation. The harness preserves the
tracking purpose string and does not invent photo-library permissions.

If compilation succeeds, REA inspects the built app's plist, Mach-O metadata and
signature status on macOS. A second Linux job uses Ghidra 12.1.4 to analyze the
arm64 Mach-O and decompile its original LC_MAIN entry address and any selected
search, ad-block and cookie-sync symbols present in the build through MCP. The target app is not launched.
Ghidra pseudocode must not be described as original Swift source.

Every MCP response, transcript, evidence bundle, build log and unsigned analysis
IPA is retained as a workflow artifact for seven days. Failures retain the
available diagnostic output. Inspect the workflow's actual conclusion before
claiming that compilation or decompilation succeeded.

The workflow runs on pushes to `codex/rea-ios-macos-analysis` and can be run
manually once GitHub exposes the workflow dispatch entry. It uses no repository
secrets and requests only read access to repository contents.
