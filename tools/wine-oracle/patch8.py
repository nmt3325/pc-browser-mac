#!/usr/bin/env python3
"""patch8.py <hook.c> [<windows path of the volume copy>]: on top of the base hook, present `\\\\.\\E:` as a
*volume* (a separate scratch copy of the FAT partition, volume-relative sector numbers, disk-extent StartingOffset =
first partition sector) and `\\\\.\\PHYSICALDRIVE*` as the whole image, and log every WriteFile on those handles
("WV" = volume copy, "WP" = physical image; "WS" = candidate return addresses of the writer). Writes to the physical image are logged and *swallowed*; only the scratch
volume copy can change. Without this the original sees an MBR at sector 0 of the volume and never writes settings."""
import sys
p = sys.argv[1]
part = sys.argv[2] if len(sys.argv) > 2 else r'Z:\tmp\wine-try\part.img'
s = open(p).read()


def rep(old, new, count=1):
    global s
    assert s.count(old) >= 1, 'anchor missing: ' + old[:60]
    s = s.replace(old, new, count)


# 1. volume copy path and per-handle flag
i = s.index('#define IMG ')
j = s.index('\n', i) + 1
s = s[:j] + '#define PART L"' + part.replace('\\', '\\\\') + '" /* scratch copy of the FAT partition (analysis only) */\n' + s[j:]
rep('static u32 g_nours;\n', 'static u32 g_nours;\nstatic u8 g_vol[64];\n')
rep('static int is_ours(HANDLE h) {',
    'static int is_vol(HANDLE h) { u32 i; for (i = 0; i < g_nours; i++) if (g_ours[i] == h) return g_vol[i]; return 0; }\n'
    'static int is_ours(HANDLE h) {')

# 2. CreateFileW / CreateFileA
rep('    int red = match_dev(name);\n    HANDLE h;\n',
    '    int red = match_dev(name);\n    int isvol = red && !ipfx_w(name, "\\\\\\\\.\\\\PHYSICALDRIVE");\n    HANDLE h;\n')
rep('if (red) { name = (const u16 *)IMG; share = 7; flags &= ~0x20000000u; }',
    'if (red) { name = isvol ? (const u16 *)PART : (const u16 *)IMG; share = 7; flags &= ~0x20000000u; }')
rep('if (red && h != (HANDLE)-1 && g_nours < 64) { g_ours[g_nours++] = h; lw("REDIRECTED"); }\n    lw("\\n");\n    return h;\n}\n\nstatic HANDLE WINAPI my_CreateFileA',
    'if (red && h != (HANDLE)-1 && g_nours < 64) { { u32 k; for (k = 0; k < g_nours && g_ours[k] != h; k++); g_vol[k] = (u8)isvol; g_ours[k] = h; if (k == g_nours) g_nours++; } lw(isvol ? "REDIRECTED-VOL" : "REDIRECTED"); }\n    lw("\\n");\n    return h;\n}\n\nstatic HANDLE WINAPI my_CreateFileA')
rep('    int red = name && (ieqa(name, "\\\\\\\\.\\\\E:") || ipfx_a(name, "\\\\\\\\.\\\\PHYSICALDRIVE"));\n',
    '    int red = name && (ieqa(name, "\\\\\\\\.\\\\E:") || ipfx_a(name, "\\\\\\\\.\\\\PHYSICALDRIVE"));\n    int isvol = name && ieqa(name, "\\\\\\\\.\\\\E:");\n')
rep('h = real_CreateFileW((const u16 *)IMG, acc, 7, sa, disp, flags & ~0x20000000u, tmpl);',
    'h = real_CreateFileW(isvol ? (const u16 *)PART : (const u16 *)IMG, acc, 7, sa, disp, flags & ~0x20000000u, tmpl);')
rep('    if (red && h != (HANDLE)-1 && g_nours < 64) { g_ours[g_nours++] = h; lw("REDIRECTED"); }\n    lw("\\n");\n    return h;\n}\n\nstatic BOOL WINAPI my_DeviceIoControl',
    '    if (red && h != (HANDLE)-1 && g_nours < 64) { { u32 k; for (k = 0; k < g_nours && g_ours[k] != h; k++); g_vol[k] = (u8)isvol; g_ours[k] = h; if (k == g_nours) g_nours++; } lw(isvol ? "REDIRECTED-VOL" : "REDIRECTED"); }\n    lw("\\n");\n    return h;\n}\n\nstatic BOOL WINAPI my_DeviceIoControl')

# 3. volume extents: StartingOffset of the partition
rep('*(u64 *)(o + 16) = 0; *(u64 *)(o + 24) = size;', '*(u64 *)(o + 16) = is_vol(h) ? 32256ull : 0ull; *(u64 *)(o + 24) = size;')

# 4. read log distinguishes volume reads; new WriteFile hook
rep('lw("R "); lh((u32)(pos >> 9));', 'lw(is_vol(h) ? "RV " : "R "); lh((u32)(pos >> 9));')
wf = '''static BOOL WINAPI my_WriteFile(HANDLE h, const void *buf, u32 n, u32 *wr, void *ov) {
    if (is_ours(h)) {
        static const char HX[] = "0123456789abcdef";
        u64 pos = 0; int v = is_vol(h); u32 i;
        if (ov) pos = (u64)*(u32 *)((u8 *)ov + 8) | ((u64)*(u32 *)((u8 *)ov + 12) << 32);
        else { long long cur = 0; real_SetFilePointerEx(h, 0, &cur, 1); pos = (u64)cur; }
        lw(v ? "WV " : "WP "); lh((u32)(pos >> 9)); lh((u32)(pos & 511)); lh(n); lw("| ");
        for (i = 0; i < 1024 && i < n; i++) { char b[3]; b[0] = HX[((u8 *)buf)[i] >> 4]; b[1] = HX[((u8 *)buf)[i] & 15]; b[2] = 0; lw(b); }
        lw("\\n");
        { /* WS: return-address candidates (exe text, preceded by a call) of the writer, to locate the serialiser */
            volatile u32 *sp; u32 top, k, cnt = 0, lo = 0x401000, hi;
            __asm__ volatile("movl %%esp, %0" : "=r"(sp));
            __asm__("movl %%fs:4, %0" : "=r"(top));
            hi = 0x400000 + *(u32 *)(0x400000 + *(u32 *)(0x40003c) + 0x50);
            lw("WR "); for (k = 0; k < 64 && (u32)(sp + k) < top; k++) lh(sp[k]); lw("\\n");
            lw("WS ");
            for (k = 0; (u32)(sp + k) < top && k < 8192 && cnt < 24; k++) {
                u32 a = sp[k];
                if (a > lo + 8 && a < hi) {
                    u8 *c = (u8 *)a;
                    if (c[-5] == 0xE8 || (c[-6] == 0xFF && c[-5] == 0x15) || c[-2] == 0xFF || c[-3] == 0xFF) { lh(a); cnt++; }
                }
            }
            lw("\\n");
        }
        if (!v) { if (wr) *wr = n; return 1; }
    }
    return real_WriteFile(h, buf, n, wr, ov);
}

'''
rep('static void *WINAPI my_GetProcAddress(', wf + 'static void *WINAPI my_GetProcAddress(')
rep('        if (eqa(name, "ReadFile")) { real_ReadFile = p; return (void *)my_ReadFile; }\n',
    '        if (eqa(name, "ReadFile")) { real_ReadFile = p; return (void *)my_ReadFile; }\n        if (eqa(name, "WriteFile")) return (void *)my_WriteFile;\n')
rep('                    else if (eqa(fn, "ReadFile")) patch(slot, (void *)my_ReadFile);\n',
    '                    else if (eqa(fn, "ReadFile")) patch(slot, (void *)my_ReadFile);\n                    else if (eqa(fn, "WriteFile")) patch(slot, (void *)my_WriteFile);\n')
open(p, 'w').write(s)
print('patched8')
