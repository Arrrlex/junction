# Junction

A small default-browser app for macOS that decides which browser (or browser profile) each
link opens in. It replaces the combination of [Finicky](https://github.com/johnste/finicky)
(rules) and [Bumpr](https://www.getbumpr.com) (a picker).

- **Rules** in a plain JavaScript config send links to a browser or a Chromium profile, based
  on the URL, the app the link was clicked in, that app's window title, and (for Slack) the
  workspace.
- **Picker** for links no rule claims: press a browser's letter to open it.
- **Feedback** at any time with a hotkey: pick a recent link, say where it should have gone
  (it's reopened there), and optionally add a note.
- **Everything is logged**, so you (or Claude, via the included skill) can review the
  feedback, fix the rules, and check the new rules against every past decision.

## Requirements

- macOS 14 or later (built and tested on macOS 26)
- Swift 6 and the macOS SDK: install the Xcode Command Line Tools with
  `xcode-select --install` (full Xcode also works)

## Install

1. Clone and run the install script:

   ```bash
   git clone https://github.com/Arrrlex/junction.git
   cd junction
   scripts/install.sh
   ```

   This builds the app into `~/Applications/Junction.app` and:
   - creates `~/.config/junction/config.js` from `config.example.js`, if you don't have one;
   - links the `junction` command-line tool into `~/.local/bin` (add that to your `PATH` if
     it isn't already);
   - links the `fix-browser-routing` skill into `~/.claude/skills`, if you use Claude Code;
   - the first time, creates a self-signed code-signing certificate in a keychain file inside
     the repo (`.signing/`, gitignored). See [Why a signing certificate?](#why-a-signing-certificate)

2. **Edit `~/.config/junction/config.js`** to list your browsers and rules. The comments in
   it explain the format. Check a rule with:

   ```bash
   junction eval https://linear.app/ --from com.tinyspeck.slackmacgap --title "general (Channel) - Acme Corp - Slack"
   ```

3. **Open Junction** (`open ~/Applications/Junction.app`). A branch icon appears in the menu
   bar.

4. **Grant Accessibility access**: menu bar icon → *Grant Accessibility access…*, then switch
   Junction on in System Settings. Junction uses this to read the title of the window a link
   was clicked in (that's how it knows the Slack workspace) and to bring the right browser
   window to the front. Restart Junction afterwards (menu bar icon → *Quit Junction*, then
   open it again).

5. **Make it the default browser**: System Settings → Desktop & Dock → Default web browser →
   Junction.

6. **Launch at login**: menu bar icon → *Launch at login*, so the feedback hotkey works after
   a restart.

To update later: `git pull && scripts/install.sh`. Your config is never overwritten.

## Using it

**Picker** (links no rule matches): press a browser's letter (set by `key` in the config,
default first letter of its label), or 1–9 by position, or click its icon. ↵ opens the icon
under the mouse pointer (the first one if you haven't moved the mouse). ⌘C copies the URL,
esc cancels.

**Feedback** (⌃⌥⌘B by default, or menu bar icon → *Give feedback on routing…*):

1. Which link? 1–9, or ↑↓ ↵.
2. Where should it have gone? The browser's letter. The one it went to is marked; choosing it
   means the decision was right.
3. Notes: optional, ↵ to save. If the link went to the wrong place, it's then reopened in the
   right one.

Esc goes back a step.

**Improving the rules with Claude Code**: say "fix the browser routing". The skill reads your
feedback and picker choices (`junction review`), edits the config, and checks the result
against every logged decision (`junction replay`).

## Command-line tool

```text
junction eval <url> [--from <bundleId>] [--title <window title>]   where would this URL go?
junction replay [--json] [--all]                                    re-run the config over all logged decisions
junction review [--mark]                                            feedback and picker choices since the last review
junction recent [n]                                                 the last n decisions
```

## Files

| Path | What |
|---|---|
| `~/.config/junction/config.js` | Your rules. Reloaded automatically when it changes. Override the path with `JUNCTION_CONFIG`. |
| `~/Library/Application Support/Junction/decisions.jsonl` | One line per link: URL, source app and window title, rule, where it went. |
| `~/Library/Application Support/Junction/feedback.jsonl` | Your feedback on those decisions. |
| `~/Library/Application Support/Junction/junction.log` | What the app did, for troubleshooting. |

## How it works

- macOS sends the link to Junction as an Apple Event, which includes the sender's process
  id. From that Junction gets the app, and (with Accessibility access) its focused window's
  title.
- The config is evaluated with JavaScriptCore, so rules are ordinary JS functions.
- Chromium profiles are opened by starting a second browser process with
  `--profile-directory=…`, which hands the URL to the running browser and exits. Junction then
  raises that profile's window (Chromium window titles end in " - <profile name>"), so macOS
  switches to the right Space.

## Why a signing certificate?

macOS remembers the Accessibility permission per code signature. With the default ad-hoc
signature every rebuild looks like a new app, and you'd have to grant access again each time.
`scripts/make-signing-identity.sh` creates a self-signed certificate in a keychain file inside
the repo; it isn't added to your login keychain, and `install.sh` only puts it on the keychain
search list for the moment it signs, then restores the list.

The bundle id defaults to `local.junction.Junction`. To use a different one, put it in a
`.bundle-id` file in the repo (gitignored) before installing. macOS ties the permission and the
default-browser setting to it, so changing it later means granting both again.

## Troubleshooting

- **The Slack workspace isn't detected / `junction.log` says `accessibility=false`.** If you've
  granted access and it still says false, macOS may have pinned the permission to an older
  build. Run `tccutil reset Accessibility local.junction.Junction` (or your bundle id), grant
  it again, and restart Junction. To see why macOS refused:
  `/usr/bin/log show --last 5m --predicate 'subsystem == "com.apple.TCC"' | grep -i junction`.
- **Nothing happens when clicking a link.** Check Junction is running and is the default
  browser, and look at `junction.log`.
- **A link opened in the right browser but you didn't see it.** It probably opened in a window
  on another Space. For Chromium profiles Junction raises the right window; for apps it can't
  identify windows in, macOS decides.

## Licence

MIT. See [LICENSE](LICENSE).
