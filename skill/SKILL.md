---
name: fix-browser-routing
description: Improve the user's browser routing (the Junction default-browser app) from the feedback they have logged. Use when the user says "fix the browser routing", "links are opening in the wrong browser/profile", "review my Junction feedback", or asks to add or change a rule for which browser or profile a link opens in.
---

# Fix browser routing

Junction is a default-browser app for macOS. Each link it receives either matches a rule in
`config.js` and opens in a browser (or browser profile), or goes to a picker where the user
chooses with one key. With a hotkey (⌃⌥⌘B by default) the user marks recent decisions right
or wrong, says where they should have gone, and optionally adds a note saying why.

Your job: turn that evidence into better rules, without breaking what already works.

## Files

- `~/.config/junction/config.js`: the rules. The app reloads it on the next link; no rebuild
  needed. It may be a symlink, or live in its own git repo; check before committing.
- `~/Library/Application Support/Junction/decisions.jsonl`: one line per link
  (url, opener app + window title, slackWorkspace, via rule/fallback/picker, rule name, target).
- `~/Library/Application Support/Junction/feedback.jsonl`: verdicts (`right`/`wrong`/`note`),
  `correctTarget`, `comment`, linked by `decisionId`.
- `~/Library/Application Support/Junction/junction.log`: what the app did (URLs received,
  panels shown, errors, whether it had Accessibility access).
- CLI: `junction` (in `~/.local/bin`). Run `junction help`.
- The Junction source repo is the parent directory of this skill's real location
  (`readlink -f ~/.claude/skills/fix-browser-routing`). `config.example.js` there documents
  the config format and helpers.

## Steps

1. **Gather evidence.** Run `junction review`. It prints, since the last review: every feedback
   entry (with the decision, the window title, and where the *current* config sends it now),
   every picker choice, rule errors, and recurring picker choices across all time. Read
   `config.js` too.

2. **Work out the cause of each wrong decision.** Usual causes:
   - a rule is too broad or too narrow (check the URL, opener bundle id, window title);
   - rule order: an earlier rule caught it first;
   - the Slack workspace was missing because the window title was unreadable
     (`windowTitle` absent means Junction lacks Accessibility permission; a title like
     "1 new item - Slack" has no workspace in it);
   - the user's note describes something no rule can see yet (e.g. time of day, a specific
     Slack channel). Then a new context field or helper may be needed in the Swift code.

   Treat the user's notes as the main signal. Treat repeated picker choices for the same
   host/source (the "picker patterns" section) as candidates for new rules, but only propose
   one when the choices agree, and ask if they're mixed or there are only 2–3 of them.

3. **Explain before editing.** Tell the user briefly, in plain language, what you found and
   what you plan to change (one line per rule). If a fix is ambiguous (e.g. two plausible
   readings of a note), ask. Small, clearly supported fixes can just go ahead.

4. **Edit `config.js`.** Keep rules named, short, and commented where the reason isn't
   obvious (cite the feedback, e.g. "per feedback 2026-10-12: event links from the X Slack").
   Order matters: first match wins.

5. **Check for regressions.** Run `junction replay`. It re-runs the config over every logged
   decision and labels each one:
   - `WRONG` / `CONFLICT`: contradicts explicit feedback or a picker choice. Fix these, or
     explain to the user why the old evidence is outdated.
   - `changed`: was auto-routed with no feedback and now goes elsewhere. Check each one is
     intended; list them for the user if there are any surprises.
   - `fixed`, `learned`: good.
   Spot-check new rules with `junction eval <url> --from <bundleId> --title "<window title>"`.

6. **Commit** if the config is in a git repo (resolve symlinks first): atomic, with a message
   that says why and cites the feedback that prompted it. Then run `junction review --mark`
   so the next review starts from here.

7. **Summarise for the user**: what changed, what replay showed, anything left open.

## Changing the app itself

Only when config can't express the fix (e.g. a new context field). Swift sources are in
`Sources/Junction/`; `Config.swift` builds the context object passed to rules and defines the
JS helpers. Rebuild and reinstall with `scripts/install.sh`, and commit in the source repo.
Builds are signed with a stable local certificate, so Accessibility access should survive.
Check `junction.log` after reinstalling: if it says `launched; accessibility=false`, see the
Troubleshooting section of the README (the fix is a `tccutil reset` the user has to run;
don't run it yourself).
