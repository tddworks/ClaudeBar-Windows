# Contributing

Thanks for helping bring ClaudeBar to Windows.

## Rules for using the Leaderboard server

These are the conditions for using `claudebar-api.tddworks.com` from this client:

1. **Identify the client.** Every request carries `X-Client: claudebar-windows/<version>`. It is not a credential; it lets the server tell clients apart and refuse a broken version.
2. **Pass the signing vectors.** CI verifies the canonical signing string against ClaudeBar's `vectors.json`, copied at a pinned commit. Bump the pin on purpose, never silently.
3. **Keep the private key on the machine.** Store it with Windows Credential Manager or DPAPI, never in a plain file, and never log it.
4. **Send only what the macOS app sends.** The username and, per shared provider per day, the token counts. No cost, models, projects, paths, prompts or emails ([privacy](https://github.com/tddworks/ClaudeBar/blob/main/docs/features/leaderboard/design.md#6--privacy)).
5. **Count a day the way ClaudeBar does.** Upload a day again to replace it, never to add to it; sum every login on the machine; skip days without tokens.

## Where things go

- Windows bugs and features: issues in this repo.
- API, signing or definition changes: an issue or PR in [tddworks/ClaudeBar](https://github.com/tddworks/ClaudeBar) first.
