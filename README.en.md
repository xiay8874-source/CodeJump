# CodeJump

[简体中文](README.md) | English

<img src="Assets/AppIcon.png" alt="CodeJump icon" width="100">

A native macOS menu-bar app that turns code references in Claude, Obsidian, and other apps into navigation in **IntelliJ IDEA, VS Code, Cursor, or Zed**.

Point at a reference and press **⌥J**. CodeJump reads the available text or link, resolves it against your selected local projects, and opens your editor. Ambiguous matches get a source preview and a choice of candidates.

## Download and install

- **Download:** [latest release](https://github.com/xiay8874-source/CodeJump/releases/latest)
- **Requirements:** macOS 14 or later; the published DMG is for Apple Silicon (arm64).
- **Interface:** currently Chinese. This README provides the English usage guide.

Open the DMG, drag `CodeJump.app` into Applications, and launch it. Add the project folders you want to search, select an editor, and enable CodeJump under **System Settings → Privacy & Security → Accessibility**.

The release uses a persistent local signing certificate. It is **not Apple Developer ID signed or notarized**. On another Mac, first launch may require Apple's normal app-approval flow in System Settings. The signing private key is never included in the download.

CodeJump stays in the menu bar; a Dock icon is not required. Closing its settings window leaves it running. Once projects are configured, use the menu bar or **⌥H** to reopen the home window.

## Everyday use

| Shortcut | Action |
| --- | --- |
| **⌥J** | Resolve the code reference under the pointer or selected text |
| **⌥P** | Search and switch projects |
| **⌥H** | Show or hide the home/settings window |

Settings can change all three shortcuts to **⌘⌥J / ⌘⌥P / ⌘⌥H**. Each shortcut is registered independently.

1. Enable the projects that should participate in searches; optionally add aliases.
2. Point at a file, class, method, or supported link and press **⌥J**.
3. A unique, verified match can open directly. Multiple projects, overloads, or uncertain positions show candidates with a code preview.
4. Choose with the arrow keys and Return, or a number key; press Esc to cancel.

The project switcher prioritizes confirmed open IDEA windows and otherwise asks the editor to open the project. Identically named projects or worktrees are not guessed from recent usage.

Manual entry and the menu-bar clipboard action work without Accessibility permission. Clipboard contents are read only when you invoke that action; hover lookup does not modify the clipboard. Removing a project only removes its search scope, not its files.

## Supported references

```text
src/main/java/com/example/Foo.java:128
src/main/java/com/example/Foo.java:128:8
Foo.java#L128-L140
Foo#process
com.example.Foo.process
```

Markdown links can keep visible text short while preserving a complete relative path:

```markdown
[Foo#process](src/main/java/com/example/Foo.java:128)
[shop-app / Foo#process](src/main/java/com/example/Foo.java:128)
```

Use the project name only for cross-project references or when needed to disambiguate. Class names, paths, and line numbers should match the actual source. Ordinary clicking is still controlled by the source app; use **⌥J** for CodeJump lookup.

Local `file:///` links and the optional custom URL scheme are supported:

```text
codejump://open?project=shop-app&path=src/main/java/com/example/Foo.java&line=128
```

A custom URL always opens a target preview before navigation. It cannot execute commands or open network files. Hosted `https://` source links are not automatically mapped to local repositories.

Local Java resolution checks method declarations and their owning classes, including nested classes. Comments, strings, and method calls are excluded. Overloads remain candidates; stale line numbers that conflict with a method's current location require confirmation. Other languages support file, line, and column navigation.

Bare method-name search requires the optional IDEA companion. Without it, include the owning class, such as `Foo#process`. A sufficiently long abbreviated class name may produce explicitly marked suffix candidates; it is not treated as an exact match. When a placeholder replaces the leading directories, such as `S/helper/Foo.java`, the remaining path is matched and shown as a candidate to confirm.

## Claude Code reference rules

Open **Claude 代码引用 → 安装 / 编辑规则…** on the home screen to install, edit, reset, or remove a short reference-format instruction for Claude Code.

- Rules are written to the global `~/.claude/CLAUDE.md` only when you save. Start a new Claude Code session to load them.
- CodeJump manages only the block between `<!-- CodeJump:begin -->` and `<!-- CodeJump:end -->`, preserving unrelated instructions.
- Existing content is backed up under `~/.claude/codejump-backups/` before saving or removing rules.
- Concurrent external changes are detected rather than overwritten. Resetting to the recommendation changes the draft until you save.

This configures Claude **Code** instructions, including its desktop Code mode. It does not change ordinary Claude chat preferences, model routing, or account settings. The recommended rules ask for concise symbol labels and absolute-path links without invented path abbreviations in conversation replies, so references stay exact when several git worktrees of one repository are open; files, commit messages, PR descriptions, and shared documents still use relative paths. Model compliance is not guaranteed. The editor lets you customize the rules, including their language.

## Optional IDEA companion

The **CodeJump Companion 0.2.2** plugin targets **IntelliJ IDEA 2026.1 (261.*)**. Download its ZIP from the release, then use **Settings → Plugins → gear menu → Install Plugin from Disk**. Restart IDEA if requested, and enable **使用可选 IDEA 插件** in CodeJump.

If no connection appears, run **Tools → Start CodeJump Bridge** in IDEA. The target project must be open. Local file lookup remains available when the plugin is disabled, disconnected, or IDEA is indexing.

The companion uses Java PSI for classes, bare method names, overload parameter types, inherited methods, and source or decompiled declarations from dependency JARs. For example:

```text
java.lang.String.substring(int, int)
java.util.ArrayList.stream()
```

PSI results always show candidates before opening the current declaration. The bridge listens only on a random `127.0.0.1` port, requires a per-process token, and rejects browser Origin requests. Its endpoint file is restricted to the current user; navigation targets are revalidated inside IDEA.

## Privacy and limits

- Resolution and indexing run locally, without an AI service or code uploads. CodeJump does not inject into Claude or rewrite conversations.
- Accessibility reading happens on shortcut activation, with bounded capture and retries; it does not continuously track the pointer.
- Only enabled project roots are indexed. Repository internals, dependency/build folders, binary files, and symlink directories are excluded.
- Ambiguous or unavailable Accessibility text may require selecting text or using manual entry. Source apps determine which link and text information they expose.
- Projects, preferences, recent navigation, and the index cache live under `~/Library/Application Support/CodeJump/`.
- Recognition diagnostics stay in memory unless you explicitly export feedback. Feedback is saved locally and can contain captured text and project paths; inspect it before sharing.
- Files and project boundaries are checked again before opening. Editor processes receive argument arrays, not assembled shell commands.

Recent navigation records mean the request was sent, not that an editor confirmed rendering the destination. CodeJump does not automatically restart an unresponsive IDE.

## Build from source

Requires macOS 14+, **Swift 6**, Apple Command Line Tools, and Python 3. The Swift package has no third-party package dependencies.

```sh
git clone https://github.com/xiay8874-source/CodeJump.git
cd CodeJump
./script/test.sh
./script/build_and_run.sh --build-only
```

The app is produced at `dist/CodeJump.app`. Build-only mode permits ad-hoc signing for temporary testing. Such builds should not replace an installed app if you want its Accessibility authorization to remain stable.

For repeatable local installation, explicitly choose to create and import your own persistent signing identity:

```sh
python3 script/local_signing.py --prepare
python3 script/local_signing.py --install
./script/build_and_run.sh --install
```

`--prepare` creates private local material; `--install` imports a persistent, non-exportable private key into your user keychain and removes the temporary key file. Handle any macOS keychain confirmation yourself. The script does not change system root certificates or TLS trust. This identity is for local signing, not Developer ID distribution or notarization.

Installation requires the persistent identity and backs up an existing CodeJump app to `output/backups/`. Switching signing identities may require granting Accessibility permission again; subsequent builds reuse the same certificate and bundle identity.

Build the companion against an installed IDEA SDK, then optionally package the already-built app and plugin:

```sh
python3 idea-plugin/build.py
python3 script/package_dmg.py
```

Set `CODEJUMP_IDEA_APP` if IDEA is installed outside `/Applications/IntelliJ IDEA.app`. Packaging produces a DMG and SHA-256 file under `dist/`; it refuses to overwrite an existing release image.

## Project structure and contributions

- `Sources/CodeJumpCore`: reference parsing, project indexing, Java resolution, launch plans, and managed Claude instructions.
- `Sources/CodeJump`: SwiftUI/AppKit interface, Accessibility capture, global shortcuts, and editor integration.
- `Sources/codejump-cli`: command-line resolution and benchmarks.
- `idea-plugin`: optional Java PSI bridge; `Tests/CodeJumpCoreTests`: parser and behavior regression coverage.

Issues and pull requests are welcome. For recognition bugs, include a minimal reference, source app/editor versions, expected result, and anonymized sample source. Remove private paths, captured conversation text, and credentials before sharing diagnostics. Run `./script/test.sh` for changes that affect behavior.

## License

Released under the [MIT License](LICENSE).
