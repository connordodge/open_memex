# Release notes

Each release has one file here, named `v<version>.md` (for example `v0.2.0.md`). `scripts/release/check-version.sh` refuses a tag with no matching file or with an empty section, and the release workflow puts the file at the top of the GitHub Release. See [`docs/releasing.md`](../docs/releasing.md) for the steps.

Use this template. Name only features that are on `main` when you write the notes.

```markdown
## Highlights

A short paragraph on what is new in this release.

## Upgrade

No vault changes. Vaults made by earlier builds at schema V<n> open as they are.

## Requirements

Apple silicon Mac, macOS 14 or later.
```

If the release changes the vault schema, replace the Upgrade section's text with this line:

```
This release migrates vaults to schema V<n> the first time it opens them. Back up first (the vault's Backups sheet → Back up now, or memex backup); older versions can't open a migrated vault.
```

The `## Upgrade` section must say `No vault changes` or name `schema V<n>`.
