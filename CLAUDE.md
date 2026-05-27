# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A pure Bash installer + CLI wrapper around the `mihomo` / `clash` proxy kernels for Linux. `install.sh` downloads/unpacks kernels, generates init-system service files, writes shell-rc hooks, and installs the `clashctl` function family. End users interact via `clashctl on|off|sub|ui|tun|mixin|secret|upgrade|...` (also exposed as `clashon`, `clashoff`, etc.).

## Two execution contexts

The same `scripts/lib/*.sh` files are sourced in two different contexts. When editing libs, both must keep working:

1. **Install-time** (running `install.sh` / `uninstall.sh` from the repo): `CLASHCTL_SRC` is the repo root; `scripts/preflight.sh` sources `.env` and every `scripts/lib/*.sh`. Functions like `valid_env`, `prepare_zip`, `install_service`, `install_clashctl`, `apply_rc` only exist in this context.
2. **Runtime** (after install, sourced from user's shell rc): `CLASHCTL_HOME` (default `~/clashctl`) is the install root; `scripts/cmd/clashctl.sh` sources `$CLASHCTL_HOME/.env`, every `scripts/lib/*.sh`, and every `scripts/cmd/*.sh` except itself. This defines the `clashctl` dispatcher plus `clashon`, `clashoff`, `clashsub`, ... as shell functions in the user's interactive shell.

`install.sh` copies `scripts/cmd`, `scripts/lib`, `scripts/init`, and `resources/` into `$CLASHCTL_HOME` — it does NOT symlink. Changes to lib code only affect installed users after re-running the installer.

Config is split across two files at the repo root:

- **`.env`** — runtime-tunable (`CLASHCTL_SUB_TIMEOUT`, `CLASHCTL_SUB_UA`) and auto-managed state (`CLASHCTL_KERNEL`, `INIT_TYPE`). Copied to `$CLASHCTL_HOME` on install; sourced by both `preflight.sh` (install-time) and `scripts/cmd/clashctl.sh` (runtime). Users should not edit the auto-managed section — `_set_env` fills it during install.
- **`.env.install`** — pre-install user choices (`CLASHCTL_HOME`, `CLASHCTL_KERNEL`, `GH_PROXY`, `VERSION_*`, `ZIP_UI`, `CLASHCTL_SUB_URL`). NOT copied to `$CLASHCTL_HOME`; sourced only by `preflight.sh` after `.env`. Editing requires re-running `install.sh`.

`CLASHCTL_KERNEL` deliberately appears in both: `.env.install` carries the user-tunable default; the empty entry in `.env`'s auto-managed section is filled by `_set_env` at install time. Same intent for `CLASHCTL_HOME` — repo's `.env.install` holds the install-path choice; runtime gets `CLASHCTL_HOME` from the shell-rc `export` (`.env` no longer redefines it, so users can't accidentally desync it from the actual install location by editing post-install).

`archives/` holds bundled binary tarballs (mihomo, clash, yq v4, subconverter, zashboard). `install.sh` extracts these into `$CLASH_RESOURCES_DIR` instead of fetching from the network when the matching archive is present — this is what makes the installer work offline once cloned. When an archive is missing, `download_zip` falls back to fetching from GitHub releases (through `GH_PROXY`). If the matching `VERSION_*` in `.env.install` is empty, `_resolve_version` first calls `_fetch_latest_tag` against `api.github.com` (direct, NOT proxied — `gh-proxy.org` only proxies downloads) to pick the latest tag.

## Config merge pipeline

`resources/config.yaml` (the user's subscription) and `resources/mixin.yaml` (user overrides) are deep-merged into `resources/runtime.yaml` by `_merge_config` in `scripts/lib/config.sh`, using a yq expression that supports `prepend` / `append` / `override` semantics on `rules`, `proxies`, `proxy-groups`, plus `inject` for proxy-groups. The kernel is only ever started against `runtime.yaml`. After any change to mixin or the active subscription, `_merge_config_restart` re-merges, stops the kernel (escalating with sudo if Tun is active), and starts it again.

`_valid_config` runs `mihomo/clash -t` against a config before accepting it. Subscription handling (`scripts/lib/convert.sh`) tries raw download first, then falls back to launching the bundled `subconverter` on a free port to convert non-clash formats.

## Service manager abstraction

`scripts/lib/service.sh` `detect_service_manager` inspects `/proc/1/exe` and cgroup info to pick one of `systemd | sysvinit | openrc | runit | nohup`. Container environments (docker/k8s/containerd/podman/lxc) and non-root users are forced to `nohup`. Every service operation (`service_start`, `service_stop`, `service_is_active`, `service_log`, `install_service`, `uninstall_service`) branches on `$service_manager`. Init templates live in `scripts/init/` and use `placeholder_*` tokens that `install_service` substitutes via `sed`.

## Shell-rc integration

`apply_rc` appends a `CLASHCTL_HOME` export + `clashctl.sh` source line to `~/.bashrc` and `~/.zshrc` (only if those files exist), and installs `clashctl.fish` into `~/.config/fish/conf.d/` (fish wraps the bash functions via `bash -i -c`). `revoke_rc` removes those lines on uninstall by matching `/CLASHCTL_HOME/d` with `sed -i.bak`.

## Port-conflict handling

Listening ports (mixed/http/socks/external-controller/subconverter) are checked via `_is_port_used` (ss → netstat fallback). On conflict, `_get_random_port` picks an unused port in 1024–65535 and writes the new value into `mixin.yaml` (or `pref.yml` for subconverter), then triggers a re-merge.

## Stateful files in `$CLASH_RESOURCES_DIR`

Three runtime-managed files live alongside the kernel — distinguishing them matters when debugging:

- `runtime.yaml` — the merged config the kernel actually loads. Regenerated on every `_merge_config`; never hand-edit.
- `mixin.yaml` — user overrides. Edited via `clashmixin -e`, and also written to programmatically when port conflicts force a re-allocation.
- `pref.yml` — internal preferences: the subscription registry (`scripts/cmd/sub.sh` uses it for `add`/`ls`/`use`/`del` of multiple subscriptions by id) and the cached subconverter port. Treat as state, not config.

## Conventions

- Bash 4+, target `/usr/bin/env bash`. Uses associative arrays, `${var,,}` lowercase, and globstar — won't work on Bash 3 (macOS default). `.editorconfig` is 2-space indent, LF endings.
- ShellCheck config in `.shellcheckrc` disables SC1090, SC1091, SC2153, SC2155, SC2296 (don't add fixes for these globally).
- User-facing output uses the `_okcat` / `_failcat` / `_errorcat` helpers in `scripts/lib/common.sh` — all messages are in Chinese with emoji prefixes. Match that style.
- Functions intended as internal helpers are prefixed with `_` (e.g. `_merge_config`, `_get_secret`). Public CLI entry points are `clash<name>` (e.g. `clashon`, `clashsub`).
- Use absolute paths for `cp`/`rm`/`install` (e.g. `/bin/cp`, `/usr/bin/rm`, `/usr/bin/install`) — the codebase does this deliberately to avoid alias interference in interactive shells.
- `BIN_YQ` is the bundled yq (v4); use it rather than assuming a system yq. All yq invocations in this repo use go-yq v4 syntax.

## Common commands

```bash
bash install.sh                  # install (optional args: mihomo|clash, or a subscription URL)
bash install.sh mihomo <url>     # install with a specific kernel and subscription
bash uninstall.sh                # remove $CLASHCTL_HOME, undo shell-rc edits, remove cron entry
find scripts -path scripts/init -prune -o -name '*.sh' -print0 | xargs -0 shellcheck   # lint (no test suite; scripts/init/* are init templates, not shell)
```

There is no automated test suite. To test changes that affect installed behavior, you generally need to run `bash install.sh` in a sandbox, exercise the relevant `clash*` command, then `bash uninstall.sh`. Avoid running these against your real `$CLASHCTL_HOME` while iterating.

## Things easy to get wrong

- `CLASHCTL_SRC` exists only at install/uninstall time. Don't reference it from `scripts/cmd/*.sh` or any code that runs at runtime — use `CLASHCTL_HOME` instead.
- Editing files under `$CLASHCTL_HOME` does not update the repo, and vice versa. The two trees drift unless you re-install.
- Never modify `runtime.yaml` directly — it's regenerated on every merge. Put overrides in `mixin.yaml`.
- The `nohup` service path writes pid/log under `$CLASH_RESOURCES_DIR`, not `/run` or `/var/log`. Code that touches log/pid paths must call `detect_service_manager` first so `service_log_path` / `service_pid_path` are set correctly.
