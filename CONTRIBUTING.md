# Contributing

Thanks for helping bring ClaudeBar to Windows.

## Rules for using the Leaderboard server

These are the conditions for using `claudebar-api.tddworks.com` from this client:

1. **Identify the client.** Every request carries `X-Client: claudebar-windows/<version>`. It is not a credential; it lets the server tell clients apart and refuse a broken version.
2. **Sign with ClaudeBar's package.** Its signing is pinned by `vectors.json`, which ClaudeBar's CI runs on Windows from phase 2 of [§10](https://github.com/tddworks/ClaudeBar/blob/main/docs/architecture/MODULAR_DESIGN.md#10--one-package-two-platforms). Depend on the package at a tag or commit, and bump it on purpose, never silently.
3. **Keep the private key on the machine.** The package keeps it in Windows Credential Manager (phase 3). Never copy it to a plain file, and never log it.
4. **Send only what the macOS app sends.** The username and, per shared provider per day, the token counts. No cost, models, projects, paths, prompts or emails ([privacy](https://github.com/tddworks/ClaudeBar/blob/main/docs/features/leaderboard/design.md#6--privacy)).
5. **Count a day with ClaudeBar's package.** Its log readers and its daily totals are the Mac's: a day uploaded again replaces it, never adds to it; every login on the machine is summed; days without tokens are skipped. Don't count a day any other way.

## Where things go

- Windows bugs and features (UI, packaging, the installer): issues in this repo.
- API, signing or definition changes, and the shared code's Windows adapters: an issue or PR in [tddworks/ClaudeBar](https://github.com/tddworks/ClaudeBar) first.
