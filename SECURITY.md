# Security

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/Larc99/stickydeck/security/advisories/new)
rather than opening a public issue. Include the version or commit, your macOS
version, and what an attacker would gain.

## What StickyDeck does with your notes

- Notes live in a SQLite database inside the app's sandbox container, stored as
  plain text.
- At-rest protection is FileVault's, which encrypts the whole disk. StickyDeck
  adds no encryption of its own — see below for why it no longer tries.
- StickyDeck makes no network connections. The sandbox entitlement for outbound
  network access is explicitly disabled, and there is no analytics, telemetry,
  crash reporting, or third-party SDK beyond GRDB.
- File access is limited to locations you choose yourself, through the standard
  open and save panels.

## What is deliberately *not* protected

Being explicit about this matters more than encryption would.

- **StickyDeck does not encrypt your notes.** Versions up to 0.2.0 encrypted
  note bodies with AES-GCM under a key in the login keychain, with a local
  fallback key for source builds that could not use the keychain. That was dropped
  in 0.3.0, because it never bought what it appeared to: sync-folder mode writes
  the same bodies as plain Markdown into a folder that is usually iCloud or
  Dropbox, the key lived on the same disk as the database it protected, and a
  keychain that would not answer could stop the app from opening at all. Whole-
  disk encryption is the right layer for this, and macOS already has it.
- **Upgrading is one-way.** The first launch of 0.3.0 decrypts any bodies still
  stored as ciphertext, rewrites them as plain text, and removes StickyDeck's
  obsolete recovery keys only after every body is safe. Nothing is lost;
  nothing goes back.
- **Anything running as your user can read your notes.** That was true before —
  the app could decrypt on demand — and it is true now.
- **Sync-folder mode is plaintext by design.** If you enable it, notes are
  written as readable Markdown into the folder you pick, so other tools can use
  them. That is the point of the feature, and it is stated in the app's own
  settings. Do not enable it for anything you would not put in a plain text
  file.
- **There is no lock or authentication gate.** Anyone at your unlocked Mac can
  read your notes by moving the pointer to the edge of the screen.

## Scope

StickyDeck is a local, offline note-taking app with no account, no server and no
network access. The realistic threat model is a stolen backup or a shared
machine. It is not designed to withstand a determined attacker who already has
code execution as your user.
