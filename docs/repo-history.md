# 仓库历史说明（拆分索引）

本仓库 2026-10-31 从 `~/Downloads/shortcut general`（ShortcutGeneral 项目）经
`git subtree split -P mirabox` 拆分为独立仓库,102 条提交完整保留,路径已剥掉
`mirabox/` 前缀。

**subtree split 重写了路径,因此本仓库的 commit hash 与父仓库不同。**
旧文档/skill/记忆里引用的旧 hash（如 `aa3e421` checkpoint、`3e0b23d` 守卫下沉、
更早的 `640023d`/`a1661e4` 等）仍在父仓库 `shortcut general` 的历史中可查:

    git -C ~/Downloads/"shortcut general" log --oneline -- mirabox/

新旧对照（拆分点时的最近几条）:

| 本仓库 | 父仓库(旧 hash) | 内容 |
|---|---|---|
| `65a4940` | `3e0b23d` | setKeysBlacked 熄屏守卫下沉 |
| `83ce75e` | `5e3bec2` | 入库 P0/P1 遗留资产 |
| `40b45cb` | `18de11a` | 门禁装成 pre-commit |
| `e012e18` | （M1 驱动层首次入库） | MiraDeck M1 |
