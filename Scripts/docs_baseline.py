#!/usr/bin/env python3
"""OpenDeck 交接文档基线：快照 + 差异报告。

用途：多个 agent 共用同一套文档时，先做一份基线快照；之后对比
当前文档与基线，新增的行/新增的文件就是「基线之后写进来的内容」。
如果这些内容不是本 agent 写的，就说明是另一个 agent 写的。

用法（在 mirabox/ 下）：
    python3 Scripts/docs_baseline.py snapshot [--label 说明]
    python3 Scripts/docs_baseline.py diff [基线目录] [--full]
    python3 Scripts/docs_baseline.py status
    python3 Scripts/docs_baseline.py snapshots

约定：
- 基线存放在 .handoff-baseline/<时间戳>[-label]/，最新一份记录在 LATEST。
- 扫描范围 = mirabox 下所有 *.md，排除 .build/.git/.zcode/dist/.handoff-baseline。
- diff 默认输出完整 unified diff，并额外列出「只属于当前版本的新增行」。
- 退出码：0 = 与基线一致；1 = 有差异；2 = 用法/基线错误。
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE_ROOT = ROOT / ".handoff-baseline"
LATEST_FILE = BASELINE_ROOT / "LATEST"
EXCLUDED_DIRS = {".build", ".git", ".zcode", "dist", "node_modules", ".handoff-baseline"}


def collect_docs() -> list[Path]:
    docs: list[Path] = []
    for path in ROOT.rglob("*.md"):
        rel = path.relative_to(ROOT)
        if any(part in EXCLUDED_DIRS for part in rel.parts):
            continue
        docs.append(path)
    return sorted(docs, key=lambda p: p.relative_to(ROOT).as_posix())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 256), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="OpenDeck 交接文档基线工具")
    sub = parser.add_subparsers(dest="command", required=True)

    snap = sub.add_parser("snapshot", help="把当前文档快照为一份基线")
    snap.add_argument("--label", default="", help="可选标签，追加到目录名")

    diff = sub.add_parser("diff", help="对比当前文档与基线")
    diff.add_argument("baseline", nargs="?", help="基线目录名或路径；缺省用 LATEST")
    diff.add_argument("--full", action="store_true", help="输出完整 unified diff（默认只列新增行）")

    sub.add_parser("status", help="只显示哪些文档相对基线有变化")
    sub.add_parser("snapshots", help="列出全部基线快照")
    return parser.parse_args()


def latest_baseline() -> Path | None:
    if not LATEST_FILE.exists():
        return None
    name = LATEST_FILE.read_text(encoding="utf-8").strip()
    if not name:
        return None
    candidate = BASELINE_ROOT / name
    return candidate if candidate.is_dir() else None


def resolve_baseline(raw: str | None) -> Path | None:
    if raw:
        candidate = Path(raw)
        if not candidate.is_absolute():
            by_name = BASELINE_ROOT / raw
            candidate = by_name if by_name.is_dir() else ROOT / raw
        return candidate if candidate.is_dir() else None
    return latest_baseline()


def cmd_snapshot(label: str) -> int:
    docs = collect_docs()
    if not docs:
        print("没有找到任何 Markdown 文档。", file=sys.stderr)
        return 2

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    name = f"{stamp}-{label}" if label else stamp
    name = "".join(ch if ch.isalnum() or ch in "-_." else "-" for ch in name)
    dest = BASELINE_ROOT / name
    dest.mkdir(parents=True, exist_ok=True)

    manifest = {
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "label": label,
        "root": str(ROOT),
        "files": {},
    }
    for doc in docs:
        rel = doc.relative_to(ROOT)
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(doc, target)
        manifest["files"][rel.as_posix()] = {
            "sha256": sha256(doc),
            "size": doc.stat().st_size,
        }

    (dest / "MANIFEST.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    LATEST_FILE.write_text(dest.name + "\n", encoding="utf-8")

    print(f"基线已创建：{dest.relative_to(ROOT)}")
    for rel in manifest["files"]:
        print(f"  {rel}")
    return 0


def baseline_manifest(baseline: Path) -> dict:
    manifest_path = baseline / "MANIFEST.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"{baseline} 缺少 MANIFEST.json")
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def unified_diff(old: str, new: str, old_name: str, new_name: str) -> list[str]:
    return list(
        difflib.unified_diff(
            old.splitlines(keepends=True),
            new.splitlines(keepends=True),
            fromfile=old_name,
            tofile=new_name,
            n=3,
        )
    )


def added_lines(old: str, new: str) -> list[tuple[int, str]]:
    """返回 (当前文件行号, 行内容)。只统计 unified diff 里真正的 + 行。"""
    old_lines = old.splitlines()
    new_lines = new.splitlines()
    result: list[tuple[int, str]] = []
    current_line = 0
    for line in difflib.unified_diff(old_lines, new_lines, n=0, lineterm=""):
        if line.startswith("@@"):
            # @@ -a,b +c,d @@ → 记录新文件起始行
            plus = line.split("+", 1)[1].split(" ", 1)[0]
            start = plus.split(",", 1)[0]
            current_line = int(start) - 1
            continue
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+"):
            current_line += 1
            result.append((current_line, line[1:]))
        elif line.startswith(" "):
            current_line += 1
    return result


def cmd_diff(raw_baseline: str | None, full: bool) -> int:
    baseline = resolve_baseline(raw_baseline)
    if baseline is None:
        print("找不到基线。先运行：python3 Scripts/docs_baseline.py snapshot", file=sys.stderr)
        return 2
    try:
        manifest = baseline_manifest(baseline)
    except (FileNotFoundError, json.JSONDecodeError) as error:
        print(f"基线不可读：{error}", file=sys.stderr)
        return 2

    old_files: dict[str, dict] = manifest.get("files", {})
    current = {doc.relative_to(ROOT).as_posix(): doc for doc in collect_docs()}

    added_files = sorted(set(current) - set(old_files))
    removed_files = sorted(set(old_files) - set(current))
    modified_files = sorted(
        rel for rel in set(current) & set(old_files)
        if sha256(current[rel]) != old_files[rel].get("sha256")
    )

    print(f"基线：{baseline.relative_to(ROOT)}（{manifest.get('created_at', '?')}）")
    print(f"当前：{len(current)} 份文档；新增 {len(added_files)}，修改 {len(modified_files)}，删除 {len(removed_files)}")

    if not (added_files or removed_files or modified_files):
        print("与基线一致：没有发现其他 agent 写入的内容。")
        return 0

    if added_files:
        print("\n## 新增文件（基线之后出现）")
        for rel in added_files:
            print(f"  + {rel}  ({current[rel].stat().st_size} B)")

    if removed_files:
        print("\n## 删除文件（基线之后消失）")
        for rel in removed_files:
            print(f"  - {rel}")

    for rel in modified_files:
        old_text = read_text(baseline / rel)
        new_text = read_text(current[rel])
        print(f"\n## 修改：{rel}")
        changes = added_lines(old_text, new_text)
        if changes:
            print("### 新增行（疑似基线之后写入的内容）")
            for lineno, content in changes:
                print(f"  {rel}:{lineno}: {content}")
        else:
            print("### 没有新增行，只有删除/替换。")
        if full:
            print("\n### unified diff")
            sys.stdout.writelines(unified_diff(old_text, new_text, f"基线/{rel}", f"当前/{rel}"))
            if not new_text.endswith("\n"):
                print()

    print("\n判断方法：上面「新增行/新增文件」如果不是你写的，就是另一个 agent 写的。")
    return 1


def cmd_status() -> int:
    baseline = latest_baseline()
    if baseline is None:
        print("还没有基线。运行：python3 Scripts/docs_baseline.py snapshot", file=sys.stderr)
        return 2
    manifest = baseline_manifest(baseline)
    old_files: dict[str, dict] = manifest.get("files", {})
    current = {doc.relative_to(ROOT).as_posix(): doc for doc in collect_docs()}
    added = sorted(set(current) - set(old_files))
    removed = sorted(set(old_files) - set(current))
    modified = sorted(
        rel for rel in set(current) & set(old_files)
        if sha256(current[rel]) != old_files[rel].get("sha256")
    )
    print(f"基线：{baseline.relative_to(ROOT)}（{manifest.get('created_at', '?')}）")
    if not (added or removed or modified):
        print("状态：一致")
        return 0
    for rel in modified:
        print(f"  M {rel}")
    for rel in added:
        print(f"  A {rel}")
    for rel in removed:
        print(f"  D {rel}")
    return 1


def cmd_snapshots() -> int:
    if not BASELINE_ROOT.is_dir():
        print("还没有基线。")
        return 0
    entries = sorted(path for path in BASELINE_ROOT.iterdir() if path.is_dir())
    if not entries:
        print("还没有基线。")
        return 0
    latest = latest_baseline()
    for entry in entries:
        mark = " *" if latest and entry.name == latest.name else ""
        print(f"{entry.name}{mark}")
    return 0


def main() -> int:
    args = parse_args()
    if args.command == "snapshot":
        return cmd_snapshot(args.label)
    if args.command == "diff":
        return cmd_diff(args.baseline, args.full)
    if args.command == "status":
        return cmd_status()
    if args.command == "snapshots":
        return cmd_snapshots()
    return 2


if __name__ == "__main__":
    sys.exit(main())
