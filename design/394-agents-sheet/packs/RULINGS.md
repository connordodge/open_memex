# Design rulings for #394 packs (lead-394, 2026-11-11)

These settle the board-vs-WI and board-vs-Spec conflicts the designer found. They bind every
#394 UI Work Item and override a pack where they differ. "Connor" marks his answers in the
lead tab; the rest are lead rulings that follow the Spec's own precedence rules.

| # | WI | Ruling |
|---|---|---|
| 1 | #405 | `Retry` is an `OmButton` ghost, dense, size 22, label `Retry`, fg1 (the board has no error panel). The WI's "text kind" means `ghost`. |
| 2 | #406 | `OmCopyButton` gains an optional `label` (default `Copy`); Semantic recall uses `Copy config`. |
| 3 | #406 | The leading copy icon shows on every copy button except the token row's. |
| 4 | #406 | The 27% accent border is `OmColors.accentLine`. Only `#1C2D29` and `#222431` are new tokens. |
| 5 | #407, #410, #412 | Tab suffixes follow Spec req 9: `Live 2 connected`, `Tools 37 tools`. |
| 6 | #407, #410 | **Connor:** with zero agents connected the Live tab reads bare `Live`; the count shows only for 1 or more. |
| 7 | #407 | No dot on the Live tab. Only Semantic recall carries a tab dot (Spec req 9). |
| 8 | #407, #413 | No Semantic recall dot when no agent is connected on a local vault (Spec req 9). |
| 9 | #407 | The vault chip reads `<vault> · local vault` / `<vault> · <server> · hosted` (Spec req 1) and ellipsizes. |
| 10 | #407 | The footer (docs link, Close) is always present, including panels the board drew without it (Spec req 11). |
| 11 | #407 | **Connor:** when the tabs don't fit (480 px window, 1.5× text), the tab row scrolls sideways, and the active tab scrolls into view when selected or reached with the arrow keys. Labels and counts are unchanged. |
| 12 | #407, #410 | Buttons use `OmButton`'s own text style (13 px w500), not the board's 12.5 px. |
| 13 | #410 | Spec req 19 copy wins: `Last agent write …` and `No agent writes recorded for this vault yet.` |
| 14 | #410 | Spec req 47 wins on narrow: the client-name column drops; card names stay w500. |
| 15 | #411 | Hosted Claude Code is one line exactly as #404's builder prints it (single-quoted values, no backslash continuations). Revealed shows the whole token; masked is `•` × 28 + last 4 (Spec req 25, 26, 28). |
| 16 | #411 | Both Claude Code notes show, including `Pasting this into a terminal keeps the token in your shell history.` (Spec req 25). |
| 17 | #411 | States the board doesn't draw (local Claude Code, detection status line, unstable-path warning, no binary, no token) use the Spec's copy with the pack's styling. |
| 18 | #412 | Spec req 34's six groups win over the board's nine. |
| 19 | #413 | Spec req 36-42 copy wins everywhere. Never claim the app never runs the model (L10). |
| 20 | #413 | `<root>` and `<host:port>` stay literal placeholders (Spec req 41). |
| 21 | #413 | Hosted coverage and model lines show (Spec req 38, 40), including the off state the board drew without them. |
| 22 | #413 | The turn-on block shows the whole Connect snippet with the flag on, the same text `Copy config` copies (Spec req 30: the shown layout matches the copied text). |
| 23 | #413 | **Connor:** hosted older server: under `Semantic recall status unknown on this vault server`, the body `The server is older than this app. Update memex on it to see semantic recall status here.`, then the closing note. Coverage, model and turn-on are omitted. |
| 24 | #413 | The status heading dot is 8 px. |
