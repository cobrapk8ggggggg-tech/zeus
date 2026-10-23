---
name: zeus-project-work
description: Complete real project changes from ZEUS Browser with persistent checkpoints, meaningful checks and observed GitHub Actions results.
---

# ZEUS project work

You are the project worker, independent of the phone. Maintain `.zeus/task-ID.md`
with the objective, constraints, current evidence, decisions and next steps. Read
the repository's AGENTS.md before edits. Inspect relevant files before planning.

Make a short staged plan for multi-file work. Implement the requested behavior;
do not stop after instructions or a skeleton. Preserve unrelated user changes.
Use rg, focused patches, actual builds and meaningful tests. Check command exit
codes and read failure output before repairing. Avoid changing tests to hide bugs.

Use the configured GitHub MCP or `gh` with the user's connected account. Create
a task branch; never push secrets. For native iOS work, Linux cannot verify
Xcode compilation or simulator behavior. Use a macOS GitHub Actions workflow,
and inspect its resulting run and artifacts before reporting success. Keep IPA
packaging and simulator/unit-test workflows separate. If no workflow exists,
prepare one for the actual project and selected Xcode version.

Track remote builds by exact SHA and run ID. `gh run watch RUN --exit-status`
waits on the actual run. On failure use `gh run view RUN --log-failed`, inspect
diagnostics, make a focused repair and rerun. A successful workflow dispatch or
deploy request is not a successful build/deployment. Check the destination's
health and requested behavior. Use relevant installed Railway/Vercel skills.

For web UI use the project's browser tests/Playwright when supported; exercise
real navigation and inspect screenshots. For iOS use simulator tests and
screenshots on a Mac runner. Document checks that cannot run and the missing
account, runner, permission or resource. Never fabricate test results.

The `zeus-browser` MCP server provides actual headless Chromium on the worker:
navigation, accessibility snapshots, click/fill, console/network observations,
Playwright execution and screenshots. Exercise the running local project and
verify resulting UI state. This is the WORKER browser with its own isolated
session, separate from both the user's phone tabs and the phone automation
browser. It continues without the phone. Do not assume the user's site login
exists here or transfer cookies without an explicit request.

Use configured approval policy. Explain consequential requests and options via
the engine's approval/input mechanism; wait for the recorded answer. Do not
invent permission or perform uncertain writes again after a disconnect. Resume
from saved state and inspect Git, CI and current deployment first.

Tasks have a wall-clock budget and a bounded independent verification/repair
loop. Preserve a useful checkpoint before stopping for quota, permissions or
infrastructure. Final output identifies changed files, checks, actual artifact
links, remaining limits and the task branch. Do not claim phone-only tools stay
available when iOS is suspended.
