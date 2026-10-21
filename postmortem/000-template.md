# NNN — One-Line Slug

_Optional status line: `Status: Complete` / `Superseded by NNK`. One page,
prose, evidence in the form of file paths, tests, gate output, or commit
hashes. English or Chinese — match the surrounding record._

## Background

What existed before and the problem it created. Name the failing layer
(rendering / state / events / packs / persistence / tooling) when one owns it.
Cite the files or commits that make the record verifiable.

## Decision

What was chosen, in one clear sentence, then the mechanics: which module owns
the behavior, which public surface changes, which old surface is removed.

## Why

The reasoning — never restate the code. Why this approach over the
alternatives considered, what concrete problem it solves now, and any tradeoff
explicitly accepted. Rejected alternatives belong here, each with one line on
why not.

## Consequence

What changed for users and developers: new/changed/removed commands, options,
faces, behavior, docs touched. What later changes must keep in mind.

## Known limitations

Deliberately deferred or accepted limits. A later entry that lifts one starts
with "Superseded by NNK" at the top of this file — do not rewrite the body of
an old record to match current behavior.

---

_Writing rules (also in AGENTS.md, §Postmortems):_

- Write one when: adding or changing a user-visible workflow; choosing between
  non-obvious architectural approaches; abandoning or reverting an approach;
  removing a public option or command; deliberately deferring a known
  limitation. Bug-fix-only changes do not need one.
- Read the relevant records before significant changes — they are constraints
  and rationale, not proof the code still matches them.
- User-visible changes link back from `CHANGELOG.md` as
  `(rationale: postmortem/NNN)`; the record cites commits, files, and tests as
  evidence. This repository has no commit history yet, so early records cite
  file paths and the verification gate output instead.
