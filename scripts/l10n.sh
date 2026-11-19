#!/bin/bash
# 检查翻译表：编译时让编译器把所有 L("…") / Text("…") 里的文案提取出来，
# 和 Resources/{en,vi}.lproj/Localizable.strings 对比，列出缺的和多余的。
# 用法：scripts/l10n.sh          只检查
#       scripts/l10n.sh --keys   另外把全部文案打印出来（写新翻译时用）
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swift build -c release -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
/usr/bin/python3 -I - "$OUT" "${1:-}" <<'PY'
import glob, json, re, subprocess, sys
out, mode = sys.argv[1], sys.argv[2]
keys = set()
for f in glob.glob(f"{out}/*.stringsdata"):
    if f.endswith("DebugTools.stringsdata"):
        continue   # 命令行调试输出，不翻译
    for items in json.load(open(f))["tables"].values():
        keys.update(i["key"] for i in items)
# 图标里的字母、数字和符号不用翻
keys -= {"%lld", "%", "0", "+", "C", "G", "X", "%@ %@"}
if mode == "--keys":
    print(json.dumps(sorted(keys), ensure_ascii=False, indent=1))

def specs(s):
    return sorted(re.findall(r"%(?:\d\$)?(@|lld)", s.replace("%%", "")))

bad = False
for lang in ["en", "vi"]:
    path = f"Resources/{lang}.lproj/Localizable.strings"
    table = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", path]))
    for k in sorted(keys - table.keys()):
        print(f"[{lang}] 缺翻译: {k!r}"); bad = True
    for k in sorted(table.keys() - keys):
        print(f"[{lang}] 多余: {k!r}")
    for k, v in table.items():
        if specs(k) != specs(v):
            print(f"[{lang}] 占位符不一致: {k!r} -> {v!r}"); bad = True
print("翻译表有问题" if bad else "✅ 翻译表完整")
sys.exit(1 if bad else 0)
PY
