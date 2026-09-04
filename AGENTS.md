# Agent instructions for this repo

## Always write an audit log for code reviews

When asked to audit, review, or check code in this repo (not just answer a
question about it), don't only report findings in chat — write them to a
file in the repo first (e.g. `audit-findings.md`, or a similarly named file
if one already exists for the current round), then summarize it in chat.

Each finding should include: severity, a concrete repro (commands run,
actual output seen — prefer testing live over reading code when the code
spawns processes, parses output, or otherwise has runtime behavior that
static reading won't catch), root cause, and a suggested fix. Also record
what was verified working, not just what's broken, so the next agent
picking up the file doesn't have to re-derive or re-test it.

This repo is worked on by multiple agents (Claude, Codex) handing work back
and forth — chat history is not shared between them, so findings that only
exist in one agent's conversation are invisible to the other. The file is
the handoff.
