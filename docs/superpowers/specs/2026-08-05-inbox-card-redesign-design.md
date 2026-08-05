# Inbox Card Redesign

## Goal

Make the gg Inbox easier to scan by turning each review request into a compact card, preserving the current bucket ordering and interactions while improving wide-pane readability and GitHub/GitLab reference formatting.

## Scope

This change affects the populated gg Inbox list in `GGInboxTabView`. Loading, upgrade-required, empty, refresh, and top-level error states retain their current behavior and presentation. The existing stack-error section joins the centered list column without otherwise changing.

Repository decoration in the left sidebar when gg is active is explicitly deferred to a separate design.

## Layout

Each non-empty `GGInboxBucket` remains a labeled section in gg's existing priority order. Each entry becomes an individual rounded card rather than a borderless row.

The scroll content uses the same adaptive centered-column behavior as ACP chat via `ACPChatLayout.contentMaxWidth(forPaneWidth:)`:

- Up to 720 pt wide in ordinary panes.
- Begins growing when the pane exceeds 1,080 pt.
- Stops growing at 960 pt.
- Remains centered with the existing Inbox horizontal padding at narrower widths.

The Inbox toolbar remains full width. Bucket headings, cards, and the stack-errors section share the centered content column.

Cards use a 7 pt corner radius, 10 pt vertical and 11 pt horizontal padding, and 7 pt vertical separation. These dimensions preserve a compact list while making each entry visually discrete.

## Card hierarchy

The card has three horizontal regions:

1. The existing stack position at the leading edge, in subdued monospaced text.
2. A flexible title-first content region:
   - Review title on the first line, truncated before the trailing column.
   - Stack name on the second line in subdued monospaced text.
   - The existing CI indicator and refresh error join this secondary region when present. A refresh error has a two-line limit rather than displacing the review reference.
3. A fixed 64 pt trailing column aligned to the card's trailing edge:
   - Review reference (`#498` or `!500`) on top.
   - `behind x` directly beneath it when `behindBase` is greater than zero.

The trailing column keeps review references and behind counts aligned across cards regardless of title or stack-name length.

## Status color

Cards use the bucket's semantic theme color at 8% opacity for the background and 28% for the border, while body text retains the normal foreground tokens.

Bucket colors use existing theme tokens:

- Refresh failed: `del`
- Ready to land: `add`
- Changes requested: `del`
- Blocked on CI: `caution`
- Awaiting review: `accent`
- Behind base: `warn`
- Draft: `fg-muted`

Refresh failures and requested changes intentionally share red because both require corrective action. No theme tokens or new palette are added.

## Review request references

The review reference uses the provider's established convention:

- GitHub pull request: `#<number>`
- GitLab merge request: `!<number>`

`GGInboxEntry` already supplies the review URL. A small pure presentation helper determines the prefix from its path: a URL whose path components include `merge_requests` uses `!`; all other or unavailable URLs retain the current safe `#` fallback. This supports GitLab.com and self-hosted GitLab without relying on the hostname.

The existing URL validation remains the trust boundary. A valid HTTP(S) URL makes the reference clickable; an invalid or absent URL renders the reference without a browser action.

## Interaction and accessibility

Existing behavior is preserved:

- Clicking or pressing Return on a card focuses its matching live worktree.
- Clicking the review reference opens the validated review URL.
- Cards without a resolvable worktree remain dimmed.
- Existing accessibility labels and hints remain, with the combined card still exposed as a worktree-focus action.
- The review-reference button retains a provider-correct help label (`Open PR #498` or `Open MR !500`).

## Testing

Add focused Swift Testing coverage to `GGInboxHelpersTests` for:

- GitHub `/pull/<number>` URL formatting as `#<number>`.
- GitLab `/-/merge_requests/<number>` URL formatting as `!<number>`.
- Self-hosted GitLab URL formatting as `!<number>`.
- Missing or unrelated URLs falling back to `#<number>`.

The adaptive width behavior is already covered by `ACPChatLayout`; Inbox reuses it rather than duplicating width calculations. Existing Inbox model, refresh, URL-validation, and worktree-resolution tests continue to cover unchanged behavior.

Verification follows the project requirements: regenerate with `xcodegen`, build the macOS scheme, and run the full test suite.
