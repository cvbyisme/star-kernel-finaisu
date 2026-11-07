#!/bin/bash
# Linux 5.4 compatibility shims for FinaSU v1.2.1 on star (sm8350)
set -e
KDIR="$1"
[ -d "$KDIR" ] || { echo "usage: $0 <kernel-dir>"; exit 1; }
SUDIR="$KDIR/KernelSU/kernel"
[ -d "$SUDIR" ] || { echo "ERROR: $SUDIR missing"; exit 1; }

echo "=== [v121] step 1: force KSU_NO_PREINIT ==="
KB="$SUDIR/Kbuild"
if [ -f "$KB" ] && ! grep -q 'v121_force_no_preinit' "$KB"; then
  sed -i 's|^kernelsu-objs += preinit/preinit.o$|# v121_force_no_preinit: preinit disabled|' "$KB"
  sed -i 's|^kernelsu-objs += preinit/blob.o$||' "$KB"
  grep -q -- '-DKSU_NO_PREINIT' "$KB" || echo 'ccflags-y += -DKSU_NO_PREINIT' >> "$KB"
  echo "  patched: preinit objects removed, -DKSU_NO_PREINIT forced"
else
  echo "  skipped (already applied)"
fi

echo "=== [v121] step 2: 5.4 shims for feature/sucompat.c ==="
python3 - "$SUDIR" <<'PYEOF'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'feature', 'sucompat.c')
if not os.path.exists(path):
    print('  ERROR: sucompat.c not found'); sys.exit(1)
src = open(path, encoding='utf-8').read()

# --- 2a: linux/pgtable.h does not exist before 5.8 ---
old = '#include <linux/pgtable.h>'
if old in src:
    src = src.replace(old, '#include <asm/pgtable.h> /* v121: linux/pgtable.h split out in 5.8 */', 1)
    print('  patched: pgtable.h -> asm/pgtable.h')
elif 'v121: linux/pgtable.h' in src:
    print('  skipped: pgtable already patched')
else:
    print('  WARN: pgtable anchor not found')

# --- 2b: strncpy_from_user_nofault() only exists since 5.7 ---
marker = 'v121_strncpy_nofault'
if marker in src:
    print('  skipped: strncpy shim already present')
else:
    shim = (
        '/* v121_strncpy_nofault: strncpy_from_user_nofault() only exists since 5.7 */\n'
        '#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 7, 0))\n'
        'static inline long ksu_strncpy_from_user_nofault(char *dst, const void __user *src, long count)\n'
        '{\n'
        '    long ret = 0;\n'
        '    if (unlikely(count <= 0))\n'
        '        return 0;\n'
        '    pagefault_disable();\n'
        '    ret = strncpy_from_user(dst, src, count);\n'
        '    pagefault_enable();\n'
        '    return ret;\n'
        '}\n'
        '#else\n'
        '#define ksu_strncpy_from_user_nofault(dst, src, count) strncpy_from_user_nofault(dst, src, count)\n'
        '#endif\n'
    )
    # insert after the last #include of the first include block
    anchor = '#include "util.h"\n'
    if anchor not in src:
        anchor = '#include <linux/ptrace.h>\n'
    if anchor not in src:
        print('  ERROR: no anchor for shim insertion'); sys.exit(1)
    src = src.replace(anchor, anchor + '\n' + shim, 1)
    # rewrite call sites
    n = src.count('strncpy_from_user_nofault(path,')
    src = src.replace('strncpy_from_user_nofault(path,', 'ksu_strncpy_from_user_nofault(path,')
    print('  patched: strncpy shim added, %d call sites rewritten' % n)

open(path, 'w', encoding='utf-8').write(src)
PYEOF


echo "=== [v121] step 3: 5.4 shims for hook/arm64/patch_memory.c ==="
python3 - "$SUDIR" <<'PYEOF3'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'hook', 'arm64', 'patch_memory.c')
if not os.path.exists(path):
    print('  ERROR: patch_memory.c not found'); sys.exit(1)
src = open(path, encoding='utf-8').read()

if 'v121_patchmem_shim' in src:
    print('  skipped: patch_memory.c already patched'); sys.exit(0)

# 1) __p4d_to_phys does not exist on 5.4 (it appeared in 5.5)
src = src.replace('__p4d_to_phys(*p4d)', 'ksu_p4d_to_phys_54(*p4d)', 1)

# 2) copy_to_kernel_nofault appeared in 5.8
n = src.count('copy_to_kernel_nofault(')
src = src.replace('ret = (int)copy_to_kernel_nofault(map, src, len);',
                  'ret = (int)ksu_copy_to_kernel_nofault(map, src, len);', 1)

shim = (
    '\n/* v121_patchmem_shim: helpers that only exist on newer kernels */\n'
    '#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 5, 0))\n'
    '#define ksu_p4d_to_phys_54(p4d) __pa(p4d_val(p4d) & PHYS_MASK)\n'
    '#else\n'
    '#define ksu_p4d_to_phys_54(p4d) __p4d_to_phys(p4d)\n'
    '#endif\n'
    '\n'
    '#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0))\n'
    'static inline long ksu_copy_to_kernel_nofault(void *dst, const void *src, size_t size)\n'
    '{\n'
    '    memcpy(dst, src, size);\n'
    '    return 0;\n'
    '}\n'
    '#else\n'
    '#define ksu_copy_to_kernel_nofault(dst, src, size) copy_to_kernel_nofault(dst, src, size)\n'
    '#endif\n'
)

anchor = '#include "asm-generic/fixmap.h"\n'
if anchor not in src:
    print('  ERROR: anchor not found'); sys.exit(1)
src = src.replace(anchor, anchor + shim, 1)

open(path, 'w', encoding='utf-8').write(src)
print('  patched: patch_memory.c (p4d_to_phys + copy_to_kernel_nofault shims)')
PYEOF3


echo "=== [v121] step 4: 5.4 shims for sulog/event.c ==="
python3 - "$SUDIR" <<'PYEOF4'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'sulog', 'event.c')
if not os.path.exists(path):
    print('  ERROR: sulog/event.c not found'); sys.exit(1)
src = open(path, encoding='utf-8').read()
if 'v121_minmax_shim' in src:
    print('  skipped: minmax already patched'); sys.exit(0)
old = '#include <linux/minmax.h>'
if old not in src:
    print('  WARN: linux/minmax.h anchor not found'); sys.exit(0)
new = ('/* v121_minmax_shim: linux/minmax.h split out in 5.11; 5.4 has these in linux/kernel.h */\n'
       '#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 11, 0))\n'
       + old + '\n'
       '#else\n'
       '#include <linux/kernel.h>\n'
       '#endif')
src = src.replace(old, new, 1)
open(path, 'w', encoding='utf-8').write(src)
print('  patched: sulog/event.c minmax include guarded')
PYEOF4


echo "=== [v121] step 5: 5.4 stub for infra/seccomp_cache.c ==="
python3 - "$SUDIR" <<'PYEOF5'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'infra', 'seccomp_cache.c')
if not os.path.exists(path):
    print('  ERROR: infra/seccomp_cache.c not found'); sys.exit(1)
src = open(path, encoding='utf-8').read()
if 'v121_seccomp_stub' in src:
    print('  skipped: seccomp stub already applied'); sys.exit(0)

stub = '''/* v121_seccomp_stub: Linux 5.4 has no seccomp bitmap cache (added in 5.9).
 * On 5.4 every syscall goes through the full seccomp filter, so there is
 * nothing to pre-populate. These become no-ops: correct, just marginally
 * slower than 5.9+ which caches the allow bitmask.
 */
#include <linux/version.h>

#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0))

#include <linux/seccomp.h>
#include "infra/seccomp_cache.h"

void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr)
{
    (void)filter;
    (void)nr;
}

void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr)
{
    (void)filter;
    (void)nr;
}

#else
'''

# keep original body for 5.9+
src = stub + src + '\n#endif\n'
open(path, 'w', encoding='utf-8').write(src)
print('  patched: seccomp_cache.c wrapped in 5.9 guard with no-op stubs')
PYEOF5


# --- step 6: manager/pkg_observer.c ---
echo 'LyogdjEyMV9wa2dvYnNfc2hpbTogNS40IGNvbXBhdCBmb3IgdGFza193b3JrIGZsYWdzIGFuZCBmc25vdGlmeV9vcHMgKi8KI2lmIChMSU5VWF9WRVJTSU9OX0NPREUgPCBLRVJORUxfVkVSU0lPTig1LCA4LCAwKSkKc3RhdGljIGlubGluZSBpbnQga3N1X3Rhc2tfd29ya19hZGRfNTQoc3RydWN0IHRhc2tfc3RydWN0ICp0LCBzdHJ1Y3QgY2FsbGJhY2tfaGVhZCAqY2IpCnsKICAgIHJldHVybiB0YXNrX3dvcmtfYWRkKHQsIGNiLCB0cnVlKTsKfQojZWxzZQojZGVmaW5lIGtzdV90YXNrX3dvcmtfYWRkXzU0KHQsIGNiKSB0YXNrX3dvcmtfYWRkKCh0KSwgKGNiKSwgVFdBX1JFU1VNRSkKI2VuZGlmCgojaWYgKExJTlVYX1ZFUlNJT05fQ09ERSA8IEtFUk5FTF9WRVJTSU9OKDUsIDksIDApKQpzdGF0aWMgaW50IGtzdV9oYW5kbGVfZXZlbnRfNTQoc3RydWN0IGZzbm90aWZ5X2dyb3VwICpncm91cCwgc3RydWN0IGlub2RlICppbm9kZSwgdTMyIG1hc2ssCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBjb25zdCB2b2lkICpkYXRhLCBpbnQgZGF0YV90eXBlLCBjb25zdCBzdHJ1Y3QgcXN0ciAqZmlsZV9uYW1lLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgdTMyIGNvb2tpZSwgc3RydWN0IGZzbm90aWZ5X2l0ZXJfaW5mbyAqaXRlcl9pbmZvKTsKI2RlZmluZSBrc3VfRlNOT1RJRllfT1BTX0ZJRUxEIC5oYW5kbGVfZXZlbnQKI2RlZmluZSBrc3VfRlNOT1RJRllfSEFORExFUl81NCBrc3VfaGFuZGxlX2V2ZW50XzU0CiNlbHNlCiNkZWZpbmUga3N1X0ZTTk9USUZZX09QU19GSUVMRCAuaGFuZGxlX2lub2RlX2V2ZW50CiNkZWZpbmUga3N1X0ZTTk9USUZZX0hBTkRMRVJfNTQga3N1X2hhbmRsZV9pbm9kZV9ldmVudAojZW5kaWYK' | base64 -d > /tmp/shim6.txt
echo 'aW1wb3J0IHN5cywgb3MKc3VkaXIgPSBzeXMuYXJndlsxXQpwYXRoID0gb3MucGF0aC5qb2luKHN1ZGlyLCAnbWFuYWdlcicsICdwa2dfb2JzZXJ2ZXIuYycpCmlmIG5vdCBvcy5wYXRoLmV4aXN0cyhwYXRoKToKICAgIHByaW50KCcgIEVSUk9SOiBtYW5hZ2VyL3BrZ19vYnNlcnZlci5jIG5vdCBmb3VuZCcpOyBzeXMuZXhpdCgxKQpzcmMgPSBvcGVuKHBhdGgsIGVuY29kaW5nPSd1dGYtOCcpLnJlYWQoKQppZiAndjEyMV9wa2dvYnNfc2hpbScgaW4gc3JjOgogICAgcHJpbnQoJyAgc2tpcHBlZDogYWxyZWFkeSBwYXRjaGVkJyk7IHN5cy5leGl0KDApCgojIDEpIFRXQV9SRVNVTUUgLT4gc2hpbSAoNS40IHRhc2tfd29ya19hZGQg56ys5LiJ5Y+C5pWw5pivIGJvb2wpCm9sZF90d2EgPSAnaWYgKCF0YXNrX3dvcmtfYWRkKGN1cnJlbnQsIGNiLCBUV0FfUkVTVU1FKSknCmlmIG9sZF90d2EgaW4gc3JjOgogICAgc3JjID0gc3JjLnJlcGxhY2Uob2xkX3R3YSwgJ2lmICgha3N1X3Rhc2tfd29ya19hZGRfNTQoY3VycmVudCwgY2IpKScsIDEpCmVsc2U6CiAgICBwcmludCgnICBFUlJPUjogdGFza193b3JrX2FkZCBhbmNob3Igbm90IGZvdW5kJyk7IHN5cy5leGl0KDEpCgojIDIpIGZzbm90aWZ5X29wcyBoYW5kbGVyIOe7keWumiAtPiDlro/mmKDlsITvvIjlro/ph4zluKbngrnlj7fvvIkKb2xkX29wcyA9ICcgICAgLmhhbmRsZV9pbm9kZV9ldmVudCA9IGtzdV9oYW5kbGVfaW5vZGVfZXZlbnQsJwppZiBvbGRfb3BzIGluIHNyYzoKICAgIHNyYyA9IHNyYy5yZXBsYWNlKG9sZF9vcHMsICcgICAga3N1X0ZTTk9USUZZX09QU19GSUVMRCA9IGtzdV9GU05PVElGWV9IQU5ETEVSXzU0LCcsIDEpCmVsc2U6CiAgICBwcmludCgnICBFUlJPUjogZnNub3RpZnlfb3BzIGFuY2hvciBub3QgZm91bmQnKTsgc3lzLmV4aXQoMSkKCiMgMykgc2hpbSDlv4Xpobvmj5LlnKggTUFTS19TWVNURU0g5LmL5ZCO77yI56ys5LiA5Liq5Ye95pWw5LmL5YmN77yJ77yM5ZCm5YiZ56ysIDQ4IOihjOWJjeWQkeW8leeUqOaKpemUmQpzaGltID0gb3BlbignL3RtcC9zaGltNi50eHQnLCBlbmNvZGluZz0ndXRmLTgnKS5yZWFkKCkKYW5jaG9yID0gJyNkZWZpbmUgTUFTS19TWVNURU0gKEZTX0NSRUFURSB8IEZTX01PVkUgfCBGU19FVkVOVF9PTl9DSElMRClcbicKaWYgYW5jaG9yIG5vdCBpbiBzcmM6CiAgICBwcmludCgnICBFUlJPUjogc2hpbSBhbmNob3Igbm90IGZvdW5kJyk7IHN5cy5leGl0KDEpCnNyYyA9IHNyYy5yZXBsYWNlKGFuY2hvciwgYW5jaG9yICsgJ1xuJyArIHNoaW0gKyAnXG4nLCAxKQoKIyA0KSBrc3VfaGFuZGxlX2V2ZW50XzU0IOeahOWumuS5ieimgeaUvuWcqCBrc3VfaGFuZGxlX2lub2RlX2V2ZW50IOS5i+WQjgpkZWZfZm4gPSAnJycKI2lmIChMSU5VWF9WRVJTSU9OX0NPREUgPCBLRVJORUxfVkVSU0lPTig1LCA5LCAwKSkKc3RhdGljIGludCBrc3VfaGFuZGxlX2V2ZW50XzU0KHN0cnVjdCBmc25vdGlmeV9ncm91cCAqZ3JvdXAsIHN0cnVjdCBpbm9kZSAqaW5vZGUsIHUzMiBtYXNrLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgY29uc3Qgdm9pZCAqZGF0YSwgaW50IGRhdGFfdHlwZSwgY29uc3Qgc3RydWN0IHFzdHIgKmZpbGVfbmFtZSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHUzMiBjb29raWUsIHN0cnVjdCBmc25vdGlmeV9pdGVyX2luZm8gKml0ZXJfaW5mbykKewogICAgKHZvaWQpZ3JvdXA7ICh2b2lkKWRhdGE7ICh2b2lkKWRhdGFfdHlwZTsgKHZvaWQpaXRlcl9pbmZvOwogICAgcmV0dXJuIGtzdV9oYW5kbGVfaW5vZGVfZXZlbnQoTlVMTCwgbWFzaywgaW5vZGUsIE5VTEwsIGZpbGVfbmFtZSwgY29va2llKTsKfQojZW5kaWYKJycnCm9wc19hbmNob3IgPSAnc3RhdGljIGNvbnN0IHN0cnVjdCBmc25vdGlmeV9vcHMga3N1X29wcyA9IHsnCmlmIG9wc19hbmNob3Igbm90IGluIHNyYzoKICAgIHByaW50KCcgIEVSUk9SOiBrc3Vfb3BzIGFuY2hvciBub3QgZm91bmQnKTsgc3lzLmV4aXQoMSkKc3JjID0gc3JjLnJlcGxhY2Uob3BzX2FuY2hvciwgZGVmX2ZuICsgJ1xuJyArIG9wc19hbmNob3IsIDEpCgpvcGVuKHBhdGgsICd3JywgZW5jb2Rpbmc9J3V0Zi04Jykud3JpdGUoc3JjKQpwcmludCgnICBwYXRjaGVkOiBwa2dfb2JzZXJ2ZXIuYyAodGFza193b3JrICsgZnNub3RpZnlfb3BzIHNoaW1zKScpCg==' | base64 -d > /tmp/step6.py
python3 /tmp/step6.py "$SUDIR" || echo "[v121] WARN: step6 failed"
# --- step 7: global TWA_RESUME shim (dynamic_manager/allowlist/supercall) ---
echo 'aW1wb3J0IHN5cywgb3MsIHJlCnN1ZGlyID0gc3lzLmFyZ3ZbMV0KZmlsZXMgPSBbJ21hbmFnZXIvZHluYW1pY19tYW5hZ2VyLmMnLCAncG9saWN5L2FsbG93bGlzdC5jJywgJ3N1cGVyY2FsbC9zdXBlcmNhbGwuYyddCnNoaW1fbWFya2VyID0gJ3YxMjFfdHdhX3Jlc3VtZV9zaGltJwoKc2hpbSA9ICcnJy8qIHYxMjFfdHdhX3Jlc3VtZV9zaGltOiBUV0FfUkVTVU1FIGludHJvZHVjZWQgaW4gNS44OyA1LjQgM3JkIGFyZyBpcyBib29sICovCiNpZiAoTElOVVhfVkVSU0lPTl9DT0RFIDwgS0VSTkVMX1ZFUlNJT04oNSwgOCwgMCkpCiNpZm5kZWYgVFdBX1JFU1VNRQojZGVmaW5lIFRXQV9SRVNVTUUgdHJ1ZQojZW5kaWYKI2VuZGlmCgonJycKCmZvciByZWwgaW4gZmlsZXM6CiAgICBwYXRoID0gb3MucGF0aC5qb2luKHN1ZGlyLCByZWwpCiAgICBpZiBub3Qgb3MucGF0aC5leGlzdHMocGF0aCk6CiAgICAgICAgcHJpbnQoJyAgV0FSTjogbm90IGZvdW5kJywgcmVsKTsgY29udGludWUKICAgIHNyYyA9IG9wZW4ocGF0aCwgZW5jb2Rpbmc9J3V0Zi04JykucmVhZCgpCiAgICBpZiBzaGltX21hcmtlciBpbiBzcmM6CiAgICAgICAgcHJpbnQoJyAgc2tpcHBlZDonLCByZWwpOyBjb250aW51ZQogICAgIyDmj5LlnKjmnIDlkI7kuIDkuKogI2luY2x1ZGUg6KGM5LmL5ZCOCiAgICBsaW5lcyA9IHNyYy5zcGxpdCgnXG4nKQogICAgbGFzdCA9IC0xCiAgICBmb3IgaSwgbG4gaW4gZW51bWVyYXRlKGxpbmVzKToKICAgICAgICBpZiBsbi5zdGFydHN3aXRoKCcjaW5jbHVkZScpOgogICAgICAgICAgICBsYXN0ID0gaQogICAgaWYgbGFzdCA8IDA6CiAgICAgICAgcHJpbnQoJyAgRVJST1I6IG5vIGluY2x1ZGUgaW4nLCByZWwpOyBjb250aW51ZQogICAgbGluZXMuaW5zZXJ0KGxhc3QgKyAxLCBzaGltLnJzdHJpcCgnXG4nKSkKICAgIHNyYyA9ICdcbicuam9pbihsaW5lcykKICAgICMg56Gu5L+d5pyJIHZlcnNpb24uaAogICAgaWYgJyNpbmNsdWRlIDxsaW51eC92ZXJzaW9uLmg+JyBub3QgaW4gc3JjOgogICAgICAgIGZvciBpLCBsbiBpbiBlbnVtZXJhdGUobGluZXMpOgogICAgICAgICAgICBpZiBsbi5zdGFydHN3aXRoKCcjaW5jbHVkZSA8bGludXgvdGFza193b3JrLmg+Jyk6CiAgICAgICAgICAgICAgICBsaW5lcy5pbnNlcnQoaSArIDEsICcjaW5jbHVkZSA8bGludXgvdmVyc2lvbi5oPicpCiAgICAgICAgICAgICAgICBzcmMgPSAnXG4nLmpvaW4obGluZXMpCiAgICAgICAgICAgICAgICBicmVhawogICAgb3BlbihwYXRoLCAndycsIGVuY29kaW5nPSd1dGYtOCcpLndyaXRlKHNyYykKICAgIHByaW50KCcgIHBhdGNoZWQ6JywgcmVsKQo=' | base64 -d > /tmp/step7.py
python3 /tmp/step7.py "$SUDIR" || echo "[v121] WARN: step7 failed"
# --- step 8: policy/app_profile.c seccomp.filter_count (5.9+) ---
echo 'aW1wb3J0IHN5cywgb3MKc3VkaXIgPSBzeXMuYXJndlsxXQpwYXRoID0gb3MucGF0aC5qb2luKHN1ZGlyLCAncG9saWN5JywgJ2FwcF9wcm9maWxlLmMnKQppZiBub3Qgb3MucGF0aC5leGlzdHMocGF0aCk6CiAgICBwcmludCgnICBFUlJPUjogcG9saWN5L2FwcF9wcm9maWxlLmMgbm90IGZvdW5kJyk7IHN5cy5leGl0KDEpCnNyYyA9IG9wZW4ocGF0aCwgZW5jb2Rpbmc9J3V0Zi04JykucmVhZCgpCmlmICd2MTIxX3NlY2NvbXBfZmlsdGVyX2NvdW50JyBpbiBzcmM6CiAgICBwcmludCgnICBza2lwcGVkOiBhcHBfcHJvZmlsZS5jIGFscmVhZHkgcGF0Y2hlZCcpOyBzeXMuZXhpdCgwKQoKb2xkID0gJyAgICBhdG9taWNfc2V0KCZjdXJyZW50LT5zZWNjb21wLmZpbHRlcl9jb3VudCwgMCk7JwppZiBvbGQgbm90IGluIHNyYzoKICAgIHByaW50KCcgIEVSUk9SOiBmaWx0ZXJfY291bnQgYW5jaG9yIG5vdCBmb3VuZCcpOyBzeXMuZXhpdCgxKQpuZXcgPSAoJy8qIHYxMjFfc2VjY29tcF9maWx0ZXJfY291bnQ6IGZpbHRlcl9jb3VudCBhZGRlZCBpbiA1Ljk7IDUuNCBoYXMgb25seSBtb2RlK2ZpbHRlciAqL1xuJwogICAgICAgJyNpZiAoTElOVVhfVkVSU0lPTl9DT0RFID49IEtFUk5FTF9WRVJTSU9OKDUsIDksIDApKVxuJwogICAgICAgJyAgICBhdG9taWNfc2V0KCZjdXJyZW50LT5zZWNjb21wLmZpbHRlcl9jb3VudCwgMCk7XG4nCiAgICAgICAnI2VuZGlmXG4nKQpzcmMgPSBzcmMucmVwbGFjZShvbGQsIG5ldy5yc3RyaXAoJ1xuJyksIDEpCgojIOehruS/neaciSB2ZXJzaW9uLmgKaWYgJyNpbmNsdWRlIDxsaW51eC92ZXJzaW9uLmg+JyBub3QgaW4gc3JjOgogICAgbGluZXMgPSBzcmMuc3BsaXQoJ1xuJykKICAgIGZvciBpLCBsbiBpbiBlbnVtZXJhdGUobGluZXMpOgogICAgICAgIGlmIGxuLnN0YXJ0c3dpdGgoJyNpbmNsdWRlIDxsaW51eC8nKToKICAgICAgICAgICAgbGFzdCA9IGkKICAgIGxpbmVzLmluc2VydChsYXN0ICsgMSwgJyNpbmNsdWRlIDxsaW51eC92ZXJzaW9uLmg+JykKICAgIHNyYyA9ICdcbicuam9pbihsaW5lcykKCm9wZW4ocGF0aCwgJ3cnLCBlbmNvZGluZz0ndXRmLTgnKS53cml0ZShzcmMpCnByaW50KCcgIHBhdGNoZWQ6IGFwcF9wcm9maWxlLmMgKHNlY2NvbXAuZmlsdGVyX2NvdW50IGd1YXJkZWQpJykK' | base64 -d > /tmp/step8.py
python3 /tmp/step8.py "$SUDIR" || echo "[v121] WARN: step8 failed"
echo "=== [v121] result ==="
grep -n 'v121_force_no_preinit\|KSU_NO_PREINIT' "$SUDIR/Kbuild" | head -3
grep -n 'v121:\|v121_strncpy\|ksu_strncpy_from_user_nofault' "$SUDIR/feature/sucompat.c" | head -8
grep -n 'v121_seccomp_stub' "$SUDIR/infra/seccomp_cache.c" | head -2
grep -n 'v121_minmax_shim' "$SUDIR/sulog/event.c" | head -2
grep -n 'v121_seccomp_filter_count' "$SUDIR/policy/app_profile.c" 2>/dev/null | head -3
grep -n 'v121_twa_resume_shim' "$SUDIR/manager/dynamic_manager.c" "$SUDIR/policy/allowlist.c" "$SUDIR/supercall/supercall.c" 2>/dev/null | head -6
grep -n 'v121_pkgobs_shim\|ksu_task_work_add_54\|ksu_FSNOTIFY' "$SUDIR/manager/pkg_observer.c" | head -6
grep -n 'v121_patchmem_shim\|ksu_p4d_to_phys_54\|ksu_copy_to_kernel_nofault' "$SUDIR/hook/arm64/patch_memory.c" | head -6
echo "=== [v121] done ==="
