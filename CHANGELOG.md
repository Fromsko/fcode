# Changelog

## 0.2.2

Subagent message cards need a recent desktop version; older desktops show messages as before.

- New: messages a subagent sends to the main agent show as that subagent's own card, with its model, instead of as your messages.
- New: long-press a conversation to copy its session ID; the menu follows the desktop's order.
- New: the project long-press menu now offers New conversation, Browse files, Pin, Copy path, Archive all and Remove from list.
- Improved: pinned conversations stay on top in both layouts, and the pinned group in the immersive sidebar can fold. "Show on home" is gone.
- Improved: in the sidebar's pinned group, long titles are cut first so the project name stays whole.
- Improved: a stopped turn folds too, reading "Stopped after X".
- Improved: screenshots in steps show as thumbnails, as on the desktop; Mermaid diagrams open full screen in the shared image viewer.
- Improved: the status line while a turn runs picks its words from the last step, as on the desktop.
- Improved: all hints show on top, visible with the sidebar open and above the keyboard.
- Improved: text can't be selected while a file preview is zoomed; it can again at normal size.
- Improved: saving an avatar or a Bot's profile no longer slows conversations open at the same time.
- Fixed: the immersive layout sometimes jumped to another conversation.
- Fixed: HTML, source and diff views scrolled up on their own after zooming out.
- Fixed: scrolling after selecting text turned the whole page grey.
- Fixed: opening "Worked for" and then a run of steps hid the first step.
- Fixed: a queued message sometimes showed the wrong state.
- Fixed: saving a file mangled its extension, e.g. `.jpg` became `.jpg.bin`.
- Fixed: a pinned conversation's unread dot was counted again on its project.

## 0.2.1

- New: Bot group chats. Create groups, manage members, @ mention, quote and send pictures.
- New: upload files in chat and view them right on the phone. Needs the next desktop version.
- New: suggested replies for Bots. Tap to send; long-press to edit first.
- New: choose whether a Bot may message you first.
- Improved: reconnecting or reopening a conversation syncs only what changed, so it's faster.
- Improved: Bot chats and group chats share one composer, with pinning.
- Improved: pull to refresh follows your finger and also works in files and a project's conversations; stronger haptics.
- Improved: in list layout, the back button shows a dot when a conversation is waiting for you.
- Improved: a more compact chat layout.
- Fixed: on Windows, viewing a file's changes marked the whole file as changed.
- Fixed: Bot replies and group messages sometimes showed wrongly or leaked into private chats.

## 0.2.0

- New: a "Focus" option under Layout opens straight into your last conversation, with projects and conversations in a side panel, grouped by project; tap one to switch. "List" stays the default.
- New (experimental): Settings → Notifications → "Keep desktop connection in background" keeps task notifications coming with the app in the background. It shows a persistent notification, uses more battery, and some phones may still stop it.
- Improved: the home list drops the filter and keeps just search; the create menu keeps just New conversation and Add bot.
- Improved: Agent mode uses an infinity icon.
- Improved: coming back to the app no longer re-syncs the whole conversation; switching networks checks the connection right away.
- Improved: long conversations and ones with many pictures load more smoothly.
- Improved: a tool's screenshot shows once; open it to swipe through the others.
- Improved: Markdown file previews show the project's pictures inline; tap one to view it full screen.
- Fixed: no "finished" notification when a task finished quickly.
- Fixed: syncing a long conversation could mistake the connection for lost and reload over and over.
- Fixed: a message that failed to send took a long time to say so.
- Fixed: a plan card could say the file is missing; a sync timeout showed the raw error.


## 0.1.1

Context usage and undoing file changes need BaoCode desktop 1.9.3 or later; with an older desktop they don't appear and everything else works as before.

- New: a context usage ring in the composer, orange above 80%; tap it to see what each part takes and how much is left before auto-compact. With BaoCode desktop 1.9.4 or later it updates as the conversation goes; with 1.9.3, when you open the conversation.
- New: when you edit an earlier message and send it again, YCode can undo the files the agent changed after it — asking, undoing or keeping as the desktop's "Edited Messages" setting says (Claude Code and BaoCode Agent).
- New: an arrow on a project's row unfolds its conversations right on the home list, without opening the project.
- Improved: picking a project in the filter closes the panel and lists that project's conversations directly; new conversations then start in it.
- Improved: checking for updates reads a small file attached to the release first, so it no longer fails when many people share one network and GitHub's hourly limit runs out.
- Fixed: file links written as `/D:/path` by a model on a Windows desktop now open.

## 0.1.0

The first open-source release of YCode, an unofficial Android client for the BaoCode desktop app.

- Pair with your computer by QR code, pasted link or LAN discovery, end-to-end encrypted over link v2.
- Conversations, Bots, Files and Settings tabs; streaming messages, edit and resend, queued sends, images and @ files, / commands.
- Checks for updates on launch and downloads and installs them in the app.
