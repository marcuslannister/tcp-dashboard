# Handoff

## Goal

Harden `tcp.sh` (interactive Linux TCP/UDP/RPS tuning panel) so it can be applied
and reversed safely and incrementally. A prior rewrite removed launch-blocking
syntax errors, root-level remote self-update, destructive rollback, unsupported
BBR3 config, and fake "情绪价值" success theater. This session ran a full code
review on that rewrite and fixed the bugs it surfaced.

## Current Progress

- **Branch:** `harden-tcp-tuning` (cut from `main`). **Not pushed. No PR yet.**
- **Commit `ee575d9`** — `fix: scope rollback per-feature and harden state restore`
  — 3 files, +149/-38: `tcp.sh`, `README.md`, `tests/test-static.sh`.
- `test.sh` (untracked stale copy of the OLD script) was **deleted** from the
  worktree. It was never tracked, so the deletion is not in git history.
- `HANDOFF.md` is still **untracked** (this file).
- Worktree is otherwise clean.

### Review performed

- Ran `/code-review` at high effort: full 7-angle multi-agent fan-out (3
  correctness + 3 cleanup + 1 altitude) followed by recall-biased verification.
- Produced 10 ranked findings (correctness first), then applied fixes for all 10
  plus a bonus menu-pause bug.

### Fixes applied (all in `ee575d9`)

1. **Scoped rollback** — per-feature apply failures (BBR, RPS) now undo only
   their own work via new `revert_managed_sysctl` / `revert_rps`, instead of the
   global `rollback_tcp_tune`, which had wiped unrelated, already-applied
   features. Global rollback is now confined to uninstall + menu option 5.
2. **`sysctl --system` non-fatal in rollback** — an unrelated drop-in's non-zero
   exit no longer fails rollback (which had blocked uninstall via the abort in
   `uninstall_script`). Reload is best-effort: `sysctl --system >/dev/null 2>&1 || true`.
3. **gai.conf full default table** — when `/etc/gai.conf` is absent, write the
   complete glibc label/precedence table (IPv4 promoted to precedence 100); a
   lone precedence line would replace the entire built-in table.
4. **Multi-value sysctl restore** — flatten tab-separated `sysctl -n` output to
   spaces at snapshot time so `tcp_rmem` / `ip_local_port_range` etc. round-trip
   cleanly through `sysctl -w`.
5. **Tolerate unsupported keys** — option 3 (`smart_tune_tcp_tune`) warns and
   keeps the supported keys on `sysctl -p` failure instead of aborting + rolling
   back the whole tune.
6. **README** — dropped the "支持一键管道流远程运行" claim the installer now refuses.
7. **Menu IPv4 status** — uses the same whitespace-tolerant regex as the writer.
8. **MSS messages** — distinguish added / already-exists / failed-and-skipped
   (skip is now non-fatal).
9. **Per-step rollback cleanup** — markers (`GAI_CREATED`, `RPS_STATE`) cleaned
   per section, not gated on a shared `failed` flag; `revert_rps` tracks its own rc.
10. **gai admin-recreate guard** — rollback only removes `/etc/gai.conf` if it
    still carries our marker line.
- Bonus: menu option 5 changed from `rollback_tcp_tune && read …` to
  `rollback_tcp_tune; read …` so the result/error always pauses.

## What Worked

- **Inline review + multi-agent fan-out both done.** First pass was inline
  (cost-aware per global rules); when the user asked for the full fan-out, 7
  finder agents ran in parallel and surfaced the same top bugs plus extras.
- **Scoped-revert helpers** (`revert_managed_sysctl`, `restore_sysctl_keys`,
  `revert_rps`, factored `config_keys`) cleanly decouple per-feature undo from
  the global rollback. The invariant "global rollback only in uninstall + option
  5" is asserted in tests as `rg -c 'rollback_tcp_tune' == 3`.
- **Static suite extended** with 6 regression assertions encoding fix intent
  (scoped-revert count, helper presence, tab-flatten, gai default table,
  non-fatal `sysctl --system`, README claim removed).
- **Verification (all green):**

```text
bash -n tcp.sh                # OK
shellcheck -S warning tcp.sh  # only pre-existing SC2155/SC2034, no new findings
bash tests/test-static.sh     # static regression tests passed
```

## What Didn't Work / Constraints

- **No live Linux validation.** This is a macOS host; the static suite only
  checks syntax + grep-level invariants. Do NOT run `sysctl`, `iptables`, or
  `/etc` mutation here. The apply→rollback→uninstall runtime paths are unproven.
- **`sysctl -w` tab acceptance was theoretical** — finding 4 was fixed by
  flattening to spaces at snapshot time (unambiguous), rather than relying on
  whether the kernel tolerates tab-delimited values.
- No project test command is registered; `tests/test-static.sh` is the de-facto
  check. Consider documenting it (e.g. `make test`).

## Next Steps

1. **Push the branch and open a PR** (user asked earlier; not yet done):
   `git push -u origin harden-tcp-tuning` then `gh pr create`.
2. **Smoke-test on disposable Linux VMs** before any release/tag:
   - Ubuntu/Debian with BBR available; a kernel WITHOUT BBR; 1 / 32 / 64 / 96+
     logical-CPU cases for RPS masks.
   - For each: capture state, apply options 1–4 individually, then run option 5
     rollback and confirm exact restoration of `/etc/gai.conf`, script-owned
     sysctl/limits drop-ins, RPS queue files, `net.core.rps_sock_flow_entries`,
     and MSS iptables rule ownership.
   - **Specifically verify the scoped-revert fix:** apply option 3, then make
     option 2 (BBR) fail, and confirm option 3's config survives.
   - Verify uninstall (option 6) completes even when `sysctl --system` exits
     non-zero due to an unrelated drop-in.
3. Decide whether to track `HANDOFF.md` or keep it local/untracked.
4. Re-run `/code-review` (or `check`) after VM testing if further edits land.

## Key Files / Locations

- `tcp.sh` — the panel. State lives under `/var/lib/tcp-dashboard` (backups,
  `.created` markers, `SYSCTL_STATE`, RPS state). Source guard at the bottom
  (`if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi`) lets tests source
  it non-root without opening the menu.
- `tests/test-static.sh` — syntax + RPS-mask + invariant assertions.
- Managed config paths: `/etc/sysctl.d/99-tcp-dashboard-{bbr,network}.conf`,
  `/etc/security/limits.d/99-tcp-dashboard.conf`, `/etc/gai.conf`.
