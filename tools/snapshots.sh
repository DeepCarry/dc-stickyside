#!/usr/bin/env bash
# 随手贴界面快照批量渲染：把主要界面 × 浅/深两套外观渲成 PNG，供设计评审。
# 用法：bash tools/snapshots.sh [输出目录]   （默认 shots/ci）
# 前置：先在仓库根目录跑过 swift build（debug），得到 .build/debug/NoteWall。
# 单个场景失败不中断，全部跑完汇总；一张都没渲出来才返回非零。
set -u
BIN=.build/debug/NoteWall
OUT=${1:-shots/ci}
mkdir -p "$OUT"
if [ ! -x "$BIN" ]; then
  echo "找不到可执行文件 $BIN，请先在仓库根目录运行 swift build"
  exit 1
fi
ok=0
fail=0
run() {
  # $1=场景 $2=尺寸（固定尺寸的场景会忽略它）
  for ap in light dark; do
    f="$OUT/$1-$ap.png"
    if "$BIN" --snapshot "$1" "$f" "$2" --appearance "$ap" >/dev/null 2>&1 && [ -s "$f" ]; then
      ok=$((ok + 1))
      echo "ok   $f"
    else
      fail=$((fail + 1))
      echo "FAIL $1 ($ap)"
    fi
  done
}
run wall      1440x920
run wallimage 1440x920
run empty     1440x920
run capture   800x400
run card      800x600
run cardmenu  800x600
run detail    800x700
run locked    800x600
run lockdetail 800x700
run edgefan   500x760
run edgepull  500x760
run settings  900x700
run trash     900x700
echo "快照完成：成功 $ok，失败 $fail，输出目录 $OUT"
[ "$ok" -gt 0 ]
