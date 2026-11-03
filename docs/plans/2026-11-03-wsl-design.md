# Tools in WSL (design, 2026-11-03)

Many people on Windows run Claude Code, Codex and the rest inside WSL. Their sign-ins, logs and CLIs are in the distro's Linux home, and ClaudeBar for Windows reads only `%USERPROFILE%`. So those tools show as not set up, or not at all, and their tokens never reach the Leaderboard.

This reads them where they live. A Linux build of ClaudeBar's package, `claudebar-probe`, runs inside each running distro, reads every provider there as ClaudeBar on Linux would, and hands the Windows app the same answer the C interface already gives for this PC. The spike is on branch [`spike/wsl-probe`](https://github.com/tddworks/ClaudeBar-Windows/tree/spike/wsl-probe) (`linux/`, `.github/workflows/wsl-probe.yml`); every number below was measured there, on GitHub's `ubuntu-latest` and on one PC (Windows 10.0.26200, WSL 3.0.3.0, kernel 6.18.54.1, `Ubuntu-26.04` with Claude Code 2.1.160, Codex 0.136.0, omp and OpenCode installed, `systemd=true`, no `.wslconfig`).

## Decisions

- **ClaudeBar itself, built for Linux, inside the distro.** ClaudeBar's package already builds and passes its tests on Linux (its Linux CI), and has the Linux adapters a reading needs: finding and running programs (`LinuxProcesses`), a CLI on a pty (`LinuxPty`), `{{platform.appData}}` (`XDG_DATA_HOME` or `~/.local/share`) and the time zone. Inside the distro, a tool's paths, its `${VAR}`s, its CLI and its logs are where ClaudeBar on Linux expects them, so nothing in the package has to know about WSL. Every kind of data source Linux has works, CLIs included: there is no first phase of files only and a second of CLIs.
- **Rejected: B, the package reads a "place" over `\\wsl.localhost`.** The factory and the log readers would take a home and an environment (`//wsl.localhost/<distro>/home/<user>`, no `${VAR}`s, no `{{platform.appData}}`). It needs a new parameter in the shared code, and still can't run a CLI: Claude's `claude /usage`, Codex's app-server and omp's `omp usage` would need a runner through `wsl.exe`, a second design. SQLite over the 9P share needs a copy first. The distro's environment (`CODEX_HOME` set in `.bashrc`) is invisible from Windows. And reading the share boots a stopped distro: measured, `Test-Path \\wsl.localhost\Ubuntu-26.04\etc\passwd` started it and took 4.9 s.
- **Rejected: an account per tool pointing into WSL** (`{{account.folder}}` = `\\wsl.localhost\…\.claude`). The path language takes UNC roots, but this app has no account settings, the Leaderboard reads default logins only (`DefaultProviderSettings`), a CLI source would still run the Windows CLI against the Linux folder, and every read boots the distro.
- **Rejected: junctions** from `%USERPROFILE%\.claude` into the distro. They break a Windows install of the same tool, which writes the same folder; they boot the distro whenever anything touches the folder; and they change the person's files to make a reading.
- **Only running distros are read.** `wsl.exe -l --running -q` starts nothing (measured: both distros stayed *Stopped*), and neither does `wsl.exe -l -v`. Running the probe in a stopped distro would boot it, so a stopped distro keeps its last reading, marked as such.

## The probe

`claudebar-probe` is an executable in this repo's `linux/` package, at the same ClaudeBar commit as `native/`. It makes ClaudeBar's `QuotaMonitor` over every provider ClaudeBar finds, as `HudMonitor` does on Windows, refreshes every login once, reads the token logs, prints one JSON object and exits.

- **The same code as the Windows side.** `HudMonitor`, `HudReading`, `ProviderTokenLogs` and `ClaudeBarSettings` are the files in `native/Sources/ClaudeBarWindows`, not copies: they move to a target of their own, `ClaudeBarShared`, which both packages build (the spike links the four files). `SettingsFile` stays Windows-only: it imports `WinSDK` for its named mutex.
- **Its output** (`--json`) is `ProbeReading`, one `Codable` type in `ClaudeBarShared`:
  - `hud`: the HUD's answer, `{reading, readAt, problems, looks}`, exactly what `cbw_hud_reading` returns for this PC. `null` with `--logs-only`.
  - `logins`: for each provider with logs, its days (`LoginDays`: the provider and its `DailyUsageStat`s), what `TokenLogs.days(in:)` returns.
  - `sources`: for each login, where each of its sources really is (*Folders shared with Windows*, below): every log root and every credential file or folder, resolved with `realpath`, and for one under a drive mount its Windows path as well. Each entry of `logins` names the log root it was read from, so the app can leave out what it reads itself.
  - `version` (the client's), `timeZone` (the distro's) and `timedOut`.
  - The spike prints the same parts flat, with the days already summed (`DailyTokens`) and each part's seconds, and no `sources`; the first release sends `LoginDays`, so the uploader sums the distro's days with this PC's in one place.
- **`--logs-only`** skips the refresh: no `QuotaMonitor`, no CLI, no pty, no network. It reads the logs and the sources and answers with `hud: null`. The uploader uses it (*The Leaderboard*). Measured in the spike, the log read for 30 days took 0.16–0.18 s warm, and 22 s on the first run after the distro started; a refresh took 24–25 s warm, most of it Claude's CLI.
- **A deadline of its own** (`--deadline`, 60 s by default), for the refresh only. When it passes, the probe answers with the HUD as read by then, each login still reading marked `reading`, and `timedOut: true`. The logs are read after that, whole, every time: `logins` is never cut by the deadline, so `timedOut` says nothing about it. If the logs aren't read 60 s after the deadline either, the probe ends its children and exits with no answer (exit 2), and a reading without an answer replaces nothing.
- **Its children end with it.** Killing `wsl.exe` on Windows doesn't end the Linux side: measured, a hung probe and its pty kept running in the distro after its `wsl.exe` was killed, and kept the distro up, until `pkill` inside the distro. Killing the probe alone isn't enough either: `pkill -f <probe path>` matches only the probe, since its CLIs have command lines of their own, and once the probe dies they're reparented to `init`, so nothing finds them as its children any more.
  - Each run carries an id the app makes, as a variable set **before the probe is exec'd**: the app runs `wsl.exe -d <distro> -e env CLAUDEBAR_WSL_RUN=<id> <probe> --json`. It has to be set then, not by the probe: `/proc/<pid>/environ` shows the environment a process was exec'd with (proc_pid_environ(5)), and a later `setenv` changes only the process's memory. Measured on a Linux runner, a C program that calls `setenv("CLAUDEBAR_WSL_RUN", "late")` reads `late` from `getenv` and finds nothing in its own `/proc/self/environ`; started as `env CLAUDEBAR_WSL_RUN=x`, its environ shows `CLAUDEBAR_WSL_RUN=x` (and `getenv` still `late`). So a probe that set the marker itself would be the one process `--end` can't find.
  - `env` rather than `WSLENV=CLAUDEBAR_WSL_RUN/u` on `wsl.exe`: the marker is in the one command line the app builds, it doesn't touch the person's own `WSLENV`, and `env` execs the probe in its own place, so the process `wsl.exe` started is the probe.
  - The probe reads the marker at startup and refuses to run without it (*claudebar-probe: started without CLAUDEBAR_WSL_RUN; run it as `env CLAUDEBAR_WSL_RUN=<id> claudebar-probe`*, exit 3), so a launch that lost the marker fails at once instead of running where nothing could end it.
  - Its children inherit the marker from that exec-time environment: every child ClaudeBar starts on Linux (pipes, the pty, scripts) gets `LinuxProcesses.environment(for:_:)`, which starts from `appEnvironment`, `ProcessInfo.processInfo.environment`, and only changes `PATH` and the definition's own names. Measured on the runner: under `env CLAUDEBAR_WSL_RUN=x sh -c …`, a grandchild started by `setsid` and reparented to `init` (ppid 1, a session of its own) shows `CLAUDEBAR_WSL_RUN=x` in its environ.
  - The probe ends its CLIs itself before exiting (ClaudeBar's teardown: `SIGTERM`, then `SIGKILL`).
  - When no answer comes 90 s after the deadline, and that run's `wsl.exe` is still running and the distro is still in `wsl.exe -l --running -q`, the app runs `wsl.exe -d <distro> -e <probe> --end <id>`. It reads `/proc/*/environ`, sends `SIGKILL` to every process carrying that run's id, the probe included, and reads again until none is left (a process can start a child between the read and the kill). `--end` runs without the marker (it's the one mode that doesn't need it), so it never matches itself. Then the app kills `wsl.exe` and reports `failed`. A probe that ended on its own (exit 2, 60 s after the deadline) has already ended `wsl.exe` too, so `--end` is for a probe that's still there, in a distro its `wsl.exe` keeps running; a stopped distro has no processes to end and is skipped. The check and the launch aren't one step, so this is best effort: a distro that stops between them is started again by `--end`, which then finds nothing.
- **What it writes in the distro.** ClaudeBar's file log, `~/.local/share/ClaudeBar/Logs/ClaudeBar.log`, and the folder a CLI runs in, `~/.local/share/ClaudeBar/Probe`, as ClaudeBar on Linux does. A CLI source writes what that CLI writes when it runs: Claude Code recorded the trust it was given for that folder in `~/.claude.json` (measured). Claude's API source refreshes `~/.claude/.credentials.json` when its token expires, as on the Mac.

### Build

The spike built three variants on `ubuntu-latest` in the `swift:6.3.3-noble` image (Swift 6.3.3, the Windows build's version).

| | glibc, x86_64 | Static Linux SDK (musl), x86_64 | musl, aarch64 |
|---|---|---|---|
| Build, clean, release | 355 s | 356 s | 509 s |
| Binary, raw | 116.9 MB | 211.5 MB | 209.9 MB |
| Binary, stripped | 71.0 MB | 73.6 MB | not stripped (the runner's `strip` is x86-64 only) |
| Resource bundles | 1 (`ClaudeBarKit_Providers.resources`), 0.22 MB | the same | the same |
| The folder, zipped | 27.5 MB | 29.5 MB | 73.6 MB |
| Needs in the distro | `libcurl.so.4`, `libstdc++.so.6`, `libgcc_s.so.1`, glibc | nothing | nothing |
| On the PC | answered: 57 s on the first run, 25 s warm | **hung**: the refresh never finished | not run (the PC is x64) |

- **The resource bundle travels with the binary.** The provider definitions are a SwiftPM resource, which `Bundle.module` looks for beside the executable. Without it the probe stops at once: `Fatal error: could not load resource bundle` (measured).
- **musl needs changes in two packages,** patched in the spike's checkouts:
  - SwiftTerm 1.12.0, which ClaudeBar pins exactly, imports `Glibc` on any Linux. SwiftTerm fixed it in 1.16.0 ([#612](https://github.com/migueldeicaza/SwiftTerm/pull/612)).
  - ClaudeBar's process code checks `canImport(Glibc)` (`PtySession`, `ProcessEnd`, `ChildTeardown`), so under musl the pty and a child's teardown would compile to nothing; `LinuxPty` imports `Glibc` outright and calls `Glibc.open`; `ProcessEnd` reads glibc's `siginfo_t` fields (`_sifields._sigchld`).
  - With those patched it builds and runs, but on the PC a refresh never finished: at the deadline, 9 logins were still `reading` that the glibc build had answered, and an earlier run without a deadline held a pty with no child for 15 minutes. The cause isn't found; a child's end not being noticed under musl is the first suspect.
- **So the first release ships the glibc build.** Ubuntu 26.04 has its libraries. A distro without `libcurl.so.4` gets a probe that can't start, which says so (see *Errors*). musl, a binary that needs nothing, is the better end state, and needs the two packages fixed and a musl job in ClaudeBar's Linux CI first (*Open questions*).
- arm64 is the same work again for a Windows-on-Arm PC, and builds in 509 s. Not in the first release.

### Where it ships, and how it's found

- In the app's folder, beside `ClaudeBar.exe`: `linux\x64\claudebar-probe` and its resource bundle. The release zip and the Velopack package carry it, so an update replaces it with the app, and the probe is always the app's own version. It adds 27.5 MB to the zip.
- The app runs it from there, through the distro's mount of the Windows drive: `/mnt/c/Users/<you>/AppData/Local/ClaudeBarWindows/current/linux/x64/claudebar-probe`. An ELF on drvfs runs: the mount marks every file executable (measured: `-rwxrwxrwx`), and the spike ran from `/mnt/h/…`. The Linux path comes from `wsl.exe -d <distro> -e wslpath -u '<Windows path>'`, once per distro per start, because a distro can mount drives elsewhere (`[automount] root`).
- Nothing is copied into the distro. Measured warm, reading 30 days: 25.0 s from `wsl.exe` to the answer from drvfs, 29.0 s from a copy in `/tmp` (ext4); 24.8 s and 25.6 s inside the probe. The drive isn't the slow part, so a copy (and cleaning it up, and replacing it at each update) isn't worth it.
- **An update while a probe runs.** Velopack 1.2.161 applies an update by renaming `current` to a backup and the new version into its place (`apply_windows_impl.rs`: `fs::rename(current_dir, temp_path_old)`, retried 10 times a second apart). Before that it stops the package's own processes (`force_stop_package`), which are the Windows ones under the install folder; `wsl.exe` and the probe inside the distro aren't among them. Measured on the PC, with a Linux binary running from a drvfs folder (`wsl.exe -d Ubuntu-26.04 -e /mnt/h/…/current/linux/x64/sleep 60`):
  - `Rename-Item` of `current` failed, *access denied*, and left it as it was. So an update that starts while a probe runs fails its rename for 10 s and then stops with Velopack's *Unable to start the update, because one or more running processes prevented it*, with the old version still in place; *Update* can be tried again.
  - `Remove-Item -Recurse` of the same folder succeeded, and the binary kept running from its open file. An uninstall, which deletes the folder, doesn't wait for a probe.
  - Deleting the running file alone, and putting another file at its name, both succeeded too.
  - So before *Update* quits the app for Velopack, the app takes every distro's mutex (*One at a time*, below): it waits for a probe the app or the uploader is running, and none starts while the app holds them. They're released when the app exits, before Velopack renames, so an hourly upload can still start a probe in that gap, or be past its mutex when Velopack stops it, which leaves its `wsl.exe` and probe running. That's best effort: `--logs-only` ends within seconds, inside Velopack's 10 s of retries, and if it doesn't, the update fails as above and changes nothing. A probe that does run across an update keeps its open file, and the app's version check (*Keeping the probe and the app in step*) refuses its answer.

## Running it

- **When:** for each distro that is on in Settings and in `wsl.exe -l --running -q`: at each HUD refresh (every 10 minutes by default, and *Refresh*), the full probe; at each hourly upload, `--logs-only`, which starts no CLI and takes about 0.2 s warm (*The probe*). The HUD's refresh is the only one that runs a tool's CLI in the distro.
- **How:** `wsl.exe -d <distro> -e env CLAUDEBAR_WSL_RUN=<id> <probe> --json` (the marker: *Its children end with it*, above). `-e` runs it as the distro's default user without a shell, so nothing in the person's shell files runs and nothing they print gets in the JSON. With `--` instead, the default shell runs the command (the PATH is the same, below).
- **How long:** measured warm on the PC, 25 s from `wsl.exe` to the answer, almost all of it the refresh (24–25 s; Claude's CLI source is the slowest, about 20 s here). The first run after the distro started took 57 s: 30 s for the refresh and 22 s for the logs, which take 0.2 s on later runs for 30 days and 76 s for 400. The deadline keeps a stuck CLI from holding the HUD. The HUD shows the Windows logins as soon as they're read and the WSL logins when their answer comes.
- **It doesn't start a distro on purpose, best effort:** a distro that's running when the refresh begins can stop before `wsl.exe` reaches it, and then `wsl.exe` starts it again, because listing the running distros and launching aren't one step. Measured: two launches into a stopped distro took 27 s and 36 s, and both printed `Failed to start the systemd user session for '<user>'` on stderr. A read over `\\wsl.localhost` booted the same distro in 4.9 s.
- **It doesn't keep a distro running.** WSL stops a distro 15 s after its last process ends (`instanceIdleTimeout`, 15,000 ms by default) and the VM 60 s after that (`vmIdleTimeout`, 60,000 ms). Measured with no `.wslconfig`: the distro stopped 10–15 s after a read (polled every 5 s) and the VM's `vmmemWSL` 65 s later. Another app's process can keep it up: Orca, on this PC, runs `wsl.exe -d Ubuntu-26.04 --exec /usr/bin/node …/opencode-sqlite-reader.cjs` while the distro runs.
- **One at a time.** Distros are read one after another, and a distro is never read twice at once: the uploader and the app both wait on a named mutex per distro, as they do for the settings file.

## The environment, and where CLIs are found

ClaudeBar finds a CLI on `PATH`, then in its own list of tool folders (`LinuxProcesses.commonPaths`: `~/.local/bin`, `~/.bun/bin`, `~/.cargo/bin`, `/usr/local/bin`, `~/.npm-global/bin`, …). A child gets the same folders on its `PATH`. What the probe sees, measured on the PC with `--where` (`~` is `/home/<user>`):

| Launched with | `PATH` before the WSL defaults | Windows' `PATH` appended | Found |
|---|---|---|---|
| `wsl.exe -d D -- probe` | nothing | yes, 80 entries | claude, codex `~/.local/bin`; omp, opencode `~/.bun/bin`; node `/usr/bin` |
| `wsl.exe -d D -e probe` | nothing | yes | the same |
| `wsl.exe -d D --shell-type login -- probe` | `~/.cargo/bin:~/.local/bin` | yes | the same |
| `wsl.exe -d D -e bash -lc probe` | `~/.cargo/bin:~/.local/bin` | yes | the same |
| `wsl.exe -d D -e bash -ic probe` | `~/.jdks/…/bin:~/.cargo/bin:~/.local/bin` (×3)`:~/.bun/bin` | yes | the same |
| `wsl.exe -d D -e bash -lic probe` (what ClaudeBar's login-shell lookup runs) | as `-ic`, plus `~/.local/bin` again | yes | the same |

- Every tool was found in every mode, because each is in a folder on ClaudeBar's own list. None printed anything stray; the first launch into a stopped distro wrote the systemd warning to stderr, not stdout.
- **The shell files only help an interactive shell.** Ubuntu's `.bashrc` returns at once when the shell isn't interactive (`case $- in *i*) ;; *) return;;`, lines 6–8 here), and the PATH lines tools add sit after it (bun's at 119–121). A login shell reads `.profile`, which reads `.bashrc`, which returns. So `-lc` gets `.profile`'s own folders, and only `-ic` and `-lic` get the rest.
- **Windows' PATH is on it in every mode** (`appendWindowsPath`, true by default): `/mnt/c/Users/<you>/AppData/Roaming/npm`, `/mnt/c/Users/<you>/.bun/bin`, `/mnt/c/Program Files/nodejs/`, … ClaudeBar looks for a CLI by its exact name, and on drvfs every file is executable, so a Windows npm install's extensionless shim (`…/AppData/Roaming/npm/codex`, a shell script npm writes beside `codex.cmd`) would be found before a Linux tool in a folder that comes later, and run Windows' Node through interop. On this PC the only such file was `/mnt/c/Users/<you>/.bun/bin/omp.exe`, which the exact name doesn't match.
- **Version managers aren't found.** With a fixture as root (whose home is `/root`), a tiny script at each manager's usual place, and the folders removed afterwards:

  | Manager | Fixture | Found, no shell | Found, `bash -lc` |
  |---|---|---|---|
  | nvm | `~/.nvm/versions/node/v22.0.0/bin/codex` | no | no |
  | Volta | `~/.volta/bin/claude` | no | no |
  | fnm | `~/.local/share/fnm/aliases/default/bin/gemini` | no | no |
  | mise | `~/.local/share/mise/shims/opencode` | no | no |
  | asdf | `~/.asdf/shims/kimi` | no | no |

  ClaudeBar's list has `~/.nvm/versions`, which holds a folder per version, not programs. These tools' shell setup would add them, but only in an interactive shell, as above. And the list follows the account's home in `/etc/passwd`, not `$HOME` (measured on the runner: `home` `/root`, `$HOME` `/github/home`).

So:

1. **The probe runs without a shell** (`-e`), the fastest and the one that runs none of the person's files on every refresh.
2. **The probe drops every `PATH` entry that lies under one of this distro's Windows-drive mounts** before anything looks for a CLI, so only Linux tools are found and run. That rule is about WSL, so it belongs in the probe, not in the package.
   - The mounts come from `/proc/self/mountinfo`: the mount point of each line whose filesystem is `drvfs`, or `9p` with `aname=drvfs` among its super options. On this PC (WSL 2, no `[automount]` in `wsl.conf`) the drives are `9p` lines such as `140 88 0:72 / /mnt/c rw,noatime - 9p C:\134 rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/,cache=0x5,access=client,msize=65536,trans=fd,rfd=6,wfd=6`, one each for `/mnt/c`, `/mnt/d`, `/mnt/e` and `/mnt/h` (measured). So the options split on `,` and then `;` (`aname=drvfs` sits in `aname=drvfs;path=C:\;…`), and the mount point is unescaped (mountinfo writes a space as `\040`).
   - Kept: everything else under `/mnt`. On this PC that's `/mnt/wsl` (`tmpfs`), `/mnt/wslg` and `/mnt/wslg/distro` (`tmpfs`, `ext4`), `/mnt/wslg/versions.txt` and `/mnt/wslg/doc` (`overlay`), and `/usr/lib/wsl/drivers`, which is `9p` too but with `aname=drivers`.
   - The match is on whole path components: `/mnt/cache` isn't under `/mnt/c`, and a trailing slash on either side doesn't change it.
   - No prefix rule and no `wsl.conf` parsing: `[automount] root` can put the drives at `/win/c` or `/c`, and `wsl.conf` can say one thing while the mounts are another until the distro restarts. With `root = /win/`, a `/mnt/` rule would leave `/win/c/Users/<you>/AppData/Roaming/npm/codex` on `PATH`.
   - If mountinfo can't be read, the probe falls back to the root `wslpath -u 'C:\'` gives (here `/mnt/c/`, measured), without its drive letter, drops what lies under it, and says so in a diagnostic in its answer.
3. **A fix in ClaudeBar (tddworks/ClaudeBar, `Internal/Linux/Process/LinuxProcesses.swift` only):** add the version managers' folders to `commonPaths`: each `~/.nvm/versions/node/*/bin`, newest first (nvm's `default` alias names one, `~/.nvm/alias/default`), `~/.volta/bin`, `~/.local/share/fnm/aliases/default/bin`, `~/.local/share/mise/shims` and `~/.asdf/shims`. A child gets them on its `PATH` too, so a CLI that is a Node script finds its `node`. It fixes a ClaudeBar started outside a shell on any Linux, not just in WSL.
- Rejected: running the probe in `bash -lic`. It runs the person's shell files on every refresh, which can be slow, print, or wait for input, and it still misses a tool set up in `.zshrc`.
- A variable a definition reads with `loginShell: true` (Z.ai's `ZAI_API_KEY`) still comes from the login shell: ClaudeBar's Linux `LoginShell` runs `$SHELL -l -i -c`, and the measured `-lic` PATH shows it reads `.bashrc` in full.

## The HUD and Limits

- **A WSL login is a login of its own,** beside the Windows one: `Claude · WSL`, or `Claude · WSL Ubuntu-26.04` when more than one distro is read. Its lineup id is the probe's prefixed with the distro (`wsl:Ubuntu-26.04/claude`), so nothing in a reading collides with this PC's. A group under it keeps both (`wsl:Ubuntu-26.04/omp/Claude · work`).
- **The Swift side merges them,** so `cbw_hud_reading` keeps its shape: the tools, problems and looks from each distro after this PC's, in the distro's own order. The C# app learns one new problem kind and nothing else.
- **What a WSL login shows:** its numbers, `signedOut`, `failed`, and one new kind, `notRunning`: its distro isn't running, its numbers from the last reading stay dimmed with their time, as for a failed read (*WSL isn't running · numbers from 14:05*).
- **What it doesn't show:** `notSetUp` (each tool not in that distro, which would otherwise list every provider twice), a failure that says the platform can't read that source at all (*Reading a local server isn't available on Linux yet*, Antigravity's, measured), and limits read with a credential the Windows side reads too (*Folders shared with Windows*, below). The same tool on Windows is the one to read there.

## Folders shared with Windows

Some people point WSL at the Windows folder: `~/.claude -> /mnt/c/Users/<you>/.claude`, `CLAUDE_CONFIG_DIR=/mnt/c/…`, or `CODEX_HOME` on `/mnt/c`. Then the probe reads the logs and the credentials the Windows side reads, and without a rule the same requests would count twice on the Leaderboard and the same account would show twice on the HUD. Being on a drive isn't the test: a WSL-only `~/.claude -> /mnt/d/wsl-data/.claude` is on a drive, and Windows never reads it, because Windows reads its own `${CLAUDE_CONFIG_DIR:-~/.claude}` (`claude.json` at the pinned commit: the account folder's default at line 413, the log records `{{account.folder}}/projects/**/*.jsonl` at 376). So the test is whether the two sides read the same place.

- **The probe reports, and drops nothing.** For each login, its `sources`: each log root (a records pattern's folder before its first wildcard, `~/.claude/projects`) and each credential file or folder its data sources read (`~/.claude/.credentials.json`, `~/.codex/auth.json`, the folder a CLI signs in from), each resolved with `realpath`. One that resolves under a drive mount (the mountinfo rule in *The environment*) also gets its Windows path, built from that mount's `path=` option (`path=C:\` on the PC, measured) and the rest of the path: `/mnt/c/Users/<you>/.claude` is `C:\Users\<you>\.claude`. Without a `path=` option, it asks `wslpath -w`. A path that doesn't resolve (nothing there) is reported as it was expanded, and matches nothing.
- **The app compares, because only it knows its roots.** It takes its own from its resolved definitions, by the same expansion `TokenLogs` and the factory use: `DataSources.expandPath` over `ProviderDefinition.usageHistory(forDefaultAccount:)`'s records and the data sources' credential paths, with this PC's home and environment. The Windows-only code resolves those through symlinks and junctions (`GetFinalPathNameByHandleW`), then hands plain strings to the matching, which lives in `ClaudeBarShared` and is pure.
- **Matching:** both sides normalized first: case-insensitive, `\` and `/` the same, no trailing separator. A WSL source is shared when it's the same path as a Windows root, or one of the two is an ancestor of the other, compared by whole components (`C:\Users\<you>\.claude\.credentials.json` is under `C:\Users\<you>\.claude`; `C:\Users\<you>\.claude-work` isn't).
- **Dropped per source, never per provider:**
  - A shared log root drops only the days from that root in the WSL login's `logins`.
  - A shared credential drops that one source of the WSL login: the HUD doesn't show limits read with it.
  - The WSL login goes, from the HUD and from Settings' list of tools, only when every source it has, logs and credentials, is shared. A login with one shared source and one distinct source stays, with the distinct one.
  - Settings says *shared with Windows* beside each shared source.
- **The probe still reads with a shared credential,** since it doesn't know which are shared: Claude's API source may refresh `.credentials.json` on `/mnt/c` while the Windows side reads it. That's what the tool itself does when run from both sides; ClaudeBar writes the file as Claude Code does.

## Settings → Tools in WSL

- The distros `wsl.exe -l -q` lists (UTF-16LE, CRLF, no BOM; measured), without those that are never tool hosts: `docker-desktop*` and `rancher-desktop*`.
- For each: whether it's running, an on/off switch, and, from its last reading, the tools found and where (the CLI's path, or *logs only*), with *shared with Windows* beside a source the Windows side reads too.
- A distro is on by default once a reading finds a tool in it. Off, it's never read and its logins leave the HUD. Its kept days stay as they are (*The Leaderboard*).
- Kept in `app.json` (`wsl: {"Ubuntu-26.04": {"on": true}}`), with each distro's last reading, which the HUD shows while it isn't running.

## The Leaderboard

- **The uploader reads the running distros' logs only.** `claudebar-upload.exe` runs the probe with `--logs-only` in each running distro that's on: no refresh and no CLI every hour, only the log read (0.2 s warm for 30 days, measured). Its `TokenLogs` returns this PC's logins followed by each distro's `logins`, less the days from log roots shared with Windows (*Folders shared with Windows*). ClaudeBar's `DailyTokens.summed` already adds every login of a provider per day, so a provider's day is its Windows tokens plus the tokens only the distro has. A request is counted once: what both sides read is counted from the Windows side, and the rest are different files. It's one device, with one key and the server's cap per day, unchanged.
- **A day must never shrink.** An upload replaces a day it sends again. If a distro is stopped at the next hourly upload, a day sent with only the Windows tokens would replace one sent with both. So each distro's last `logins` are kept (`%LOCALAPPDATA%\ClaudeBar\wsl\<distro>.json`) and sent in its place while it isn't running. Only an answer replaces them, and an answer's `logins` are always whole (the deadline doesn't cut them, above); a failed or missing answer keeps them. Those days were still counted by ClaudeBar's package, in the distro (CONTRIBUTING rule 5).
- **A distro switched off, or removed** (`wsl --unregister`, or no longer in `wsl.exe -l -q`), is like a provider whose sharing is turned off on Windows today: `LeaderboardMembership.stopSharing` only stops the uploads, and *days already uploaded stay until you leave* (ClaudeBar's Leaderboard README). So its kept days are frozen, not deleted: they're still added to the days they cover, so a day already sent with them isn't sent again smaller, and no new days come from the distro. They drop out as their days leave the upload window, and the file goes with the last of them, or when the person leaves the Leaderboard, which deletes every day. Turned on again, its next answer replaces them. Deleting them instead would shrink days already on the board, which nothing else in the client does.
- **Days are the distro's.** The probe counts days in the distro's time zone, which WSL keeps equal to Windows' (`useWindowsTimezone`, true by default; measured `Asia/Seoul` beside Windows' Korea Standard Time). The probe says which zone it used; when it isn't Windows', Settings says so, and the days still count.
- Sharing stays per provider: sharing Claude shares its Windows and its WSL tokens.

## Keeping the probe and the app in step

- `ProbeReading` is one type, encoded by the probe and decoded by the app from the same source file. `HudReading`, `HudMonitor.Answer` and the problem and look types become `Codable` (they're `Encodable` today).
- The probe ships with the app and says its version. A probe of another version is a failure (*ClaudeBar's WSL reader is from another version*), never read in part.
- A test decodes a reading the probe encoded and checks it equals the original, and one decodes a checked-in sample (`tests/wsl-probe.json`), so a field renamed on one side fails CI.

## Providers in WSL

What each built-in provider does inside a distro, from its definition and ClaudeBar's Linux platform (no keychain, no browser cookies, no local-server reading, no AWS SDK yet), and, where the spike's reading on the PC says more, from that.

| Provider | In WSL | Basis |
|---|---|---|
| Claude | **Reads.** CLI on the pty, then the API from `~/.claude/.credentials.json`; logs from `~/.claude/projects` | Measured: the CLI ran, ClaudeBar answered Claude's folder-trust prompt itself, and the usage screen said API billing, not a plan (this distro's login is from June); the API's token refresh was refused (`invalid_grant`). The keychain step is Unavailable on Linux |
| Codex | **Reads.** App-server over pipes, the API from `~/.codex/auth.json`, `/status` on the pty; logs from `~/.codex/sessions` | Measured: the app-server answered with OpenAI's 401 for this distro's stale sign-in in one run, and didn't answer within 15 s in another |
| Oh My Pi | **Reads.** `omp usage --json`; logs from `~/.omp/agent/sessions` | Measured: found at `~/.bun/bin/omp`; its five accounts read |
| OpenCode Go | **Reads.** `opencode.db` with SQLite, in place | Measured: 5h, 7d and monthly limits |
| Gemini, Grok, Kimi, Kiro, Amp, Command Code, Cline, Mistral (logs) | Read when set up in the distro: files, a CLI on `PATH`, or both | Not set up on this PC's distro |
| Z.ai | Reads: a setting, `configPath`, or `ZAI_API_KEY` from the login shell | — |
| Copilot | The token from the environment or a setting; `gh`'s keychain item is Unavailable on Linux | — |
| Antigravity | Unavailable: reading a local server isn't on Linux yet. Not shown for WSL | Measured |
| Cursor, Windsurf, JetBrains | Not applicable: Windows apps, read on the Windows side | — |
| Bedrock | Unavailable: ClaudeBar builds its AWS clients for the Mac only | — |
| The API-key providers (OpenAI, OpenRouter, DeepSeek, …) | Read when their key is set in the distro. Usually it's set on Windows and read there | — |

Token logs: the probe found Claude, Codex, Mistral, omp and OpenCode logs (`providersWithLogs`). This distro's newest Claude and Codex logs are from June and its omp logs from August, so the last 30 days hold no tokens, and the probe sent none. With `--days 400` it sent Claude's 8 days (April 12 to June 2), OpenCode's 5 (April 13 to 17) and omp's 34 (June 2 to August 7), in 76 s.

## Errors

| What happens | What the person sees | Where |
|---|---|---|
| No WSL, or no distro | Nothing; Settings → Tools in WSL says *WSL isn't installed* or *No distros* | Settings |
| The distro is stopped | `notRunning` on its logins, with the last numbers dimmed | HUD, Limits |
| `wsl.exe` fails, or the probe can't start (no `libcurl.so.4`, a non-x64 distro, the drive not mounted) | `failed` on its logins: *ClaudeBar couldn't run in Ubuntu-26.04: <the error's first line>* | HUD, Limits, Settings |
| The probe answers late | Its answer at the deadline; logins still reading say `failed`, *Took too long in WSL* | HUD, Limits |
| No answer 90 s after the deadline | The probe's Linux processes are killed in the distro, then `wsl.exe`; `failed` as above, and the kept days stay | HUD, Limits |
| The JSON doesn't parse, or another version answered | `failed`, *ClaudeBar's WSL reader is from another version* | HUD, Limits |
| The probe started without its marker | It exits 3 at once with nothing read; `failed`, *ClaudeBar couldn't run in Ubuntu-26.04: started without CLAUDEBAR_WSL_RUN* | HUD, Limits, Settings |
| The upload can't read a distro | It sends that distro's last kept days; the log says why | ClaudeBar.log |
| A distro is switched off or removed | Its logins leave the HUD; its kept days stay frozen until they age out or the person leaves | HUD, Settings |
| A WSL source is the Windows side's own folder (shared) | Not an error: that source's days or limits are left out, the rest of the login stays, and Settings says *shared with Windows* beside it | Settings |
| A source's Windows path can't be built (no `path=` and `wslpath -w` fails) | It's treated as not shared, and the log says which; it can count twice only in that case | ClaudeBar.log |
| An update starts while a probe runs | Velopack can't rename `current` and stops with *Unable to start the update, because one or more running processes prevented it*; the old version stays in place, and *Update* can be tried again | Velopack's update log |

## Tests

- **Shared:** `ProbeReading` round trip; decoding the checked-in sample; the merge of a distro's answer into the lineup (ids, names, `notSetUp` and platform failures dropped, `notRunning` with the kept numbers).
- **Shared, folders shared with Windows, pure** (`ClaudeBarShared`, plain strings in, no file system), each a pair of a WSL answer's `sources` and the Windows side's roots:
  - a WSL `~/.claude` symlinked to the same Windows folder the Windows side reads (`C:\Users\<you>\.claude`): its logs and its credential are dropped, and the WSL Claude login goes;
  - a WSL `~/.claude` on a drive mount at a different folder (`/mnt/d/wsl-data/.claude`, `D:\wsl-data\.claude`, against Windows' `C:\Users\<you>\.claude`): kept;
  - `CODEX_HOME` shared, with Claude distinct in the same distro: only Codex's shared sources are dropped, and Claude's login and days stay whole;
  - a login with a shared credential and a distinct log root: its `logins` kept, the credential source dropped, the login still listed;
  - matching: case differences (`c:\users\…` against `C:\Users\…`), mixed separators (`C:/Users\<you>/.claude`), a trailing separator, an ancestor either way (`…\.claude\.credentials.json` against `…\.claude`), and a sibling with a common prefix (`…\.claude-work` against `…\.claude`), which isn't shared.
- **Windows:** `wsl -l -q` parsing (UTF-16LE without BOM, CRLF, empty output with exit 0 when none run), the excluded distros, the `TokenLogs` that adds the distros' logins less the shared ones, the kept days while a distro is stopped, and the frozen days after it's switched off or removed. The Windows roots come from the definitions' own expansion, checked against a temp home (`expandPath` with that home), and a junction in it resolves to its target.
- **The probe, in CI on Linux:** it builds, runs on the runner, and its `--json` decodes as `ProbeReading`. Started without `CLAUDEBAR_WSL_RUN`, it exits 3 and prints the error. With a fixture CLI that never answers: the answer comes at the deadline with `timedOut: true` and whole `logins`, and once the probe has exited no process it started is left (`pgrep` finds none). `--logs-only` answers with `hud: null` and the same whole `logins` as `--json`, and starts no CLI (the fixture CLI on `PATH` writes a file when it runs; there is none afterwards). Its `sources` give each root's `realpath`, and, over a fixture mountinfo with a drive at `/win/c` (`path=C:\`), the Windows path `C:\…` for a root under it and none for a root elsewhere.
- **`--end <id>`, in CI on Linux:** the probe started as `env CLAUDEBAR_WSL_RUN=<id> <probe>`, with a fixture CLI that starts a grandchild in a new session (`setsid`) and then exits, so the grandchild is reparented to `init`. The test records the probe's PID and the grandchild's, stops the probe (`SIGSTOP`, so it can't tidy up itself), and runs `--end <id>` without the marker. Then: `kill -0` fails for the probe's PID and for the grandchild's (`/proc/<pid>` is gone), no process carrying the id is left, and `--end` itself exited 0. Checking only "no marked process remains" would pass with a probe that had lost its marker, so the PIDs are checked by number. The test `wait`s for the probe, its own child, before checking it, and runs where PID 1 reaps orphans (the runner, or a container with `--init`): a killed process nobody has reaped is a zombie, which `kill -0` still finds.
- **The probe's drive mounts, pure, over mountinfo text** (the lines above as fixtures): the default `/mnt/` root; a custom `/win/` root; root `/` (`/c`); a plain directory kept (`/mnt/cache`, `/mnt/wslg`, `/mnt/wsl`, the `9p` `aname=drivers` line); a `PATH` entry with a trailing slash; both a `drvfs` line and a `9p aname=drvfs` line; and no drive mounts, where every entry is kept. Plus one `PATH` case: a custom root with an npm shim fixture (`/win/c/…/npm/codex`) before a Linux `codex`, where the probe doesn't find the Windows one and does find the Linux one.
- **ClaudeBar (the `commonPaths` fix):** `LinuxBinaryLocator` finds a tool in each version manager's folder, with the folders given to the locator (it already takes `toolFolders`), not by writing in a real home.
- **On a PC:** with a distro running, the HUD shows its tools as `· WSL`, *Refresh* reads them again, a stopped distro shows `notRunning` without being started, and an upload's preview adds its days. With no screen step while the PC is in use.

## Upstream

- The probe is this repo's: its shape is this app's C interface. If ClaudeBar gets a Linux client, the reading it makes (a monitor over every provider, as JSON) could become a product in ClaudeBar's package, which both clients use. That's a question for hanrw, below; until then nothing here moves.

## Open questions for hanrw

1. **musl.** ClaudeBar's process code checks `canImport(Glibc)`, and its SwiftTerm pin (exactly 1.12.0) predates SwiftTerm's musl fix (1.16.0). Would you take a change that adds `Musl` beside `Glibc`, moves SwiftTerm to ≥ 1.16.0, and adds a Static Linux SDK build to the Linux CI? The spike's patched build still hangs in a refresh, so it needs that investigation first.
2. **Version managers in `commonPaths`.** The fix above, in `LinuxProcesses.swift` with a locator test. It's a bug fix for any Linux, so it could come first, as its own issue.
3. **A Linux product.** Should `claudebar-probe`, or a `claudebar --json` like it, live in ClaudeBar's package for a future Linux client?
4. **Writing in the distro.** ClaudeBar's file log and its CLI folder land in the distro's `~/.local/share/ClaudeBar`. Fine as ClaudeBar on Linux, or should a probe log to stderr only?
