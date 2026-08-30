# Security

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/Larc99/stickydeck/security/advisories/new)
rather than opening a public issue. Include the version or commit, your macOS
version, and what an attacker would gain.

## What StickyDeck does with your notes

- Notes live in a SQLite database inside the app's sandbox container.
- Note **bodies** are encrypted with AES-GCM before they are written.
- The key is 256-bit and lives in your login keychain. If the keychain is
  unavailable at first launch, the app falls back to a key file created with
  `0600` permissions in the same container.
- StickyDeck makes no network connections. The sandbox entitlement for outbound
  network access is explicitly disabled, and there is no analytics, telemetry,
  crash reporting, or third-party SDK beyond GRDB.
- File access is limited to locations you choose yourself, through the standard
  open and save panels.

## What is deliberately *not* protected

Being explicit about this matters more than the encryption does.

- **Note titles, colours, tags and dates are stored in plaintext columns.** Only
  the body is encrypted. Titles are searched and displayed constantly, and
  encrypting them would not survive the first search query.
- **The encryption protects the database file, not the running app.** Anything
  that can execute code as your user can read your notes: the key is in your
  keychain and the app can decrypt on demand. This is at-rest protection against
  someone reading `notes.sqlite` out of a backup or a copied container — not a
  defence against malware or another user with your session.
- **The fallback key file sits next to the database it protects.** When the
  keychain cannot be used, anyone who can read the container can read both. The
  keychain path is strongly preferred; the file key exists so unsigned local
  builds can run at all.
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
