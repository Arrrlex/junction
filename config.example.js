// Junction routing config. Copy to ~/.config/junction/config.js (scripts/install.sh does
// this if you don't have one yet). Junction reloads it whenever the file changes.
//
// Each rule's `match` gets a context object:
//   url            { href, protocol, host, hostname, pathname, search, hash }
//   opener         { bundleId, name, path, windowTitle } — the app the link was clicked in
//   slackWorkspace e.g. "Acme Corp", when the link came from Slack (needs Accessibility access)
//
// Helpers: glob("*.example.com/*"), domain("example.com"), from("com.tinyspeck.slackmacgap"),
// slack("Acme Corp"), any(...), all(...), not(...). A `match` can also be a glob string or an
// array of globs, matched against host + path.
//
// Rules are checked in order; the first match wins. `target` is a key of `targets` or
// "picker". URLs that match nothing go to `fallback`.
//
// Test a URL with:  junction eval <url> --from <bundleId> --title "<window title>"
// Find an app's bundle id with:  osascript -e 'id of app "Slack"'

export default {
  // Opens the feedback window.
  hotkey: "ctrl+alt+cmd+b",
  menuBarIcon: true,

  // Every browser Junction can open, in picker order. The picker and the feedback window
  // both show this list. `key` is the letter that picks it (default: first letter of the
  // label); 1–9 also work, by position. `profile` selects a profile in Chromium-based
  // browsers (Chrome, Brave, Edge, Vivaldi, Chromium), by its display name or directory.
  targets: {
    work: { app: "Google Chrome", profile: "Work", label: "Chrome · Work", key: "w" },
    personal: { app: "Firefox", key: "f" },
    safari: { app: "Safari", key: "s" },
  },

  fallback: "picker",

  rules: [
    // Work tools always open in the work profile.
    { name: "work-sites", match: domain("linear.app", "notion.so", "atlassian.net"), target: "work" },
    { name: "video-calls", match: domain("meet.google.com", "zoom.us"), target: "work" },

    // A GitHub organisation.
    { name: "work-github", match: glob("github.com/acme-corp", "github.com/acme-corp/*"), target: "work" },

    // Links clicked in a particular Slack workspace.
    { name: "work-slack", match: slack("Acme Corp"), target: "work" },
    { name: "other-slack", match: all(from("com.tinyspeck.slackmacgap"), ({ slackWorkspace }) => !!slackWorkspace), target: "personal" },

    // Everything clicked in a particular app.
    { name: "messages", match: from("com.apple.MobileSMS", "net.whatsapp.WhatsApp"), target: "personal" },

    // Any JavaScript works, e.g. a regular expression over the whole URL.
    { name: "acme-anywhere", match: ({ url }) => /\bacme[-.]?corp\b/i.test(url.href), target: "work" },
  ],
};
