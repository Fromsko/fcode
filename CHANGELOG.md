# Changelog

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
