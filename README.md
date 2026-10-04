<p align="center"><img src="Resources/icon.png" width="160" alt="Clippa icon"></p>

# Clippa

*Leggi in italiano: [README.it.md](README.it.md)*

A clipboard manager for macOS. Clippa keeps everything you copy (text, links, images, files and colors) for as long as you choose, and brings it back with **⇧⌘V**. Free and open source, built to work like [Paste](https://pasteapp.io), with your data on your own Macs.

Clippa is an independent project, not affiliated with Paste or its makers.

## What it does

* **Clipboard history** in a bar at the bottom of the screen, newest first. Each card shows a preview, the app it came from (with its color) and when you copied it.
* **Keep history for as long as you want**: 1 day, 1 week, 1 month, 1 year or forever. **Each item can also have its own rule**: delete it after an hour, a day, a week, a month, a year, or keep it forever.
* **Search** as you type, across text, link titles, app names and **text inside images** (recognized on your Mac). Filters by type, app, date and Mac.
* **Pinboards**: named, colored collections for what you reuse. Pinned items never expire.
* **Paste straight into the app you are using**, or as plain text, or several items at once. **Quick Paste** with ⌘1 to ⌘9.
* **Paste Stack** (⇧⌘C): copy several things, then paste them one by one, in order.
* **Edit and rename** items before pasting; rotate images; copy the text of an image.
* **Suggestions** (✦): the items that fit the app you are pasting into, ranked on your Mac, with Apple Intelligence when available.
* **AI tools**: Claude, Codex, Cursor and other MCP clients can search your history, if you allow it.
* **Sync between Macs** through iCloud Drive (or any synced folder), with a "pinboards only" mode.
* **Sounds** when you copy and when Clippa pastes; pick your own sound files in Settings.
* **Privacy**: passwords and apps you choose are never saved. Pause Clippa at any time.

The app is in English, with an Italian translation that macOS picks automatically when your Mac is set to Italian.

## Install

You need macOS 14 Sonoma or later and Apple's developer tools. If you don't have them, install them for free with `xcode-select --install`.

Three ways, pick one. All of them build Clippa on your own Mac, so no Apple signature is needed and no security warning shows up.

### 1. One command

```sh
curl -fsSL https://raw.githubusercontent.com/massimodascola/clippa/main/install.sh | sh
```

Downloads the source, builds it, copies Clippa to Applications and launches it. The script is [install.sh](install.sh): read it first if you want to know what it does.

### 2. Homebrew

```sh
brew install massimodascola/tap/clippa
clippa-install
```

Homebrew builds Clippa but cannot copy apps into Applications on its own: the `clippa-install` command does that.

### 3. From source

```sh
git clone https://github.com/massimodascola/clippa.git
cd clippa
sh build.sh --install
```

Without `--install`, `build.sh` only builds `build/Clippa.app`.

### First launch: two permissions

* **Read the clipboard.** Since macOS 15.4, macOS asks before an app reads the clipboard by itself. The first time you copy something, choose **Always Allow** (or set it in System Settings → Privacy & Security → Paste from Other Apps).
* **Paste into your apps.** To paste straight into the app you are using, allow Clippa in System Settings → Privacy & Security → Accessibility (called *Device Control and Data Access* on macOS 27). Clippa only uses it to press ⌘V (and to watch ⌘V while Paste Stack is on). Without it, Clippa copies the item and you press ⌘V yourself.

If you use Paste too, quit it or change one of the two ⇧⌘V shortcuts: only one app can have it.

### Update

Update the same way you installed it. Your history, pinboards and settings are kept.

* **One command**: run it again.
* **Homebrew**: `brew update && brew upgrade massimodascola/tap/clippa && clippa-install` (name the formula: `brew upgrade` alone updates every Homebrew package on your Mac).
* **From source**, in the `clippa` folder: `git pull && sh build.sh --install`.

After an update, macOS may stop honoring the Accessibility permission (see [Keeping permissions across updates](#keeping-permissions-across-updates)): remove Clippa from the Accessibility list with the − button, then allow it again.

### Uninstall

Turn off "Open Clippa at login" in Settings, quit Clippa from its menu bar icon, then move `/Applications/Clippa.app` to the Trash. Your data is in `~/Library/Application Support/Clippa`: delete that folder too to remove everything. If you used Homebrew, also run `brew uninstall clippa`.

## How to use it

Press **⇧⌘V** (or click the menu bar icon, then Open Clippa, or open Clippa from Applications or Spotlight). Start typing to search.

| Keys | Action |
|---|---|
| ← → | Select the previous or next item (⇧ extends the selection) |
| ↩ / ⇧↩ | Paste / paste as plain text |
| ⌘1 … ⌘9 | Quick Paste the item with that number (⇧⌘ for plain text) |
| Space | Preview |
| ⌘C | Copy to the clipboard without pasting |
| ⌘E / ⌘R | Edit / rename |
| ⌘N / ⇧⌘N | New text item / new pinboard |
| ⌘F, or just type | Search; Tab or ↩ moves to the results |
| ⌘← ⌘→ | Previous or next pinboard |
| ⌘G | Show a search result in its own list |
| ⌫ / ⌘Z | Delete / undo |
| ⌘O | Open a link, or show a file in Finder |
| ⌘T | Pause Clippa for an hour |
| ⇧⌘C | Paste Stack (works from any app) |
| Esc | Clear the search, then close |

Double-click a card to paste it, drag it into any app, or drag it onto a pinboard. Right-click a card for everything else, including **Keep** (its own retention rule) and **Pin**. Drag the top edge of the bar to make it taller or shorter; a short bar switches to a compact layout.

The ⇧⌘V and ⇧⌘C shortcuts, and the modifier keys of Quick Paste and plain text mode, can be changed in Settings → Shortcuts.

### How long items are kept

Settings → General → Keep history applies to every item that is not in a pinboard (1 month by default). Right-click an item and choose **Keep** to give it its own rule: it then follows that rule, pinned or not. A pinned item that ages out of the history stays in its pinboard. Lowering the setting asks before deleting older items. Erase History removes the whole history except pinned items and items you chose to keep forever.

### Suggestions

Click ✦ in the bar. Clippa looks at the app you were using (its name, its window title and the text around the cursor, read with the Accessibility permission) and ranks your items: what you pasted into that app before, the kinds of items it usually gets, how close each item is to what you are writing, and how recent it is. On macOS 26 and later with Apple Intelligence turned on, the on-device model re-orders the best candidates. Optionally (Settings → Intelligence) it can also read the text visible in that window, which needs the Screen Recording permission. Nothing is stored and nothing leaves your Mac. Apps you ignore and password fields are never read.

### AI tools (MCP)

Turn on Settings → Intelligence → "Let AI tools search Clippa". Clippa then answers the [Model Context Protocol](https://modelcontextprotocol.io) through `clippa-mcp`, a small program inside the app that AI tools start on your Mac.

Claude Code:

```sh
claude mcp add --scope user clippa -- /Applications/Clippa.app/Contents/MacOS/clippa-mcp
```

Claude Desktop, Cursor, VS Code and other clients: add this to their `mcpServers` configuration.

```json
"clippa": {
  "command": "/Applications/Clippa.app/Contents/MacOS/clippa-mcp"
}
```

Tools: `search_clipboard`, `get_item`, `list_pinboards`; with "Allow them to add and pin items" also `add_item`, `pin_item` and `copy_to_clipboard`. Nothing goes over the network between Clippa and the tool, but the tool itself may send what it reads to its model provider: check the privacy settings of the tools you connect.

### Sync between Macs

Settings → Sync, on each Mac:

* **Off** (default): nothing leaves this Mac.
* **Pinboards only**: only pinboards and pinned items are synced, in both directions. Good for a work Mac signed in to a personal iCloud account.
* **Clipboard history and pinboards**: everything.

Clippa syncs through a folder, `iCloud Drive/Clippa` by default (any synced folder works, e.g. Dropbox: choose the same one on every Mac). Each Mac writes only its own files there and reads the others', so iCloud never has to merge a file; when two Macs change the same item, the newest change wins. Clippa does not use CloudKit, which needs a paid Apple developer account. The data in that folder is protected like the rest of your iCloud Drive (end-to-end encrypted only if Advanced Data Protection is on). Items larger than 25 MB, and the files behind copied file references, are not synced. Each Mac applies its own Keep History.

## Privacy

* Everything stays in `~/Library/Application Support/Clippa` on your Mac (a SQLite database and a folder of files), unless you turn on sync.
* By default Clippa ignores content marked as confidential or transient (password managers mark passwords this way) and everything copied in common password managers. Add more apps in Settings → Privacy. Some browser extensions copy passwords in a way no app can detect: ignore the browser too if that worries you.
* Link previews download the title and picture of copied web links; turn them off in Settings → Privacy.
* Pause Clippa from the menu bar (15 minutes, 1 hour, 8 hours or until you resume) or with ⌘T in the bar.

## Keeping permissions across updates

macOS ties the Accessibility permission to the exact signature of the app. Clippa is signed *ad hoc* by the Mac that builds it, so every new build looks like a new app and the permission has to be granted again. To avoid that, sign your builds with a stable certificate. A free Apple ID is enough: in Xcode → Settings → Accounts, add your Apple ID, then Manage Certificates → + → Apple Development. Then build with:

```sh
CLIPPA_SIGN_IDENTITY="Apple Development" sh build.sh --install
```

## Compatibility

* **macOS 27**: developed on macOS 27.0.1 (MacBook Pro with Apple Silicon, built-in and external display).
* **macOS 14 to 26**: should work (the code checks every newer API), but it is **not tested**. Please open an issue if you try it, even just to say it works.
* Apple Silicon and Intel: `build.sh` builds for the Mac it runs on.
* **iPhone and iPad**: not available. The storage, search, retention and sync code (`ClippaCore`) uses only Foundation and SQLite, so an iOS app can be added on top of it later.

## Known limits

* No shared pinboards: sharing with other people would need a server or CloudKit.
* Suggestions are ranked by Apple Intelligence only on Macs where it is available and turned on; otherwise Clippa uses its own on-device ranking.
* Copied files are kept as references: if the file is moved or deleted, the card stays but the file is gone.
* There is no prebuilt download: the app is signed ad hoc by the Mac that builds it.

## How it works

* `Sources/ClippaCore`: the database (SQLite with a trigram full-text index, so "bot" finds "robot"), files stored once under their SHA-256, retention, and the folder sync. Foundation and SQLite only.
* `Sources/Clippa`: the macOS app. The clipboard is checked a few times a second (macOS has no "clipboard changed" notification; the check reads no content until something changes). The bar is a panel that takes the keyboard without activating Clippa, so the app you were using stays in front and receives the paste.
* `Sources/ClippaMCP` and `Sources/clippa-mcp`: the MCP server, JSON-RPC over stdin and stdout.
* `Sources/ClippaPasteboard`: puts saved items back on the clipboard, shared by the app and the MCP server.

For developers:

```sh
swift test                         # storage, search, retention, sync and MCP tests
swift tools/check-strings.swift    # every interface text has its Italian translation
sh tools/make-icon.sh              # redraws the icon from tools/draw-icon.swift
```

## License

[MIT](LICENSE).
