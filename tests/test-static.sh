#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/tcp.sh"

bash -n "$SCRIPT"

# Source mode must expose helpers without requiring root or opening the menu.
source "$SCRIPT"

[ "$(rps_cpu_mask 1)" = "1" ]
[ "$(rps_cpu_mask 32)" = "ffffffff" ]
[ "$(rps_cpu_mask 64)" = "ffffffff,ffffffff" ]
[ "$(rps_cpu_mask 96)" = "ffffffff,ffffffff,ffffffff" ]

if rg -n '\\\$|SCRIPT_URL|download_script|check_update|tcp\.vpsing\.de|bash <\(curl|强制同步更新|tcp_congestion_control_version|10-bbr\.conf|pfifo_fast|ulimit -n 1024|curl -sL|ethtool -G|gai\.conf\.bak|0ms|补丁注入|Unbinding Single Core IRQ|\[SUCCESS\]|\[[[:space:]]+OK|\[DONE\]|6w\+|全核均衡' "$SCRIPT" "$ROOT/README.md"; then
    echo "unsafe or obsolete pattern found" >&2
    exit 1
fi

rg -q 'SHORTCUT_CREATED' "$SCRIPT"
rg -q 'prepare_managed_file' "$SCRIPT"
rg -q 'restore_managed_file' "$SCRIPT"
rg -q 'snapshot_sysctls' "$SCRIPT"
rg -q 'restore_sysctls' "$SCRIPT"

# A per-feature apply failure must scope its undo to its own work, never call the
# global rollback (which would wipe unrelated, already-applied features). The
# global rollback belongs only to uninstall and the explicit "rollback" menu item.
[ "$(rg -c 'rollback_tcp_tune' "$SCRIPT")" -eq 3 ]
rg -q 'revert_managed_sysctl' "$SCRIPT"
rg -q 'revert_rps' "$SCRIPT"

# Multi-value sysctls must be flattened to spaces so the snapshot round-trips
# cleanly through `sysctl -w` on rollback.
rg -qF "value=\${value//\$'\\t'/ }" "$SCRIPT"

# set_ipv4_priority must write the full glibc default table when gai.conf is
# absent; a lone precedence line would replace the entire built-in table.
rg -q 'label  ::1/128' "$SCRIPT"

# Rollback must not let an unrelated `sysctl --system` non-zero exit fail the
# rollback (which would block uninstall).
rg -q 'sysctl --system >/dev/null 2>&1 \|\| true' "$SCRIPT"

# The README must not claim pipe/process-substitution remote execution, which the
# installer now refuses.
if rg -q '支持一键管道流远程运行' "$ROOT/README.md"; then
    echo "README still claims unsupported pipe execution" >&2
    exit 1
fi

echo "static regression tests passed"
