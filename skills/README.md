# skills/ - the kit as skills, for a harness that loads them

Nine skills: `hook-gauntlet`, the entry, and one per stretch of the route - `hook-gauntlet-interview`, `-spec`,
`-battery`, `-round`, `-blackbox`, `-release`, `-dossier` - plus `hook-gauntlet-doctor` for the deterministic checks.
Each is short (under 8,000 bytes) and holds only what an agent needs to start that stretch: the six rules that hold in
every phase, the rows of `doctrine/NEXT.md` it owns with what each says to do, the gate of its phase from `AGENTS.md`
section 3, two to five files to read, and "run `scripts/next.sh`, load the skill its row names". Everything else stays
where it is - `AGENTS.md`, `doctrine/`, `briefs/`, `state/` - and wins where a skill and it disagree.

**They are generated, never written by hand.** `scripts/gen-skills.sh` builds every `SKILL.md` from `AGENTS.md` and
`doctrine/NEXT.md`: the six rules are the block between `<!-- invariants:begin -->` and `<!-- invariants:end -->` in
`AGENTS.md`, byte for byte; the rows and the gates are read from the tables; what is not in the doctrine (which skill
owns which rows, the trigger words, the reading lists) is data at the top of the generator. `scripts/skills-check.sh`
regenerates them and compares, resolves every path they name, checks the six rules against `AGENTS.md`, and refuses
a skill over 8,000 bytes; the selftest makes each of those go red. To change a skill, change the doctrine or the
generator's data, then run `scripts/gen-skills.sh`.

## Install them into your project

```sh
<kit>/scripts/install-skills.sh --harness claude --project <your project>    # or codex, devin, agents
```

It copies each `SKILL.md` - only that file - into the harness's project directory (`.claude/skills/`,
`.agents/skills/`, `.devin/skills/`), writing where the kit is in place of `{{KIT}}`: `lib/hook-gauntlet` by default,
the path the handoff dossier assumes (vendor the kit there, as a submodule or a copy), or `--kit <path>`. It then checks
that every file the skills name exists there, and says so when the kit is not there yet. It refuses to replace a
directory that is not one of these skills, replaces its own only with `--force`, and writes a user-level directory
(`~/.claude/skills`, ...) only with `--user` and an absolute `--kit`. Then tell your agent: *"Use the hook-gauntlet
skills."* The entry skill puts it on the right row; `scripts/next.sh` names the next one.

A harness without skills: read `AGENTS.md` in full, as before. The skills add no rule of their own.

## Credit

The design is Pedro Santana's: his fork of this kit (0xZ0uk/hook-gauntlet, 2026-09) turned it into a set of skills -
the entry skill and its four steps, the table from a `NEXT.md` row to the skill that owns it, the shape of a phase
skill (this phase, gate, read on entry, read when, done when), `install-skills.sh --harness --project`, and a drift
guard. What is ours is that nothing in a skill is written by hand, and that the kit stays one tree.
