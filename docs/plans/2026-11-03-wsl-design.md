# Tools in WSL (design, 2026-11-03)

Many people on Windows run Claude Code, Codex and the rest inside WSL. Their sign-ins, logs and CLIs are in the distro's Linux home, and ClaudeBar for Windows reads only `%USERPROFILE%`, so those tools show as not set up, or not at all, and their tokens never reach the Leaderboard. This reads them where they live. Evidence: [`design-concept/wsl/research.md`](../../design-concept/wsl/research.md); the spike is on branch [`spike/wsl-probe`](https://github.com/tddworks/ClaudeBar-Windows/tree/spike/wsl-probe).

## Decisions

- **ClaudeBar itself, built for Linux, runs inside the distro:** `claudebar-probe`, from ClaudeBar's package with its Linux adapters (`LinuxProcesses`, `LinuxPty`, `{{platform.appData}}`, the time zone). Inside the distro, a tool's paths, `${VAR}`s, CLI and logs are where ClaudeBar on Linux expects them, so the package needn't know about WSL, and CLIs work from the start.
- **Rejected: the package reads a "place" over `\\wsl.localhost`.** It needs a new parameter in the shared code, still can't run a CLI, needs SQLite copied off the 9P share, can't see the distro's environment (`CODEX_HOME` set in `.bashrc`), and reading the share boots a stopped distro.
- **Rejected: an account per tool pointing into WSL** (`{{account.folder}}` = `\\wsl.localhost\…\.claude`). This app has no account settings, the Leaderboard reads default logins only, a CLI source would run the Windows CLI against the Linux folder, and every read boots the distro.
- **Rejected: junctions** from `%USERPROFILE%\.claude` into the distro. They break a Windows install of the same tool, boot the distro whenever anything touches the folder, and change the person's files to make a reading.
- **Only running distros are read,** from `wsl.exe -l --running -q`, which starts nothing. A stopped distro keeps its last reading, marked as such.
- **The glibc x86_64 build ships first.** The musl build needs nothing in the distro, but needs two packages patched and still hangs in a refresh (research). arm64 isn't in the first release.

## Phases

1. **The HUD, Limits and Settings for WSL, and the probe.** Builds on ClaudeBar as pinned today. The uploader sends this PC's days only, as now.
2. **WSL days on the Leaderboard.** Waits for a change in ClaudeBar (*Labelled days*, below) and a pin bump. No WSL day is sent before it, so none can shrink when it comes.

Two changes go to ClaudeBar first, as problem-first issues (drafts in this PR's description, not posted):

- **Labelled days**, for phase 2. At ClaudeBar `origin/main` (`6d3d5906`; these files are the same at the pin `da68b4a3`), the uploader takes days only as `TokenLogs.days(in:) -> [LoginDays]` (`LeaderboardUploader.swift:73-74`), and `LeaderboardMembership.dailyTokens(from:)` dates each with this PC's calendar (`DailyTokens.summed`, `DailyTokens.swift:51-57`, via `day(of:calendar:)` at 60-63), so a distro's day would get Windows' label. The smallest change is three files in `Modules/Leaderboard/Sources`, with their tests and `docs/features/leaderboard/design.md`'s table: in `DailyTokens.swift`, `DailyTokens.summed(_ days: [DailyTokens], providers:)` and a `TokenLogs` requirement `labelledDays(in:) -> [DailyTokens]`, empty by default in an extension, so the Mac's `MonitorTokenLogs` doesn't change; in `LeaderboardMembership.swift`, `dailyTokens(from:labelled:)`, adding them after the logins behind the same `sharing` filter, where the rule that only shared providers leave the device lives; in `LeaderboardUploader.swift`, passing `logs.labelledDays(in:)` along.
- **Version managers in `commonPaths`** (*PATH*), for phase 1 to find CLIs installed with nvm, Volta, fnm, mise or asdf; `Internal/Linux/Process/LinuxProcesses.swift` only. Without it those CLIs show as not set up.

## The probe

- **The same code as the Windows side.** `HudMonitor`, `HudReading`, `ProviderTokenLogs` and `ClaudeBarSettings` move to a target of their own, `ClaudeBarShared`, which `native/` and the probe's `linux/` package both build, at the same ClaudeBar commit. `SettingsFile` stays Windows-only (it imports `WinSDK`).
- **The launch:** `wsl.exe -d <distro> -e env CLAUDEBAR_WSL_RUN=<id> <probe> --json --windows-roots <file>`. `-e` runs it as the distro's default user without a shell, so none of the person's shell files run and nothing they print gets in the JSON.
- **Its answer** is `ProbeReading`, one `Codable` type in `ClaudeBarShared`:
  - `hud`: the HUD's answer, `{reading, readAt, problems, looks}`, exactly what `cbw_hud_reading` returns for this PC; `null` with `--logs-only`.
  - `days`: `[DailyTokens]`, ClaudeBar's own day (`provider`, `day` as `yyyy-MM-dd`, five token counts), made in the probe by `DailyTokens.summed` with the distro's calendar. The wire carries day labels, never `Date`s.
  - `tools`: each tool found and where (its CLI's path, or *logs only*); `skipped`: each source left out as shared with Windows (*Folders shared with Windows*), with its Windows path.
  - `version` (the client's), `timeZone` (the distro's), `timedOut`, and `diagnostics` (a fallback taken, a path that couldn't be mapped).
- **`--deadline <s>`** (60 by default) bounds the refresh. When it passes, the probe answers with the HUD as read by then, logins still reading marked `reading`, and `timedOut: true`. The days are read after it, whole, every time. With no answer 60 s after the deadline, the probe ends its CLIs and exits 2 with nothing; a run without an answer replaces nothing.
- **`--logs-only`** skips the refresh: no CLI, no pty, no network. The uploader uses it, from phase 2.
- **The marker.** Killing `wsl.exe` doesn't end the Linux side, and a CLI is reparented to `init` when the probe dies, so the processes of a run are found by `CLAUDEBAR_WSL_RUN=<id>` in `/proc/<pid>/environ`. That file shows the environment at `execve`, so the marker is set by `env` before the probe is exec'd, never by the probe; its children inherit it, since every Linux child ClaudeBar starts gets the app's environment (`LinuxProcesses.environment(for:_:)`). `env` rather than `WSLENV`: the marker stays in the one command line the app builds, and the person's `WSLENV` is untouched. The probe refuses to run without it (exit 3).
- **`--end <id>`** sends `SIGKILL` to every process carrying that id, the probe included, and reads again until none is left. It runs without the marker, so it never matches itself. The app runs it when no answer comes 90 s after the deadline, only while that run's `wsl.exe` is still running and the distro still in `wsl.exe -l --running -q`, then kills `wsl.exe`. A probe that ends on its own has ended `wsl.exe` too. Checking and launching aren't one step, so this is best effort: a distro that stops in between is started again, and `--end` finds nothing.

## Where it ships

- Beside `ClaudeBar.exe`: `linux\x64\claudebar-probe` and its resource bundle, in the release zip and the Velopack package, so it's always the app's own version. 27.5 MB more in the zip.
- It runs from there, over drvfs: `/mnt/c/Users/<you>/AppData/Local/ClaudeBarWindows/current/linux/x64/claudebar-probe`, its Linux path from `wsl.exe -d <distro> -e wslpath -u '<Windows path>'`, once per distro per start. Nothing is copied into the distro: running from drvfs is no slower than from ext4.
- **An update.** While a Linux program runs from a folder, Windows can't rename the folder (it can delete it). Velopack applies an update by renaming `current`, and stops only Windows processes first, so an update during a probe fails, changes nothing, and can be tried again. So before *Update* quits the app for Velopack, the app takes every distro's mutex, which waits for a probe the app or the uploader runs. They're released when the app exits, so an hourly upload can still start one before Velopack renames: best effort, and a `--logs-only` run ends inside Velopack's 10 s of retries. A probe that runs across an update keeps its open file, and the version check refuses its answer. An uninstall deletes the folder and doesn't wait.

## Running it

- **When:** for each distro that's on in Settings and running: the full probe at each HUD refresh (every 10 minutes, and *Refresh*), and from phase 2 `--logs-only` at each hourly upload. Only the HUD's refresh runs a tool's CLI in the distro.
- **One at a time,** per distro: the app and the uploader wait on a named mutex for it, as they do for the settings file.
- **How long:** about 25 s warm, most of it Claude's CLI; 57 s on the first run after the distro starts. The HUD shows this PC's logins first and a distro's when its answer comes.
- **It doesn't start a distro on purpose,** best effort: one that stops between the listing and the launch is started again by `wsl.exe`, which takes 27–36 s.
- **It doesn't keep one running.** WSL stops a distro 15 s after its last process ends, and the probe's processes end with it.

## PATH

- **No shell** (`-e`): the fastest launch, running none of the person's files. Every tool on the PC was found without one, from ClaudeBar's own tool folders. Rejected: `bash -lic`, which runs the shell files on every refresh and still misses a tool set up in `.zshrc`. A variable read with `loginShell: true` (Z.ai's `ZAI_API_KEY`) still comes from ClaudeBar's login shell (`$SHELL -l -i -c`).
- **Windows' `PATH` is dropped.** WSL appends it (`appendWindowsPath`), and a Windows npm install's extensionless shim (`…/AppData/Roaming/npm/codex`) would be found before a Linux tool and run Windows' Node. Before anything looks for a CLI, the probe drops every `PATH` entry under one of the distro's Windows-drive mounts, a rule about WSL that belongs in the probe, not the package.
- **The mount rule.** A drive mount is a line of `/proc/self/mountinfo` whose filesystem is `drvfs`, or `9p` with `aname=drvfs` among its options (split on `,`, then `;`); its mount point, unescaped (`\040`), is the root. Under a root means by whole components: `/mnt/cache` isn't under `/mnt/c`, and trailing slashes don't count. `/mnt/wsl`, `/mnt/wslg` and `9p` with `aname=drivers` aren't drives. No `/mnt/` prefix and no `wsl.conf` parsing: `[automount] root` can put drives at `/win/c` or `/c`, and `wsl.conf` can differ from the mounts until a restart. If mountinfo can't be read, the root of `wslpath -u 'C:\'` without its letter is used, with a diagnostic.
- **Version managers** aren't found: their folders are added by shell setup, interactively only. ClaudeBar's fix adds `~/.nvm/versions/node/*/bin` (nvm's default first), `~/.volta/bin`, `~/.local/share/fnm/aliases/default/bin`, `~/.local/share/mise/shims` and `~/.asdf/shims` to `commonPaths`, which a child's `PATH` gets too; it helps a ClaudeBar started outside a shell on any Linux.

## Folders shared with Windows

Some people point WSL at the Windows folder (`~/.claude -> /mnt/c/Users/<you>/.claude`, `CLAUDE_CONFIG_DIR` or `CODEX_HOME` on `/mnt/c`). Then both sides read the same logs and credentials: the days would count twice and the account show twice. Being on a drive isn't the test: a WSL-only `~/.claude -> /mnt/d/wsl-data/.claude` is never read by Windows, which reads its own `${CLAUDE_CONFIG_DIR:-~/.claude}` (`claude.json`: the folder's default at line 413, the records at 376). The test is whether both read the same place, and a shared source is skipped, not read and then filtered.

- **The app's roots, passed in.** Before the launch, the app writes its own roots per provider to `%LOCALAPPDATA%\ClaudeBar\wsl\windows-roots.json`, expanded as `TokenLogs` and the factory do (`DataSources.expandPath` with this PC's home and environment): the credential roots, the account folder (`accounts.folder.default`) and the files `dataSources(forDefaultAccount:)` reads; and the log roots, the folder of `usageHistory(forDefaultAccount:)`'s records before the first wildcard. Each is resolved through symlinks and junctions (`GetFinalPathNameByHandleW`). The probe gets the file's Linux path as it gets its own.
- **The probe's side.** It expands the same roots in the distro, resolves each with `realpath`, and maps one under a drive mount to its Windows path from that mount's `path=` option (`/mnt/c/Users/<you>/.claude` is `C:\Users\<you>\.claude`), or `wslpath -w` without one. A root that doesn't map isn't shared, with a diagnostic.
- **Matching,** pure, in `ClaudeBarShared`, against the same provider's Windows roots: case-insensitive, `\` and `/` the same, no trailing separator; shared when the two are the same or one is an ancestor of the other by whole components (`…\.claude\.credentials.json` is under `…\.claude`; `…\.claude-work` isn't).
- **What ClaudeBar lets the probe skip,** at `origin/main`, without a change:
  - a whole provider: `isEnabled(forProvider:defaultValue:)`, read by `Provider.productSwitch` (`Provider.swift:103`);
  - the data source in use: `dataSourceKind(forProvider:)` (`Configuration.activeKind`), and a fallback only when the definition makes it switchable (`Configuration.isFallbackEnabled`, `enabledBySetting`). Claude's `cli` falls back to `api` always; `api` to `cli` only while `cliFallbackEnabled` is on. Codex's `rpc` falls back to `tty` always.
  - Nothing turns off one source or points it elsewhere: the paths come from the definitions and `${CLAUDE_CONFIG_DIR}`, `${CODEX_HOME}` in the environment. The smallest hook would be a per-kind switch that `Configuration` consults when it picks the active source and follows a fallback.
- **So the probe skips per provider, per kind of source,** with no change in ClaudeBar:
  - a shared credential root turns the provider off for the refresh, through the probe's settings (a view over `ClaudeBarSettings` answering `isEnabled` false), so the probe never reads or refreshes a Windows `.credentials.json`;
  - a shared log root leaves that provider out of the probe's `ProviderTokenLogs`, this repo's code;
  - each skip is in `skipped`, and Settings says *shared with Windows* beside it.
  - Tradeoff: a provider with one shared credential source and one distinct loses its WSL limits; its distinct logs still count. Per-source skipping keeps those limits but needs the hook above, for a case the built-in definitions don't make: Claude's and Codex's sources all read their account folder.

## The HUD, Limits and Settings

- **A WSL login is a login of its own,** beside the Windows one: `Claude · WSL`, or `Claude · WSL Ubuntu-26.04` when more than one distro is read. Its lineup id is the probe's prefixed with the distro (`wsl:Ubuntu-26.04/claude`); a group keeps both (`wsl:Ubuntu-26.04/omp/Claude · work`).
- **The Swift side merges them,** so `cbw_hud_reading` keeps its shape: each distro's tools, problems and looks after this PC's. The C# app learns one new problem kind, `notRunning`: the distro isn't running, and its last numbers stay dimmed with their time (*WSL isn't running · numbers from 14:05*).
- **Not shown for WSL:** `notSetUp`, which would list every provider twice, and a failure that says Linux can't read that source at all (Antigravity's local server).
- **Settings → Tools in WSL:** the distros `wsl.exe -l -q` lists, without `docker-desktop*` and `rancher-desktop*`; for each, whether it's running, an on/off switch (on by default once a reading finds a tool), and from its last reading the tools and where, with *shared with Windows* beside a skipped source, and a note when its time zone isn't Windows'. Kept in `app.json` (`wsl: {"Ubuntu-26.04": {"on": true}}`) with each distro's last reading.

## The Leaderboard (phase 2)

- **The uploader runs `--logs-only`** in each running distro that's on, and its `TokenLogs.labelledDays(in:)` returns each distro's `days` with a label in the range. ClaudeBar adds them to this PC's days per provider and label, behind the `sharing` filter. A request counts once: a shared log is read on the Windows side only. One device, one key, the server's cap, unchanged.
- **The labels are the distro's.** A `DailyUsageStat` holds one date per day and no record times, so Windows can't put a distro's tokens into its own days; re-dating a day would only move it, whole, onto the wrong label. WSL keeps the zones equal by default (`useWindowsTimezone`).
- **No day shrinks because a distro couldn't be read.** An upload replaces a day it sends again, so each distro's last `days` are kept with their labels (`%LOCALAPPDATA%\ClaudeBar\wsl\<distro>.json`) and sent while it isn't running. Only an answer replaces them. An answer is what the logs say now, as for this PC: a tool that deletes its logs (Claude Code's `cleanupPeriodDays`) can make a re-sent day smaller on either side, and keeping the larger total would count tokens no log holds (CONTRIBUTING rule 5).
- **A distro switched off or removed** (`wsl --unregister`) is like a provider whose sharing is turned off: `stopSharing` only stops uploads, and *days already uploaded stay until you leave* (ClaudeBar's Leaderboard README). Its kept days are frozen, not deleted, until they leave the upload window or the person leaves the Leaderboard.

## Keeping the probe and the app in step

- `ProbeReading` is one type, encoded by the probe and decoded by the app from the same source file; `HudReading`, `HudMonitor.Answer` and the problem and look types become `Codable`. Its days are ClaudeBar's `DailyTokens`, so the label format is ClaudeBar's on both sides.
- The probe says its version; another version's answer is a failure, never read in part.

## Providers in WSL

| Provider | In WSL |
|---|---|
| Claude | Reads: CLI on the pty, then the API from `~/.claude/.credentials.json`; logs from `~/.claude/projects` |
| Codex | Reads: the app-server, the API from `~/.codex/auth.json`, `/status` on the pty; logs from `~/.codex/sessions` |
| Oh My Pi, OpenCode Go | Reads: `omp usage --json` and `~/.omp/agent/sessions`; `opencode.db` in place |
| Gemini, Grok, Kimi, Kiro, Amp, Command Code, Cline, Mistral (logs), Z.ai, the API-key providers | Read when set up in the distro |
| Copilot | The token from the environment or a setting; `gh`'s keychain item is Unavailable on Linux |
| Antigravity, Bedrock | Unavailable: no local-server reading on Linux yet (not shown for WSL); ClaudeBar builds its AWS clients for the Mac only |
| Cursor, Windsurf, JetBrains | Not applicable: Windows apps, read on the Windows side |

## Errors

| What happens | What the person sees |
|---|---|
| No WSL, or no distro | Settings says *WSL isn't installed* or *No distros* |
| The distro is stopped | `notRunning`, the last numbers dimmed |
| `wsl.exe` fails, or the probe can't start (no `libcurl.so.4`, not x64, the drive not mounted, no marker: exit 3) | `failed`: *ClaudeBar couldn't run in Ubuntu-26.04: <the error's first line>*, on the HUD, Limits and Settings |
| The answer comes at the deadline | Logins still reading say `failed`, *Took too long in WSL* |
| No answer 90 s after the deadline | `--end`, then `wsl.exe` killed; `failed`, and kept days stay |
| Another version answered, or the JSON doesn't parse | `failed`, *ClaudeBar's WSL reader is from another version* |
| A source is shared with Windows | Not an error: it's skipped, and Settings says *shared with Windows*. A root that can't be mapped to a Windows path is treated as not shared, with a diagnostic |
| The upload can't read a distro (phase 2) | Its kept days are sent; the log says why |
| An update starts during a probe | Velopack's *Unable to start the update, because one or more running processes prevented it*; the old version stays, and *Update* can be tried again |

## Tests

- **`ClaudeBarShared`, pure:** `ProbeReading` round trip (labels and counts) and a checked-in sample (`tests/wsl-probe.json`), so a field renamed on one side fails CI; the merge into the lineup (ids, names, `notSetUp` and platform failures dropped, `notRunning` with the kept numbers).
- **Matching, pure, paired:** a WSL `~/.claude` symlinked to the folder Windows reads: skipped; on a drive but elsewhere (`/mnt/d/wsl-data/.claude` against `C:\Users\<you>\.claude`): kept; `CODEX_HOME` shared with Claude distinct: only Codex skipped; a shared credential with a distinct log root: the provider off for the refresh, its days kept; case, mixed separators, a trailing separator, an ancestor either way, and `.claude-work` against `.claude`, not shared.
- **Mount rule, pure, over mountinfo text** (the PC's lines as fixtures): a `/mnt/` root, a `/win/` root, root `/`; `/mnt/cache`, `/mnt/wslg`, `/mnt/wsl` and `aname=drivers` kept; a trailing slash; `drvfs` and `9p aname=drvfs` lines; no drive mounts, everything kept. And with a `/win/` root and an npm shim fixture before a Linux `codex`, the Linux one is found.
- **Days in mixed zones, pure** (phase 2, explicit calendars): a distro in Asia/Seoul and Windows in UTC, both with a day labelled `2026-11-04`, sum into one `2026-11-04`, nothing on `2026-11-03`; a distro day with no Windows day is kept as it is; a frozen distro's kept days keep their labels.
- **Windows:** `wsl -l -q` parsing (UTF-16LE without BOM, CRLF, empty with exit 0), the excluded distros, the roots file from a temp home with a junction resolved, the kept and frozen days.
- **The probe, on the Linux runner:** its `--json` decodes; without the marker it exits 3; with a fixture CLI that never answers, the answer comes at the deadline with `timedOut` and whole days, and no process it started is left; `--logs-only` gives `hud: null`, the same days, and runs no CLI (the fixture writes a file when it runs); `--windows-roots` skips a shared fixture root, mapped through a fixture mount with `path=C:\`.
- **`--end`, on the runner:** a fixture CLI starts a grandchild with `setsid` and exits, so it's reparented to `init`; the probe is stopped (`SIGSTOP`) and `--end` run without the marker. Then `kill -0` fails for the probe's PID and the grandchild's, by number, since "no marked process left" would pass with a probe that lost its marker. The test `wait`s for the probe, on a runner whose PID 1 reaps orphans, since a zombie still answers `kill -0`.
- **ClaudeBar's fixes, in their PRs:** the locator finds a tool in each version manager's folder (folders given to it, no real home); `dailyTokens(from:labelled:)` adds labelled days behind `sharing`.
- **On a PC:** a running distro's tools on the HUD as `· WSL`; *Refresh*; a stopped distro shows `notRunning` without being started; from phase 2, an upload's preview adds its days. No screen step while the PC is in use.

## Open questions for hanrw

1. **musl.** Would you take `Musl` beside `Glibc` in the process code, SwiftTerm ≥ 1.16.0, and a Static Linux SDK job in the Linux CI? The patched build still hangs in a refresh, so that needs finding first.
2. **A Linux product.** Should the probe, or a `claudebar --json` like it, live in ClaudeBar's package for a future Linux client?
3. **Writing in the distro.** ClaudeBar's file log and CLI folder land in `~/.local/share/ClaudeBar`, and Claude Code records its trust for that folder in `~/.claude.json`. Fine as ClaudeBar on Linux, or should a probe log to stderr only?
