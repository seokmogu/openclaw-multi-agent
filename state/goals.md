# OCMA Evolution Goals

High-level objectives that guide the self-evolution task discovery engine.
When discovery is enabled, the Orchestrator reads this file to generate improvement tasks.

## Active Goals

- Evolve `agent-recruitment-platform` at the service level: improve deployability, runtime reliability, operational visibility, and user-facing production readiness
- Prioritize version-upgrade work across OCMA and target services: dependencies, platform/runtime versions, CLI tools, and security patch adoption with rollback-aware plans
- Generate roadmap tasks that produce meaningful version advancement or service capability improvement, not only local code cleanup
- Treat code-health work as supporting maintenance only when it clearly unlocks service upgrades, production hardening, or release readiness
- Keep the human operator in monitor/approval mode: OCMA should discover, propose, execute, and report autonomously; the operator should not be expected to perform the work manually
- Surface proposed high-impact changes in Slack with clear rationale, expected service impact, and merge/approval prompts when needed

## Notes

- Favor outcomes such as upgrade, migration, rollout safety, observability, release hardening, dependency risk reduction, and production capability improvement
- Avoid spending the next autonomous cycles on low-impact refactors unless they directly unblock a higher-value service goal

## Completed Goals

<!-- Move completed goals here with completion date -->
