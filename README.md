# ClaudeBar for Windows (Preview)

A Windows client for the [ClaudeBar](https://github.com/tddworks/ClaudeBar) Leaderboard.

> **Status: community-maintained preview.** Maintained by [@LunarECL](https://github.com/LunarECL). Nothing is built yet.
> Report Windows issues **here**, not in the ClaudeBar repo.

## Scope

- **First: the Leaderboard.** Read the local token logs of the providers that have a `usageHistory` (Claude, Codex, Mistral, omp), sum each day, and upload to the same board the macOS app uses.
- **Later, maybe: quotas,** reusing ClaudeBar's provider definitions.

## The contract

This client speaks a contract owned by the main repo. It does not redefine it.

- **API and signing:** [`docs/features/leaderboard/design.md` §5](https://github.com/tddworks/ClaudeBar/blob/main/docs/features/leaderboard/design.md#5--the-api)
- **Signing test vectors:** [`Tests/DomainTests/Leaderboard/vectors.json`](https://github.com/tddworks/ClaudeBar/blob/main/Tests/DomainTests/Leaderboard/vectors.json), copied at a pinned commit and run in CI
- **Provider definitions:** [`Modules/Providers/Resources/Providers`](https://github.com/tddworks/ClaudeBar/tree/main/Modules/Providers/Resources/Providers), copied at a pinned commit

Changes to the contract start as an issue or PR in [tddworks/ClaudeBar](https://github.com/tddworks/ClaudeBar).

## License

[Apache-2.0](LICENSE)
