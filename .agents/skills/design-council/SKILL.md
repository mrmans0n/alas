---
name: design-council
description: Run a design-judging loop on Alas screenshots. Fresh sessions on models from different providers score the app against reference apps, then an agent fixes what they flag. Use when asked to run the design council, hill-climb the design, or have models judge Alas's look.
---

# Design council

Models from other providers judge screenshots of Alas beside reference apps. You
run the rounds, read the findings, and fix what most judges agree on. Scores
direct the work. They are not a target, and the owner's judgement overrides them.

Inputs: a capture round from `scripts/design/capture.sh` (see
`scripts/design/README.md`), reference images, and an agreed round cap. Ask the
owner for the cap if none was given.

## Privacy

- Panels go to outside model providers.
- Alas captures come from the demo profile only. Never capture the owner's real
  workspace or Claude conversations (Claude's sidebar lists them).
- Check every reference image for personal content before use.
- Reference images are never committed.

## Round

Work in `docs/superpowers/design-runs/<date>/` (uncommitted). Each round writes
`round-N/panel/`, `round-N/scores.md` and `round-N/changes.md`.

1. Capture dark and light from the demo profile at the baseline window size.
2. Build the panel. It prints the absolute path of every file:
   `scripts/design/build-panel.py --alas <capture> --refs <refs> --out round-N/panel`
3. Copy the panel to a fresh folder outside the repo with a neutral name (for
   example `/tmp/panel-<random>/`, keeping one subfolder per app), so no path
   names the run, the round or the app being improved. Start fresh judges with
   `session_new`, each on a different harness (for example Claude, Codex, and a
   third through Pi or opencode), in the harness's own read-only or plan mode
   where it has one. Never reuse a session across rounds. Send the judge prompt
   below with the copied paths and a `/tmp` answer file you name for each judge;
   read the answer from that file, since reading a session's transcript can
   fail. Before round one, send each a test image and confirm it describes it
   correctly; drop a judge that cannot see images and tell the owner.
4. Run the cheapest judge first. Add slower judges once its findings stop being
   substantial.
5. Record each judge's scores and findings in `scores.md`, with its reported
   token or cost usage. If a session reported none, write "none reported".
   Never estimate.
6. Fix the findings most judges agree on. Read the rubric's reference roles:
   drop layout findings that come from feel-only references. Log each change and
   the finding behind it in `changes.md`.
7. Recapture and compare against the baseline (below) before the next round.

## Judge prompt

Fill in `<paths>`: absolute paths of the copied panel, grouped by app folder,
and `<answer-file>`. Add nothing else.

```
You are a senior product designer reviewing screenshots of desktop apps. Read
only: do not edit files or run commands, other than viewing the images below
and writing your final answer to <answer-file>.

These apps are in the set, one folder each:
<paths>

Score each app out of 10 on: hierarchy, typography, colour and contrast,
spacing, iconography, consistency, density fit. Judge what you see, not what
you know of the app. Then list specific findings per app. Each finding names
the screen (file name) and what is wrong, and ends with what you would change.

Write your final answer to <answer-file> as well as replying with it. End
with exactly this format, and nothing after it:

SCORES
<app> | hierarchy <n> | typography <n> | colour <n> | spacing <n> | iconography <n> | consistency <n> | density <n>
(one line per app)
FINDINGS
<app> | <screen> | <what is wrong> | <suggested change>
(one line per finding)
```

Never add a target score, earlier rounds, or any hint that one app is being
improved. Present every app neutrally.

## Checks every round

- **Reference drift.** Track the reference apps' scores per judge. If one moves
  more than about 0.5 between rounds, treat the round's numbers as noise and
  weight findings over scores.
- **Colour.** Compare Alas's colour against the baseline: accents, tints,
  contrast. Call out any move toward grey. The method's known failure is
  washing an app out.
- **Anti-goals.** Reject a change that does any of these, whatever score it
  earns:
  - copies a reference app rather than looking like Alas;
  - turns the app grey and lifeless;
  - makes finding the worktree that needs you slower;
  - makes reading diffs or code worse;
  - regresses scrolling performance.

## Stopping

Stop at the agreed round cap, or when a round brings no visible improvement.
Never extend the cap without asking the owner. Finish by reporting what changed,
the score trend per judge with the reference drift, and any anti-goal worries.
