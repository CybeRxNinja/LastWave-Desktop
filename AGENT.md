# AGENT.md — CybeRxNinja fork

This fork (`CybeRxNinja/LastWave-Desktop`) is managed by the owner's AI agent.
Upstream: `Clash-Projects/LastWave-Desktop`. Disjoint ownership: agent edits only this file.

Orchestrator plans; workers execute small scoped tasks, then verify via `gh` + `git`.
No local Flutter build; Linux binaries come from GitHub Actions.

Workflow: `desktop.yml` ("Build and Release Desktop Apps").
Build: `flutter build linux --release` on `ubuntu-22.04`.

Trigger: Actions > Build and Release Desktop Apps > Run workflow (branch `main`),
or `push` to `main`. `.deb`/`.rpm` packaging runs only on `v*` tags.
Artifacts: `LastWave-Desktop-Linux` bundle on every build.
