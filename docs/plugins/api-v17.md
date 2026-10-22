# Plugin API v17: project requirements

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 16 in [api-v5.md](api-v5.md) to
> [api-v16.md](api-v16.md); everything there still applies.

API 17 lets a plugin say which projects it is for. A plugin that only makes
sense on GitHub, such as a pull request inbox, can ask Alas to start it only
in projects that have a GitHub remote, instead of showing an empty panel
everywhere else.

## The `api` field

Alas loads plugins with `"api": 4` to `17`. Below 17, a manifest with
`requires` is refused.

## The `requires` field

```json
{ "api": 17, "requires": { "codeHost": "github" } }
```

| Key | Value |
|---|---|
| `codeHost` | `"github"` or `"gitlab"`. The project needs a recognized fetch remote on that host. |

`"requires": {}` is accepted and means no requirement. An unknown `codeHost`
value, an unknown key inside `requires`, or a value of the wrong type refuses
the manifest, so a requirement Alas cannot read never turns into a plugin that
shows up everywhere.

A project meets `codeHost` when it is not a plain folder and at least one of
its fetch remotes is recognized as that host. Every fetch remote counts, not
just the primary one: a project with a GitHub `upstream` and a GitLab `origin`
meets both `"github"` and `"gitlab"`. Until Alas has read a project's remotes,
the requirement is not met.

When a project does not meet the requirement, Alas does not start the plugin
there. Its panel, tabs, commands, decorations, prompts and context providers
are all absent for that project, and it does no work in it. Already-open tabs
of the plugin show the usual "isn't available" placeholder. Plugins without
`requires` are unaffected. A requirement only restricts, so the approval sheet
is unchanged.

## Recognized hosts

Alas recognizes `github.com` as GitHub, and `gitlab.com` or a host whose first
label is `gitlab` (such as `gitlab.example.com`) as GitLab. GitHub Enterprise,
self-managed GitLab servers under other names, and SSH host aliases from
`~/.ssh/config` (such as `git@github-work:org/repo`) are not recognized, so a
plugin that sets `requires.codeHost` stays hidden in those projects.

## Panel icons

A right-rail panel's `icon` is an SF Symbol name, with two exceptions: `"github"`
and `"gitlab"` draw Alas's own GitHub and GitLab glyphs. Command icons are
always SF Symbols.
