#!/usr/bin/env python3
"""把 install-header.sh + 载荷 tar.gz 拼成一个自解压安装脚本。

用法:  python build.py
输入:  ./install-header.sh               安装器模板（@SHA256@ / @SKIP@ 占位）
       ../release/e5-panel-<VER>.tar.gz  载荷（相对 / 的路径树）
输出:  ../release/e5-panel-install.sh
"""
import hashlib
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
RELEASE = HERE.parent / "release"
VER = "1.0.0"

HEADER = HERE / "install-header.sh"
PAYLOAD = RELEASE / f"e5-panel-{VER}.tar.gz"
OUT = RELEASE / "e5-panel-install.sh"

if not PAYLOAD.exists():
    sys.exit(f"缺少载荷 {PAYLOAD}（先用 tar -czf 打一份）")

data = PAYLOAD.read_bytes()
sha = hashlib.sha256(data).hexdigest()

text = HEADER.read_text(encoding="utf-8").replace("\r\n", "\n")
if not text.endswith("\n"):
    text += "\n"
text = text.replace("@SHA256@", sha)

# 占位符先留固定宽度，等行数定下来再回填（回填不改行数）
first = text.replace("@SKIP@", "0000000")
lines = first.count("\n")
skip = lines + 1  # 载荷从第 skip 行开始
final = text.replace("@SKIP@", str(skip))
assert final.count("\n") == lines, "SKIP 位数变了，行数会漂移"

OUT.write_bytes(final.encode("utf-8") + data)
# 回读校验：按 SKIP 取出来的字节必须和载荷一致
got = OUT.read_bytes().split(b"\n")
assert b"\n".join(got[skip - 1:]) == data, "回读校验失败"

print(f"{OUT.name}  {OUT.stat().st_size} bytes  sha256={sha[:16]}…  SKIP={skip}")
