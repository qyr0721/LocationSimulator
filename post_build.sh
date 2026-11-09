#!/bin/bash
# LocationSimulator 构建后处理脚本
# 用法: bash post_build.sh
# 步骤: Mach-O修复 → ldid签名嵌入entitlements → 添加xcent → 打包IPA

set -e

APP="/root/LocationSimulator-XTool/xtool/LocationSimulator.app"
MAIN="$APP/LocationSimulator"
MAIN_ENT="/root/LocationSimulator-XTool/Support/LocationSimulator.entitlements"
IPA_OUT="/root/LocationSimulator-XTool/xtool/LocationSimulator.ipa"
WIN_OUT="/mnt/c/Users/Administrator/WorkBuddy/2026-11-08-22-52-59/ipa-output/LocationSimulator.ipa"

# 1. Mach-O 段边界修复（必须在签名之前！）
echo "[1/4] Mach-O 段边界修复..."
python3 << 'PYEOF'
import struct
path = "/root/LocationSimulator-XTool/xtool/LocationSimulator.app/LocationSimulator"
with open(path, "rb") as f:
    data = bytearray(f.read())
fs = len(data)
nc = struct.unpack("<I", data[16:20])[0]
off, fixes = 32, 0
for _ in range(nc):
    cmd, cs = struct.unpack("<II", data[off:off+8])
    if cmd == 0x19:
        seg = struct.unpack("<QQQQ", data[off+24:off+56])
        if seg[2] + seg[3] > fs:
            a = fs - seg[2]
            struct.pack_into("<Q", data, off+48, a)
            struct.pack_into("<Q", data, off+32, max((a+0xFFF)&~0xFFF, 0x1000))
            fixes += 1
    elif cmd == 0x1D:
        ds = struct.unpack("<II", data[off+8:off+16])
        if ds[0] + ds[1] > fs:
            struct.pack_into("<II", data, off, 0x24, cs)
            fixes += 1
    off += cs
if fixes:
    with open(path, "wb") as f: f.write(data)
print(f"  Main: {fixes} fixes, {fs} bytes")
PYEOF

# 2. ldid 签名嵌入 entitlements
echo "[2/4] ldid 签名嵌入 entitlements..."
/tmp/ldid -S"$MAIN_ENT" "$MAIN"
echo "  主 App signed"

# 3. 验证 entitlements
echo "[3/4] 验证 entitlements..."
/tmp/ldid -e "$MAIN" | head -6

# 4. 添加 avatar + 打包 IPA
echo "[4/4] 打包 IPA..."
python3 << PYEOF
import os, zipfile, shutil

APP = "$APP"

# avatar
shutil.copy2("/root/LocationSimulator-XTool/Resources/avatar.jpg", APP + "/avatar.jpg")

# 打包 IPA
ipa = "$IPA_OUT"
if os.path.exists(ipa): os.remove(ipa)
with zipfile.ZipFile(ipa, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(APP):
        for fn in files:
            fp = os.path.join(root, fn)
            arc = "Payload/" + os.path.relpath(fp, os.path.dirname(APP))
            zf.write(fp, arc)
shutil.copy2(ipa, "$WIN_OUT")
size = os.path.getsize(ipa) / 1048576
print(f"  IPA: {size:.2f} MB")

z = zipfile.ZipFile(ipa)
for n in sorted(z.namelist()):
    print(f"    {n}")
PYEOF

echo ""
echo "=== 完成 ==="
