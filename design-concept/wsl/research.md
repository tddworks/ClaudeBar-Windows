# Tools in WSL: what WSL does, measured and sourced (2026-11-03)

The facts the WSL design ([`docs/plans/2026-11-03-wsl-design.md`](../../docs/plans/2026-11-03-wsl-design.md)) stands on. Each one was measured on a Windows PC, on GitHub's `ubuntu-latest` runner with the spike on branch [`spike/wsl-probe`](https://github.com/tddworks/ClaudeBar-Windows/tree/spike/wsl-probe) (`linux/`, `.github/workflows/wsl-probe.yml`, `.github/workflows/environ-check.yml`), or read from source, with the place. Anything not measured says so.

## The PC

Windows 10.0.26200, WSL 3.0.3.0, kernel 6.18.54.1-1, WSLg 1.0.79. No `.wslconfig`. Two distros: `Ubuntu-26.04` (the default, WSL 2, `DefaultUid` 1000 in the `Lxss` registry key, `systemd=true`, no `[automount]` in `wsl.conf`) with Claude Code 2.1.160, Codex 0.136.0, omp and OpenCode, and `docker-desktop`. Both were *Stopped* at the start and are again now. `~` below is `/home/<user>`.

## Starting and stopping a distro

- `wsl.exe -l --running -q` and `wsl.exe -l -v` start nothing: both distros stayed *Stopped* after each. With none running, `-l --running -q` prints nothing and exits 0.
- `wsl.exe -l -q` writes UTF-16LE with CRLF and no BOM (`55 00 62 00 75 00 …`).
- Listing `\\wsl.localhost\` or `\\wsl$\` with no distro running: *path not found*, and nothing starts. `Test-Path \\wsl.localhost\Ubuntu-26.04\etc\passwd` started the distro, in 4.9 s.
- Without starting a distro, Windows has only its default uid (`DefaultUid` in `HKCU\…\Lxss\{guid}`), not its home. `WslGetDistributionConfiguration` returned `0x80070542` from the test's process.
- Launching the probe into a stopped distro took 27 s and 36 s. Both runs wrote `wsl: Failed to start the systemd user session for '<user>'. See journalctl for more details.` to stderr; stdout was clean.
- **Idle:** with no `.wslconfig`, the distro stopped 10–15 s after the last read (polled every 5 s), and the VM's `vmmemWSL` 65 s after that. Microsoft's defaults are `instanceIdleTimeout` 15,000 ms and `vmIdleTimeout` 60,000 ms ([wsl-config.md](https://github.com/MicrosoftDocs/WSL/blob/main/WSL/wsl-config.md)).
- Another app can keep a distro up: Orca runs `wsl.exe -d Ubuntu-26.04 --exec /usr/bin/node …/opencode-sqlite-reader.cjs` on this PC while the distro runs.

## Building the probe

`ubuntu-latest`, the `swift:6.3.3-noble` image (Swift 6.3.3, the Windows build's version), a clean release build of `claudebar-probe`:

| | glibc, x86_64 | Static Linux SDK (musl), x86_64 | musl, aarch64 |
|---|---|---|---|
| Build | 355 s | 356 s | 509 s |
| Binary, raw | 116.9 MB | 211.5 MB | 209.9 MB |
| Binary, stripped | 71.0 MB | 73.6 MB | not stripped (the runner's `strip` is x86-64 only) |
| Resource bundles | 1 (`ClaudeBarKit_Providers.resources`), 0.22 MB | the same | the same |
| The folder, zipped | 27.5 MB | 29.5 MB | 73.6 MB |
| Needs in the distro | `libcurl.so.4`, `libstdc++.so.6`, `libgcc_s.so.1`, glibc | nothing | nothing |
| On the PC | answers | **hangs** | not run (the PC is x64) |

- Without its resource bundle beside it, the probe stops at once: `Fatal error: could not load resource bundle`. `Bundle.module` looks beside the executable.
- musl needed two packages patched in the build's checkouts:
  - SwiftTerm 1.12.0, which ClaudeBar pins exactly, imports `Glibc` on any Linux. SwiftTerm fixed it in 1.16.0 ([#612](https://github.com/migueldeicaza/SwiftTerm/pull/612), merged 2026-07-26).
  - ClaudeBar's `PtySession`, `ProcessEnd` and `ChildTeardown` check `canImport(Glibc)`, so under musl the pty and a child's teardown compile to nothing; `LinuxPty` imports `Glibc` and calls `Glibc.open`; `ProcessEnd` reads glibc's `siginfo_t` fields (`_sifields._sigchld`).
- Patched, the musl build runs, but a refresh never finished on the PC: at a 60 s deadline, 9 logins the glibc build had answered were still `reading`, and a run with no deadline held a pty with no child for 15 minutes. The cause isn't found; a child's end not noticed under musl is the first suspect.

## Running the probe

| Run, on the PC unless named | `wsl.exe` to answer | Refresh | Logs, 30 days |
|---|---|---|---|
| First run after the distro started | 57.0 s | 30.4 s | 22.3 s (2,686 records) |
| Warm, from drvfs (`/mnt/h/…`) | 25.0 s | 23.8 s | 0.18 s |
| Warm, from drvfs, again | 25.0 s | 24.6 s | 0.18 s |
| Warm, from a copy in `/tmp` (ext4) | 29.0 s | 25.4 s | 0.16 s |
| Warm, from drvfs, 400 days | 102.1 s | 25.4 s | 75.8 s |
| The runner, nothing set up (musl) | — | 0.08 s | 0.02 s |

- An ELF on drvfs runs: the mount shows every file as `-rwxrwxrwx`.
- What the providers read, in this distro:
  - **Claude:** the CLI ran on the pty; ClaudeBar answered Claude Code's folder-trust prompt itself; the usage screen said API billing, not a plan (the distro's login is from June). Claude's CLI is the slowest source, about 20 s. The API's token refresh was refused (`invalid_grant`).
  - **Codex:** the app-server answered OpenAI's 401 (`invalid_jwt`) for the stale sign-in in one run, and didn't answer within 15 s in another.
  - **omp:** found at `~/.bun/bin/omp`; its five accounts read. **OpenCode Go:** `opencode.db` read in place, 5h, 7d and monthly limits.
  - **Antigravity:** *Reading a local server isn't available on Linux yet.*
- Logs: Claude, Codex, Mistral, omp and OpenCode (`providersWithLogs`). The newest Claude and Codex logs are from June and omp's from August, so 30 days held no tokens. Over 400 days: Claude 8 days (April 12 to June 2), OpenCode 5 (April 13 to 17), omp 34 (June 2 to August 7).
- The distro's zone was `Asia/Seoul`, beside Windows' *Korea Standard Time* (`useWindowsTimezone` is on by default).
- What it wrote: `~/.local/share/ClaudeBar/Logs/ClaudeBar.log` and the CLI folder `~/.local/share/ClaudeBar/Probe`, both removed afterwards, and a trust entry for that folder in `~/.claude.json`, which is still there.

## PATH and where CLIs are found

`--where` prints the probe's `HOME`, `SHELL`, `PATH` and where ClaudeBar's own locator finds each tool:

| Launched with | `PATH` before the WSL defaults | Windows' `PATH` appended | Found |
|---|---|---|---|
| `wsl.exe -d D -- probe` | nothing | yes, 80 entries | claude, codex `~/.local/bin`; omp, opencode `~/.bun/bin`; node `/usr/bin` |
| `wsl.exe -d D -e probe` | nothing | yes | the same |
| `wsl.exe -d D --shell-type login -- probe` | `~/.cargo/bin:~/.local/bin` | yes | the same |
| `wsl.exe -d D -e bash -lc probe` | `~/.cargo/bin:~/.local/bin` | yes | the same |
| `wsl.exe -d D -e bash -ic probe` | `~/.jdks/…/bin:~/.cargo/bin:~/.local/bin` (×3)`:~/.bun/bin` | yes | the same |
| `wsl.exe -d D -e bash -lic probe` (ClaudeBar's login-shell lookup) | as `-ic`, plus `~/.local/bin` again | yes | the same |

- Every tool was found in every mode: each is in a folder on ClaudeBar's own list (`LinuxProcesses.commonPaths`). None printed anything stray.
- Ubuntu's `.bashrc` returns when the shell isn't interactive (`case $- in *i*) ;; *) return;;`, lines 6–8), before the lines tools add (bun's at 119–121). A login shell reads `.profile`, which reads `.bashrc`, which returns.
- Windows' entries include `/mnt/c/Users/<you>/AppData/Roaming/npm`, `/mnt/c/Users/<you>/.bun/bin` and `/mnt/c/Program Files/nodejs/`. The only file there named like a tool was `/mnt/c/Users/<you>/.bun/bin/omp.exe`, which ClaudeBar's exact-name lookup doesn't match. A Windows npm install writes an extensionless shim beside `codex.cmd`, which it would match.
- **Version managers:** as root (home `/root`), a tiny script at each manager's usual place, removed afterwards. None was found:

  | Manager | Fixture | Found, no shell | Found, `bash -lc` |
  |---|---|---|---|
  | nvm | `~/.nvm/versions/node/v22.0.0/bin/codex` | no | no |
  | Volta | `~/.volta/bin/claude` | no | no |
  | fnm | `~/.local/share/fnm/aliases/default/bin/gemini` | no | no |
  | mise | `~/.local/share/mise/shims/opencode` | no | no |
  | asdf | `~/.asdf/shims/kimi` | no | no |

  `commonPaths` lists `~/.nvm/versions`, a folder per version rather than programs. It follows the account's home in `/etc/passwd`, not `$HOME` (on the runner: `home` `/root`, `$HOME` `/github/home`).

## Drive mounts

`/proc/self/mountinfo` in `Ubuntu-26.04`, the lines under `/mnt` and the `9p` ones:

```
84 88 0:34 / /mnt/wsl rw,relatime shared:1 - tmpfs none rw
85 88 0:36 / /usr/lib/wsl/drivers ro,nosuid,nodev,noatime - 9p drivers ro,aname=drivers;fmask=222;dmask=222,cache=0x5,access=client,msize=65536,trans=fd,rfd=8,wfd=8
89 88 0:40 / /mnt/wslg rw,relatime shared:2 - tmpfs none rw
90 89 8:48 / /mnt/wslg/distro ro,relatime shared:3 - ext4 /dev/sdd rw,discard,errors=remount-ro,data=ordered
135 89 0:42 /etc/versions.txt /mnt/wslg/versions.txt rw,relatime shared:24 - overlay none rw,lowerdir=/systemvhd,upperdir=/system/rw/upper,workdir=/system/rw/work,uuid=on
137 89 0:42 /usr/share/doc /mnt/wslg/doc rw,relatime shared:25 - overlay none rw,lowerdir=/systemvhd,upperdir=/system/rw/upper,workdir=/system/rw/work,uuid=on
140 88 0:72 / /mnt/c rw,noatime - 9p C:\134 rw,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/,cache=0x5,access=client,msize=65536,trans=fd,rfd=6,wfd=6
141 88 0:73 / /mnt/d rw,noatime - 9p D:\134 rw,aname=drvfs;path=D:\;uid=1000;gid=1000;symlinkroot=/mnt/,…
142 88 0:74 / /mnt/e rw,noatime - 9p E:\134 rw,aname=drvfs;path=E:\;…
143 88 0:75 / /mnt/h rw,noatime - 9p H:\134 rw,aname=drvfs;path=H:\;…
```

- The drives are `9p` with `aname=drvfs`, which sits in a `;`-separated group inside the comma-separated options, with `path=` beside it. No line had the filesystem type `drvfs`.
- `/usr/lib/wsl/drivers` is `9p` too, with `aname=drivers`. `/mnt/wsl` and `/mnt/wslg` aren't drives.
- `wslpath -u 'C:\'` gave `/mnt/c/`.

## Ending a probe's processes

- Killing `wsl.exe` on Windows left the hung probe and its pty running in the distro, and the distro up. `pkill` inside the distro ended them: 8 probe processes over the spike's runs.
- `/proc/<pid>/environ` is the environment at `execve` ([proc_pid_environ(5)](https://man7.org/linux/man-pages/man5/proc_pid_environ.5.html)). On the runner (run 41664666790):

```
started plainly, setenv after start:
  getenv:  late
  environ: (absent)
started with env CLAUDEBAR_WSL_RUN=x, then setenv:
  getenv:  late
  environ: CLAUDEBAR_WSL_RUN=x
  probe stand-in 2243: CLAUDEBAR_WSL_RUN=x
  grandchild 2246 (ppid 1, sid 2244): CLAUDEBAR_WSL_RUN=x
a shell that exports the marker itself:
  /proc/$$/environ: 0 lines
```

- Every Linux child ClaudeBar starts (pipes, the pty, scripts) gets `LinuxProcesses.environment(for:_:)`, which starts from `appEnvironment`, `ProcessInfo.processInfo.environment`, and changes only `PATH` and the definition's own names (`ChildEnvironment.exactNames`).

## Replacing the app's folder while a probe runs

A copy of `/bin/sleep` in `H:\cbw-upd\current\linux\x64\`, run as `wsl.exe -d Ubuntu-26.04 -e /mnt/h/cbw-upd/current/linux/x64/sleep 60`. While it ran:

- `Rename-Item` of `current` failed: *access denied*. The folder was unchanged.
- `Remove-Item -Recurse` of the same folder succeeded, and `sleep` kept running.
- Deleting the running file alone, and putting another file at its name, both succeeded, and it kept running.

Velopack 1.2.161 (`src/bins/src/commands/apply_windows_impl.rs` at tag `1.2.161`) stops the package's own processes (`force_stop_package`), then renames `current` to a backup, retrying 10 times a second apart, and otherwise stops with *Unable to start the update, because one or more running processes prevented it. Try again later, or if the issue persists, restart your computer.*, before anything has changed.

## The phase 1 build on the PC (2026-11-04)

`int/wsl` built on the PC with `.\build.ps1 -Probe` and CI's probe, then `scripts/check-wsl.ps1 -Start Ubuntu-26.04` and the runs below, each from a stopped distro that was stopped again after.

- **The controlling terminal.** `wsl.exe` gives every Linux process a controlling terminal, even one started as the app starts it: no console (`CREATE_NO_WINDOW`), stdin a closed pipe, stdout and stderr pipes. There `/dev/tty` opened. `bash -l -i -c true` in a process group of its own was still running at 6 s and had to be killed, from the app's kind of launch and from a console alike; in a session of its own it exited in 0.11 s. An interactive bash opens `/dev/tty` for job control and, in a background group of it, stops itself with `SIGTTIN`. So the probe's environment import timed out at 3 s on every run; it now runs the shell with `POSIX_SPAWN_SETSID`, and imports (`imported`, no names: this distro's shell files export none the definitions name).
- **The import's cost** (Task 19's check 8, five runs each): inside the distro 103–149 ms warm, and 1.5–1.9 s for the first login shell after the distro starts (3.8 s once, 3 s after it started); `wsl.exe -e <the import>` 0.19–0.28 s against `wsl.exe -e true` 0.11–0.17 s. So the first run after a start can still time out at 3 s: both first runs of the fixed probe did, and every later run imported.
- **The probe, as the app runs it** (`--json --deadline 60`): 74–94 s on the first run after a start, then 71 s, then 23–35 s. The first runs' Claude CLI didn't finish in its timeout, and Codex's app-server and omp's `usage` answered *Request timed out*; warm, Claude says the account has API billing, not a plan, and Codex gets `401 invalid_jwt`, as in June. OpenCode Go and omp's five accounts read. Antigravity: *Reading a local server isn't available on Linux yet*. No days: the newest records are from June 2 (Claude, Codex) and August 7 (omp). Nothing skipped: the WSL roots are the distro's own. The answer decodes with `ProbeReading` and re-encodes equal.
- **After each run** no process carried its marker; `ClaudeBar.exe --wsl-end-all` ended a stand-in marked `sleep 300` in 1.2–2.2 s; the probe ran from a folder with a space in its name (`…\Temp\claudebar check wsl\x64`).

## v0.1.10 installed on the PC (2026-11-05)

`Ubuntu-26.04` started at 02:59:57 and left running, with its switch on, so the app probed it at the HUD's ten-minute cadence. WSL 3.0.3.0, no `.wslconfig`.

- **Every tick started the CLIs cold.** The ticks at 03:08, 03:18 and 03:28 all answered *Command did not complete within the timeout* for Claude (its CLI's 20 s) and *Request timed out* for Codex (its app-server's 15 s). *Try again* at 03:20, 80 s after a run, answered as the warm runs above: API billing, and `401 invalid_jwt`.
- **WSL takes the page cache back within a minute or two.** `Cached` in `/proc/meminfo` fell from 500 MB to 230 MB in the minute after a run, and stayed low until the next tick. With the cache dropped (`echo 3 > /proc/sys/vm/drop_caches`), `claude --version` took 4.5 s and `codex --version` 3.7 s; again right after, 0.01 s each. Claude's binary is 317 MB (`~/.local/share/claude/versions/2.1.317`), Codex's 217 MB.
- **Read through, they answer.** `cat`-ing the two binaries to `/dev/null` took 4.7 s and 2.5 s; the 03:38 tick, started with them read, answered API billing and `401`. So the probe now reads each located CLI through, in parallel and for 10 s at most, before the refresh (`Readahead`).

## Not measured

- A distro without `libcurl.so.4`, a custom `[automount] root` on a real distro, and an arm64 PC.
- Why the musl build's refresh hangs.
- A probe reading a Claude or Codex login that's signed in now: this distro's are from June and August.
