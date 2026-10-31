#!/bin/bash
# 安装 OpenDeck「合盖休眠锁」所需的精确 sudoers 免密规则。
#
# 只放行这一条命令的两个取值，其他 sudo 权限一律不变：
#     /usr/bin/pmset -a disablesleep 1
#     /usr/bin/pmset -a disablesleep 0
#
# 用法（会要求输入一次登录密码）：
#     sudo bash "/Users/yorkli/Downloads/shortcut general/mirabox/Scripts/install-pmset-sudoers.sh"

set -uo pipefail

TARGET="/etc/sudoers.d/pmset-disablesleep"
USER_NAME="yorkli"
RULE="${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 需要 root 权限运行：sudo bash \"$0\"" >&2
    exit 1
fi

echo "▸ 目标：$TARGET"
if [ -f "$TARGET" ]; then
    BACKUP="${TARGET}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$TARGET" "$BACKUP"
    echo "▸ 旧规则已备份到 $BACKUP"
fi

printf '%s\n' "$RULE" > "$TARGET"
chown root:wheel "$TARGET"
chmod 0440 "$TARGET"

echo "▸ 语法校验（visudo -c）"
if ! visudo -c -q; then
    echo "❌ sudoers 语法校验失败，正在撤销本次写入" >&2
    rm -f "$TARGET"
    exit 1
fi

echo
echo "--- $TARGET 内容 ---"
cat "$TARGET"

echo
echo "--- 以 $USER_NAME 身份自测（写 0，当前即 0，幂等） ---"
if sudo -u "$USER_NAME" sudo -n /usr/bin/pmset -a disablesleep 0; then
    echo "✅ 免密调用通过"
else
    echo "❌ 免密调用失败：规则未生效（检查用户名是否与 $USER_NAME 一致、文件权限是否 0440）" >&2
    exit 1
fi

echo
echo "当前状态：$(pmset -g | awk '/SleepDisabled/{print "SleepDisabled = " $2}')"
echo "✅ 完成。回到 OpenDeck 按那颗键即可切换。"
