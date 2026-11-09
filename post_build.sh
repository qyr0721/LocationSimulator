#!/bin/bash
# LocationSimulator 构建后处理脚本
# 用法: bash post_build.sh
# 步骤: 裁剪调试符号 → Mach-O 修复 → ldid 签名嵌入 entitlements → 打包 IPA

set -e

APP="/root/LocationSimulator-XTool/xtool/LocationSimulator.app"
MAIN="$APP/LocationSimulator"
MAIN_ENT="/root/LocationSimulator-XTool/Support/LocationSimulator.entitlements"
IPA_OUT="/root/LocationSimulator-XTool/xtool/LocationSimulator.ipa"
WIN_OUT="/mnt/c/Users/Administrator/WorkBuddy/2026-11-08-22-52-59/ipa-output/LocationSimulator.ipa"

# 1. 裁剪调试符号（必须在签名之前）
#    LLVM 链接出的二进制会保留完整符号表与字符串表（本项目约 22 MB），
#    运行时完全用不到，且 GNU strip / llvm-objcopy 都不支持 Mach-O，
#    因此直接改 Mach-O 头：把 LC_SYMTAB 置空并整体前移代码签名。
echo "[1/5] 裁剪调试符号..."
python3 << 'PYEOF'
import struct, os

path = "/root/LocationSimulator-XTool/xtool/LocationSimulator.app/LocationSimulator"
with open(path, "rb") as f:
    data = bytearray(f.read())
orig = len(data)

nc = struct.unpack("<I", data[16:20])[0]
off = 32
symtab_off = dysymtab_off = None
codesig_off = codesig_size = None
linkedit_off = None

for _ in range(nc):
    cmd, cs = struct.unpack("<II", data[off:off+8])
    if cmd == 0x2:      # LC_SYMTAB
        symtab_off = off
    elif cmd == 0xB:    # LC_DYSYMTAB
        dysymtab_off = off
    elif cmd == 0x19:   # LC_SEGMENT_64
        if data[off+8:off+24].rstrip(b"\x00") == b"__LINKEDIT":
            linkedit_off = off
    elif cmd == 0x1D:   # LC_CODE_SIGNATURE
        codesig_off, codesig_size = struct.unpack("<II", data[off+8:off+16])
    off += cs

if symtab_off is None or codesig_off is None:
    print("  跳过：未找到符号表或代码签名")
else:
    symoff, nsyms, stroff, strsize = struct.unpack("<IIII", data[symtab_off+8:symtab_off+24])
    sym_end = stroff + strsize
    if nsyms == 0:
        print("  已经是无符号表二进制，跳过")
    elif codesig_off < sym_end:
        print("  跳过：代码签名位于符号数据之前")
    else:
        delta = codesig_off - symoff
        new_data = data[:symoff] + data[codesig_off:]

        # LC_SYMTAB 置空
        struct.pack_into("<I", new_data, symtab_off+8, symoff)
        struct.pack_into("<I", new_data, symtab_off+12, 0)
        struct.pack_into("<I", new_data, symtab_off+16, symoff)
        struct.pack_into("<I", new_data, symtab_off+20, 0)

        # LC_DYSYMTAB 清零
        if dysymtab_off is not None:
            struct.pack_into("<IIIIII", new_data, dysymtab_off+8, 0, 0, 0, 0, 0, 0)
            struct.pack_into("<IIIIII", new_data, dysymtab_off+32, 0, 0, 0, 0, 0, 0)
            struct.pack_into("<II", new_data, dysymtab_off+56, 0, 0)
            struct.pack_into("<IIII", new_data, dysymtab_off+64, 0, 0, 0, 0)

        # 代码签名整体前移
        o = 32
        for _ in range(nc):
            c, s = struct.unpack("<II", new_data[o:o+8])
            if c == 0x1D:
                struct.pack_into("<I", new_data, o+8, codesig_off - delta)
            elif c == 0x19 and new_data[o+8:o+24].rstrip(b"\x00") == b"__LINKEDIT":
                old_fsize = struct.unpack("<Q", new_data[o+48:o+56])[0]
                new_fsize = old_fsize - delta
                struct.pack_into("<Q", new_data, o+48, new_fsize)
                struct.pack_into("<Q", new_data, o+32, max((new_fsize + 0xFFF) & ~0xFFF, 0x1000))
            o += s

        with open(path, "wb") as f:
            f.write(new_data)
        print(f"  删除 {delta/1048576:.1f} MB 符号数据，{orig/1048576:.1f} MB -> {len(new_data)/1048576:.1f} MB")
PYEOF

# 2. Mach-O 段边界修复（必须在签名之前！）
echo "[2/5] Mach-O 段边界修复..."
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

# 3. ldid 签名嵌入 entitlements
echo "[3/5] ldid 签名嵌入 entitlements..."
/tmp/ldid -S"$MAIN_ENT" "$MAIN"
echo "  主 App signed"

# 4. 验证 entitlements
echo "[4/5] 验证 entitlements..."
/tmp/ldid -e "$MAIN" | head -6

# 5. 添加 avatar + 打包 IPA
echo "[5/5] 打包 IPA..."
python3 << PYEOF
import os, zipfile, shutil

APP = "$APP"

# avatar
shutil.copy2("/root/LocationSimulator-XTool/Resources/avatar.jpg", APP + "/avatar.jpg")

# 清理可能残留的备份
for junk in ("LocationSimulator.bak",):
    p = os.path.join(APP, junk)
    if os.path.exists(p): os.remove(p)

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
