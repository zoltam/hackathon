---
name: hackathon-orchestra
description: Coordinate parallel Codex subagents; use when the user requests an agent orchestra or delegates work to a coordinated agent team.
---

# Agent orchestra

Coordinate independent work through subagents when parallel work helps. Assign clear tasks and coordinate shared files. Combine their results and continue the user's requested work. Frequently search GitHub for relevant ideas and existing solutions. Prefer suitable existing libraries and GitHub projects over building from scratch whenever practical; check compatibility and licenses before reuse.

## Defaults

- Coordinator: `gpt-6.1-sol`, `medium`. The user selects the coordinator in the client; this skill cannot change the active model.
- Workers: `gpt-6.1-terra`, `low`.
- Maximum concurrent workers: 3, excluding the coordinator.

The user may override models, reasoning levels, and worker count in their request. Request the configured model and reasoning level when spawning each worker. Respect the actual runtime limit. If a model or requested count is unavailable, report the limitation rather than claiming it was applied.

## Live adjustments

The user can change the maximum concurrent worker count at any time in plain language. The number means workers excluding the coordinator unless context indicates otherwise. Apply increases to useful independent work; for reductions, stop assigning work to excess workers and have them finish or interrupt them when appropriate. Briefly confirm the effective limit. Changes apply to the current run unless the user requests a permanent default change.
