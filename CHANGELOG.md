# Changelog

## 1.3.1 (2026-10-06)

* New icon: ⌘C in white inside a key with a pink-to-violet outline, on graphite. The ⌘ sign and the C are drawn as paths, and the ⌘C group is centered in the key from its measured outline.
* "Hold ⌘V to open Clippa" starts by itself as soon as the Accessibility permission is granted.

## 1.3.0 (2026-10-06)

* Hold ⌘V to open Clippa (Settings → Shortcuts, off by default): a quick ⌘V still pastes, holding it opens the shelf. It starts by itself as soon as the Accessibility permission is granted.
* Selecting several items shows a bar to paste, pin or delete them together; the right-click menu says how many items it deletes, and deleting 10 or more asks first.
* Closing the shelf while a confirmation is open now cancels it, and Escape cancels a confirmation instead of closing the shelf (this also fixes "Delete Pinboard…").
* The ⌘V that Clippa sends is marked as its own, so Paste Stack no longer swaps it for a stack item.

## 1.2.5 (2026-10-05)

* build.sh calls the Swift compiler directly instead of Swift Package Manager, so Clippa builds even where SwiftPM's own files are broken (a user's Command Line Tools failed to link the package manifest). Package.swift stays for development and tests.
* With Apple's Command Line Tools alone, the macOS 27 SDK cannot build SwiftUI's `@State` (its macro plugin ships only with Xcode): build.sh checks the SDK and falls back to the previous one included with the tools.

## 1.2.4 (2026-10-05)

* Builds with older developer tools: the package manifest now needs Swift 5.9 (Xcode 15 or its Command Line Tools) instead of a recent Swift 6, and the macOS 15.4 clipboard-permission check no longer needs the macOS 15.4 SDK. Reported by a user whose Command Line Tools could not read `swiftLanguageModes`.
* install.sh checks the Swift version first and explains what to update when the build fails.

## 1.2.3 (2026-10-04)

* `tools/make-local-signing.sh` creates a local signing certificate (no Apple account needed) that `build.sh` uses by itself, so macOS keeps the Accessibility permission across updates.

## 1.2.2 (2026-10-04)

* Icon centering reworked from measurements: the C is a little more closed and its circle and card sit together, slightly right of center, so no reference (outline, mass, circle, card) is more than 22 points off on a 1024-point canvas.

## 1.2.1 (2026-10-04)

* New icon: a white C holding a copied card, on a pink-to-violet gradient, centered on its real outline.

## 1.2.0 (2026-10-04)

* Opening Clippa by hand (from Applications, Spotlight or Launchpad) shows the shelf, like Paste; at login it stays in the menu bar. The shelf also appears right after the first-launch setup.
* When Clippa itself is in front, items are pasted into the app whose window is on top.

## 1.1.0 (2026-10-04)

* Sounds when something is copied and when Clippa pastes, on by default, like Paste. Choose your own sound files in Settings → General.
* The Accessibility alert shows once per launch, then a short reminder, and explains what to do when Clippa is switched on but macOS remembers an older build.
* Copies are processed in the background, so big images never freeze the interface.
* "Delete after…" rules are applied every 5 minutes.
* Settings warns when another app already uses one of Clippa's shortcuts.

## 1.0.0 (2026-10-04)

First release.

* Clipboard history in a bar at the bottom of the screen (⇧⌘V), with cards for text, rich text, links (with previews), images, files and colors.
* Keep History (1 day, 1 week, 1 month, 1 year, forever) plus a Keep rule for each item.
* Search as you type, including text recognized in images; filters by type, app, date and Mac.
* Pinboards, Quick Paste (⌘1 to ⌘9), plain text paste, multiple selection, Paste Stack (⇧⌘C).
* Edit, rename, preview, rotate images, undo deletions, drag and drop.
* Suggestions for the app you are pasting into, with Apple Intelligence where available.
* MCP server for AI tools (Claude Code, Claude Desktop, Cursor and others).
* Sync between Macs through iCloud Drive or any synced folder, with a "pinboards only" mode.
* Privacy rules: confidential and transient content, ignored apps, pause.
* English and Italian.
