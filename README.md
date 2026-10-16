# agent-pod

`agent-pod` runs an autonomous coding agent (Claude Code) in a rootless Podman container. From the host, the container gets one project directory and its own per-project state volume, and nothing else. It ships with a check script that tests those limits on your machine, instead of asking you to take them on trust.

> **Status:** early. `verify` passes with the default profile, with `--containers` and with `--browser` (Chrome renders with its own sandbox enabled), on one Linux machine with rootless Podman 5 and pasta. `--containers` and `--browser` together are untested. Run [Verify](#verify) on yours.

## Why

Using Podman on its own is not enough to jail a strong agent like Claude. Without hardening, an agent could use several techniques to get out of containment. The most obvious is the Podman socket, which gives full access to any part of the host's filesystem. My first setup also shared the host's network, which gave the agent access to every service on the local machine and the LAN. In theory it could also read keystrokes and capture the screen through the display sockets. Another weakness was that the Claude Code session ran inside the pod with the credentials of several agents mounted read-write, so several keyrings were visible.

Run inside that first setup, the check script fails 10 checks: [docs/before-verify.txt](docs/before-verify.txt). Two things that surprised me. Host networking also exposes the host's `/sys` (efivars, debugfs, bpf). And GNU `find` doesn't see a bind-mounted socket (see the note under the table). This repo is the hardened replacement.

## Threat model

To mitigate these issues, `agent-pod`:
- stops all access to Podman sockets
- creates its own network instead of passing the host's
- doesn't expose any display sockets
- gives the pod no host credentials at all; Claude logs in once per project, and that state lives in the project's own volume
- passes only the secrets a project absolutely needs, in a safe way (today: `ANTHROPIC_API_KEY` if set, your Claude login token only with `--login`, and any variable you name with `--secret`)

The agent is treated as **untrusted code with your API key**. It may be steered by prompt injection from the repo it works on, or it may simply make mistakes.

**The agent can reach:**
- the mounted project, read-write, at `/workspace`
- its own home volume, `agent-pod-home-<project>`, which holds its login, history and caches for this one project
- your Claude Code rules, skills, agents, commands, plugins and `settings.json`, **read-only** (skip with `--clean`)
- this project's Claude memory (`~/.claude/projects/<project>/memory`), read-write, shared with the host
- the internet and your LAN (egress is not filtered; see below)
- your SSH agent, but only with `--ssh`

**The agent cannot reach, enforced by the container:**

| Property | How it's enforced | How `verify` checks it |
|---|---|---|
| Host filesystem outside the project | the project and the home volume are the only host mounts; dot-dirs in `$HOME` and its ancestors are refused | every mount in `/proc/self/mountinfo` must be on an exact allowlist |
| Host Podman/Docker socket, other host sockets | never mounted | stats every candidate file (see note below) |
| Host services on loopback (IPv4 and IPv6) | own network namespace (pasta, `--no-map-gw`) | connects to real listeners on host `127.0.0.1`/`::1` via every route back |
| Your display, keyboard or screen | no X11/Wayland sockets or variables | socket and env checks |
| Other projects' agent state | one home volume per project | by design, not checked |
| Rewriting your shared Claude config (rules, skills, plugins, hooks) | mounted read-only; changes only through `agent-pod config` | every mount under `~/.claude` except this project's memory must be `ro` |
| Root or capabilities | `--userns=keep-id`, `--cap-drop=ALL`, `no-new-privileges` | uid, bounding/ambient capability sets, `NoNewPrivs` |
| Fork bombs, memory or CPU exhaustion | pids, memory and CPU limits | cgroup `pids.max`, `memory.max`, `cpu.max` |
| Modifying the image or its own binary | read-only root, auto-updater disabled | `/` mounted `ro` |
| Your git credentials | only `user.name`/`user.email` are passed, as env vars; `~/.gitconfig` is not mounted | by design, not checked |

Note: GNU `find -type s` misses bind-mounted sockets, because the directory entry keeps the type of the mount point, an empty regular file. The first draft of `verify` passed the old setup's `/run/docker.sock` this way. The check now stats every empty file as well.

**Held only by convention:**
- **Monitoring changed files.** I don't go over every code change, but at every commit I check which files have changed and whether that fits the task being worked on. When something is out of the ordinary, or touches core files like authentication, I check the code myself.
- **No access to production, given willingly.** I don't give the agent access to production servers, remote repos or production deployments. A staging environment is preferably on a separate server; if that isn't possible, it should be jailed. Otherwise I do that work manually.
- **No shared SSH key.** The pod never uses the same SSH key as I do.
- **Money needs triple checks.** Any code that handles funds is triple-checked and read in full.

## What this does not protect against

- **Creating malicious code.** If for whatever reason the agent writes bad or malicious code, nothing inside the pod checks what it writes. Once that code runs in production, it can cause damage.
- **Prompt injection from repo contents.** The agent reads the project. A malicious README, issue or dependency can steer it within everything listed under "can reach".
- **Exfiltration over the network.** Egress is open. Anything in `/workspace` or the agent's context can be sent anywhere. An egress allowlist (proxy or nftables) is the next step.
- **Your LAN.** The pod can't reach host loopback, but it can reach other machines and the host's LAN address.
- **Misuse of the credentials you hand it.** The API key, the forwarded SSH agent, and any secrets inside the project.
- **Persistence inside the project.** The agent can write files that run later *on the host*, when you use the project outside the pod: `.git/hooks`, `.git/config` (`core.fsmonitor`, `core.sshCommand`, aliases), `.envrc`, `.claude/settings.json` hooks, CI config and package scripts. Review diffs, and check these paths in particular.
- **Kernel or Podman escapes.** This is a container, not a VM; it shares the host kernel. Because of `keep-id`, a breakout lands as your real host user.

## How it works

```
 host (rootless Podman, your user)
 ├── ~/projects/foo ──────────── bind mount (rw) ───┐
 │                                                  ▼
 │   ┌──────────────── agent-pod-foo-1a2b3c4d ─────────────────┐
 │   │ uid 1000 (= your uid), no capabilities, no_new_privs    │
 │   │ read-only image          /workspace  ← project          │
 │   │ tmpfs /tmp /run          /home/agent ← volume (per proj)│
 │   │ own netns (pasta) ──────► internet / LAN   ✗ host lo    │
 │   └─────────────────────────────────────────────────────────┘
 │
 ✗ not mounted: podman socket, X11/Wayland, ~/.claude, ~/.ssh, other projects
```

## Usage

Requirements:
- Linux with rootless Podman 5+ and pasta (`passt`)
- cgroup v2, with CPU and memory controllers delegated to your user (`cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers` should list `cpu memory pids`)
- `python3` on the host, for `verify`'s test listeners
- for `--containers` only: a subuid range of at least 65,536 (`grep "^$USER:" /etc/subuid`)

```bash
./bin/agent-pod build                 # build localhost/agent-pod:latest and :browser
./bin/agent-pod verify ~/projects/foo # check isolation with the exact run settings
./bin/agent-pod run ~/projects/foo    # interactive shell; run `claude` inside
./bin/agent-pod run ~/projects/foo -- claude   # start the agent directly
./bin/agent-pod shell ~/projects/foo        # another terminal in the same running pod
./bin/agent-pod stop ~/projects/foo
./bin/agent-pod reset ~/projects/foo  # wipe this project's agent state (re-login)
./bin/agent-pod destroy               # remove all containers, volumes and the image
```

Log in once per project inside the pod, or export `ANTHROPIC_API_KEY` on the host and it is passed through. The login is kept in that project's volume, so it survives restarts until you run `reset`. Your host login is never shared, because `~/.claude/.credentials.json` and `~/.claude.json` hold your account tokens and the history of every project. On a project's first start, the pod writes a minimal `~/.claude.json` (onboarding done, nothing else), so you go straight to login instead of the first-run setup.

**Your Claude Code setup comes with you.** The pod mounts your rules, skills, agents, commands, plugins and `settings.json` from `~/.claude`, read-only. A prompt-injected agent can use them but cannot plant instructions or hooks in them that would run in every later session. Your memory for *this* project is mounted read-write, at the same host path Claude Code uses, so memories carry over between the host and the pod. The agent can already write to this project, so that adds no new reach. Login, history and caches stay in the project's own volume.

To install or update plugins and skills, run `./bin/agent-pod config`. It's a separate maintenance pod with `~/.claude` mounted read-write and no project mounted, so nothing untrusted is read while your config is writable.

### Options

- `--browser` uses the `:browser` image: base plus Google Chrome (from Google's signed repo) and Noto fonts, including Thai, with a 1 GB `/dev/shm`. Chrome runs headless; there's still no display. Its log fills with D-Bus errors, because the pod has no system bus on purpose; they're harmless. `verify --browser` checks that Chrome renders a page with its own sandbox enabled, rather than `--no-sandbox`.
  - The pod also gets `CAP_SYS_CHROOT`. Chrome's sandbox chroots itself to drop filesystem access, and Podman's default seccomp profile allows `chroot(2)` only with that capability. Without it, Chrome's zygote crashes ("Zygote process exited prematurely"). The capability applies only inside the pod's user namespace. The classic chroot escalation needs a setuid binary, and `no-new-privileges` blocks that. The image also drops the setuid bit from Chrome's unused `chrome-sandbox` helper.
  - With `--containers` too, `no-new-privileges` is off, so that protection is gone. The agent already has `CAP_SETUID` in that mode anyway.
- `--login` passes a Claude login token instead of a separate login per project. Create it once with `claude setup-token` and save it, readable only by you:
  ```bash
  mkdir -p ~/.config/agent-pod && (umask 077; cat > ~/.config/agent-pod/claude-token)   # paste, then Ctrl-D
  ```
  The pod gets the token in its environment, so the agent can read it, but a login made inside the pod gives it the same access anyway. The difference is reach: one token now serves every project you start with `--login`, so a leak from one pod affects all of them. Revoke it at claude.ai if needed. Your host's own login (`~/.claude/.credentials.json`) is still never mounted.
- `--secret NAME` passes the host environment variable `NAME` into the pod, for a project that needs one credential (a staging API key, say). Repeat it for several: `--secret STAGING_API_KEY --secret SENTRY_TOKEN`. The variable must be set and exported on the host. Podman reads the value from its environment, so it stays out of `ps`. The agent can read what you pass, so use a key scoped to this one project. Names the pod sets itself (`PATH`, `HOME`, `GIT_*`, `ANTHROPIC_API_KEY` and so on) are refused.
- `agent-pod shell <dir>` opens another bash terminal in the pod that `run` started, for example to watch the agent's work or run a command while it works. It joins the same container, so the user, mounts, limits and environment are identical, and it grants no extra access. Add `-- cmd` to run one command instead of a shell. It needs a running pod, so `run` first.
- `agent-pod secret <dir> NAME` hands a secret to a pod that is already running, for when you need one halfway through a session. The value comes from the host variable `NAME` if it's exported, otherwise from stdin or a silent prompt. It lands as a file at `/tmp/.agent-secrets/NAME` (mode 600, directory 700) on the pod's tmpfs, so it disappears when the pod stops. A running process can't gain environment variables, so tell the agent to read it: `export NAME=$(cat /tmp/.agent-secrets/NAME)`. The same trade-off as `--secret` applies: the agent can read it.
- `--clean` mounts none of your `~/.claude` config or memory. Use it for a project you trust less than usual.
- `--ssh` forwards your SSH agent. The pod can *use* every loaded key while it runs, though it can't read them. Load only the key you need (`ssh-add -t 1h ~/.ssh/deploy_key`).
- `--containers` lets the agent run its own rootless Podman inside the pod, for projects that need containers. Nested images live in the project's home volume, and the host socket is still never mounted. **The profile gets weaker:**
- The pod gains `CAP_SETUID`/`CAP_SETGID` inside its user namespace, so the agent can switch to any mapped uid, including 0 in the pod. Podman also puts them in the ambient set, so every process in the pod inherits them.
- It gets `/dev/fuse`.
- It loses `no-new-privileges`, because `newuidmap` needs file capabilities.
- SELinux labelling is disabled (`label=disable`).
- Files that nested containers write into `/workspace` may end up owned by a subuid on the host.

The host needs a subuid range of at least 65,536. `verify --containers` reports the weaker profile, but it does not yet test that nested Podman actually works. *Experimental.*

## Verify

`agent-pod verify [--containers] <dir>` builds its pod arguments with the same function `run` uses. The only differences are no TTY, a different container name and two extra environment variables. Before starting the pod, it opens accept-and-close listeners (no HTTP, nothing served) on host `127.0.0.1` and `::1`. It then runs [`agent-pod-verify`](bin/agent-pod-verify) inside the pod. The checks are written to fail when in doubt, and the exit code is the number of failures.

Output on the author's machine (default mode; gateway addresses replaced):

```
PASS  not running as root (uid 1000)
PASS  capability bounding set as expected (CapBnd=0000000000000000)
PASS  ambient capabilities as expected (CapAmb=0000000000000000)
PASS  no_new_privs is set
PASS  only allowlisted mounts present
PASS  root filesystem mounted read-only
PASS  no unexpected unix sockets (container runtime, display, etc.)
PASS  no X11/Wayland access
PASS  limit pids.max: 1024
PASS  limit memory.max: 8589934592
PASS  limit cpu.max: 400000
WARN  something other than the host listener answered at: <gw4>:57197 (e.g. a router accepting every port)
PASS  host loopback listeners unreachable (tried <gw4>:57197 169.254.1.2:57197 [<gw6>]:59593 [fe80::1]:59593)
PASS  claude runs (2.1.301 (Claude Code))
PASS  can reach api.anthropic.com:443
WARN  egress is not filtered: the pod can reach the internet, your LAN and the host's LAN address

All checks passed.
```

With `--containers`, the same checks pass, and the capability lines read `CapBnd`/`CapAmb=00000000000000c0` with a WARN that `no_new_privs` is off.

Why the loopback check reads a token: the first version only tested whether a TCP connection succeeded, and it failed on the author's machine. The cause turned out to be the home router, which accepts connections on every port, not a leak to the host. The listener now sends a random token, and only reading that token back counts as reaching the host. Anything else that answers is reported as a WARN.

## Roadmap

Not done yet, roughly in priority order:
- **Egress allowlist.** Let the pod reach only the model API and the package registries, through a filtering proxy or nftables. This closes the biggest remaining gap in the threat model.
- **Test nested Podman** in `verify --containers` by running a container inside the pod.
- **`:idmap` mounts instead of `keep-id`,** so a breakout doesn't land as the host user.
- **Pin the base image by digest,** and record the Claude Code version in `verify` output.

## License

[Apache-2.0](LICENSE)
