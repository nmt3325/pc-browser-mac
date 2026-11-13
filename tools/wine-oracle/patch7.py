#!/usr/bin/env python3
"""patch7.py <hook.c>: on top of patch6, remember the last card reads (sector, first 0x60 bytes, 0x1b0..0x1cf) and
append them, together with the stack-frame bytes of the caller, to every AT record of hook.log (see atl2.py)."""
import sys
p=sys.argv[1]
s=open(p).read()
old="    return real_ReadFile(h, buf, n, got, ov);\n}\n"
assert old in s, 'readfile tail'
new='''    {
        BOOL rr = real_ReadFile(h, buf, n, got, ov);
        if (is_ours(h) && n >= 512 && rr) {
            u32 idx = g_rn & 7, i;
            g_rs[idx] = g_lastpos;
            for (i = 0; i < 0x60; i++) g_rb[idx][i] = ((u8 *)buf)[i];
            for (i = 0; i < 0x20; i++) g_rx[idx][i] = ((u8 *)buf)[0x1b0 + i];
            g_rn++;
        }
        return rr;
    }
}
'''
s=s.replace(old,new,1)
anchor="static BOOL WINAPI my_ReadFile("
assert anchor in s, 'anchor'
s=s.replace(anchor,"static u32 g_rs[8], g_rn, g_lastpos; static u8 g_rb[8][0x60], g_rx[8][0x20];\n"+anchor,1)
old2="        g_nreads++;\n        lw(\"R \");"
assert old2 in s, 'old2'
s=s.replace(old2,"        g_nreads++; g_lastpos = (u32)(pos >> 9);\n        lw(\"R \");",1)
old3="    for (k = 0; k < 8; k++) {\n"
assert old3 in s, 'old3'
new3='''    { u32 j, q; for (j = 0; j < 4; j++) { u32 idx = (g_rn - 1 - j) & 7; lw("  LR sec="); lh(g_rs[idx]); lw("d: "); lb((u32)g_rb[idx], 0x60); lw("| x: "); lb((u32)g_rx[idx], 0x20); lw("\\n"); }
      lw("  F: "); for (q = 0x3b0; q >= 0x2c0; q -= 12) { u32 pp = rdp(ebp - q); lh(rdb(pp)); } lw("\\n"); }
'''
s=s.replace(old3,new3+old3,1)
open(p,'w').write(s)
print('patched7')
