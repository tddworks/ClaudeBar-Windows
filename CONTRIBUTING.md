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

## Checks before a PR

The **Windows client** workflow runs on every PR to `main`, every push to
`main`, and on demand. Its **Build and test Windows client** check uses a fresh
x64 `windows-latest` runner, Swift 6.3.3 and .NET 10. It runs the existing
`build.ps1` (the native DLL, uploader, runtime staging and self-contained WinUI
app), then `swift test --package-path native` in the same PowerShell session
so the tests inherit the MSVC environment the build script loaded. Either
failure fails the check. It does not launch the GUI, join the Leaderboard
or upload data; those need separate verification.

For the same check locally, from the repository root on Windows:

```powershell
& .\build.ps1
if (-not $?) { exit 1 }
swift test --package-path native
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

## Releases

A release is a tag. Set the version in both `native/Sources/ClaudeBarWindows/Client.swift`
(`Client.version`, which the app sends as `X-Client`) and `app/ClaudeBar.csproj`
(`Version`), merge, then push `v<version>` on `main`. The same workflow checks the
tag matches both, builds and tests as above, and a second job, the only one with
write access, publishes `ClaudeBar-Windows-<version>-x64.zip` and its SHA-256 as a
pre-release. Before tagging, run the build on a Windows PC and open the app: CI
never launches it.
