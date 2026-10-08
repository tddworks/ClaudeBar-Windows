# ClaudeBar for Windows (Preview)

A Windows client for the [ClaudeBar](https://github.com/tddworks/ClaudeBar) Leaderboard.

> **Status: community-maintained preview.** Maintained by [@LunarECL](https://github.com/LunarECL). Nothing is built yet: the client starts once ClaudeBar's package builds the Leaderboard on Windows.
> Report Windows issues **here**, not in the ClaudeBar repo.

## Scope

- **First: the Leaderboard.** Read the local token logs of the providers that have a `usageHistory` (Claude, Codex, Mistral, omp), sum each day, and upload to the same board the macOS app uses.
- **Then: quotas,** from ClaudeBar's provider definitions, once the package runs them on Windows.

## How it's built

The board is only fair if a day counts the same on Windows as on the Mac. So this client doesn't reimplement ClaudeBar: it depends on ClaudeBar's Swift package, which is being made to build on Windows as well as macOS, one phase at a time ([MODULAR_DESIGN §10](https://github.com/tddworks/ClaudeBar/blob/main/docs/architecture/MODULAR_DESIGN.md#10--one-package-two-platforms)).

- **From the package:** reading the logs, summing a day, signing, keeping the key, the provider definitions and `vectors.json`. This client depends on `tddworks/ClaudeBar` by URL at a tag or commit, and calls the same factories as the Mac app.
- **In this repo:** the UI, the composition root, packaging and the installer. If the UI is C#, the C interface over the package's factories lives here too. The UI isn't chosen yet.

**Where it stands:** §10's phase 0 is done ([#523](https://github.com/tddworks/ClaudeBar/pull/523)): Swift builds and tests a module on Windows, Mockable included. The client can start at phase 2, when the Leaderboard builds there, and joins and uploads from phase 3.

## The contract

This client speaks a contract owned by the main repo. It does not redefine it.

- **API and signing:** [`docs/features/leaderboard/design.md` §5](https://github.com/tddworks/ClaudeBar/blob/main/docs/features/leaderboard/design.md#5--the-api)
- **Signing test vectors:** [`vectors.json`](https://github.com/tddworks/ClaudeBar/blob/main/Tests/DomainTests/Leaderboard/vectors.json), which comes with the package
- **Provider definitions:** [`Modules/Providers/Resources/Providers`](https://github.com/tddworks/ClaudeBar/tree/main/Modules/Providers/Resources/Providers), which come with the package

Changes to the contract or to the shared code, Windows adapters included, start as an issue or PR in [tddworks/ClaudeBar](https://github.com/tddworks/ClaudeBar).

## License

[Apache-2.0](LICENSE)
