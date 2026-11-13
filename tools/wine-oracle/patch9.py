#!/usr/bin/env python3
"""patch9.py <hook.c>: (apply after patch8) log the control traffic of the settings dialog ("DM" lines).
The original is an ANSI MFC application, so the dialog talks to its controls through SendMessageA, SendDlgItemMessageA,
GetWindowTextA, SetWindowTextA, SetDlgItemTextA, IsDlgButtonChecked and CheckDlgButton. For every call on a control whose ID
is in 20000..21999 (the recording-settings dialog) the hook logs `DM <ctrl id> <msg> <wparam> <result> <lparam | T text>`:
combo-box item lists (CB_ADDSTRING), the index read back when the user presses Save (CB_GETCURSEL), check boxes
(BM_GETCHECK) and slider positions (TBM_GETPOS)."""
import sys
p = sys.argv[1]
s = open(p).read()


def rep(old, new):
    global s
    assert s.count(old) >= 1, 'anchor missing: ' + old[:60]
    s = s.replace(old, new, 1)


logger = r'''static int (WINAPI *real_GetDlgCtrlID)(void *);
static u32 (WINAPI *real_SDIMA)(void *, int, u32, u32, u32);
static u32 (WINAPI *real_GWTA)(void *, char *, int);
static BOOL (WINAPI *real_SWTA)(void *, const char *);
static BOOL (WINAPI *real_SDITA)(void *, int, const char *);
static u32 (WINAPI *real_IDBC)(void *, int);
static BOOL (WINAPI *real_CDB)(void *, int, u32);
static void dlg_text(const u8 *t, int wide, u32 max) {
    u32 i;
    if (!t || real_IsBadReadPtr((void *)t, wide ? 2 : 1)) { lw("-"); return; }
    for (i = 0; i < max; i++) {
        u32 c = wide ? ((const u16 *)t)[i] : t[i];
        if (!c) break;
        lh(c);
    }
}
static void dlg_log2(u32 id, u32 msg, u32 wp, u32 lp, u32 r, int wide) {
    switch (msg) {
    case 0x143: case 0x14A: case 0x14B: case 0x14E: case 0x147: case 0x148: case 0x14C: case 0x14D: case 0x158: case 0x159:
    case 0xF0: case 0xF1: case 0x400: case 0x401: case 0x402: case 0x405: case 0x406: case 0x407: case 0x408:
    case 0xC: case 0xD: case 0xE: case 0x1001: case 0x1002:
        break;
    default: return;
    }
    if (id < 20000 || id >= 22000) return;
    lw("DM "); lh(id); lh(msg); lh(wp); lh(r);
    if (msg == 0x143 || msg == 0x14A || msg == 0xC || msg == 0x14C || msg == 0x14D || msg == 0x158 || msg == 0x148 || msg == 0xD) {
        lw("T "); dlg_text((const u8 *)lp, wide, 40);
    } else lh(lp);
    lw("\n");
}
static void dlg_log(void *hwnd, u32 msg, u32 wp, u32 lp, u32 r, int wide) {
    if (!real_GetDlgCtrlID) return;
    dlg_log2((u32)real_GetDlgCtrlID(hwnd), msg, wp, lp, r, wide);
}
static u32 WINAPI my_SDIMA(void *dlg, int id, u32 msg, u32 wp, u32 lp) { u32 r = real_SDIMA(dlg, id, msg, wp, lp); dlg_log2((u32)id, msg, wp, lp, r, 0); return r; }
static u32 WINAPI my_GWTA(void *h, char *buf, int n) { u32 r = real_GWTA(h, buf, n); dlg_log(h, 0xD, (u32)n, (u32)buf, r, 0); return r; }
static BOOL WINAPI my_SWTA(void *h, const char *t) { BOOL r = real_SWTA(h, t); dlg_log(h, 0xC, 0, (u32)t, (u32)r, 0); return r; }
static BOOL WINAPI my_SDITA(void *dlg, int id, const char *t) { BOOL r = real_SDITA(dlg, id, t); dlg_log2((u32)id, 0xC, 0, (u32)t, (u32)r, 0); return r; }
static u32 WINAPI my_IDBC(void *dlg, int id) { u32 r = real_IDBC(dlg, id); dlg_log2((u32)id, 0xF0, 0, 0, r, 0); return r; }
static BOOL WINAPI my_CDB(void *dlg, int id, u32 chk) { BOOL r = real_CDB(dlg, id, chk); dlg_log2((u32)id, 0xF1, chk, 0, (u32)r, 0); return r; }
'''
rep('static u32 WINAPI my_SendMessageW(', logger + 'static u32 WINAPI my_SendMessageW(')
rep('    return real_SendMessageW(hwnd, msg, wp, lp);\n}', '    { u32 r = real_SendMessageW(hwnd, msg, wp, lp); dlg_log(hwnd, msg, wp, lp, r, 1); return r; }\n}')
rep('    return real_SendMessageA(hwnd, msg, wp, lp);\n}', '    { u32 r = real_SendMessageA(hwnd, msg, wp, lp); dlg_log(hwnd, msg, wp, lp, r, 0); return r; }\n}')
rep('                    else if (eqa(fn, "SendMessageA")) real_SendMessageA = (void *)*slot;\n',
    '                    else if (eqa(fn, "SendMessageA")) real_SendMessageA = (void *)*slot;\n'
    '                    else if (eqa(fn, "SendDlgItemMessageA")) real_SDIMA = (void *)*slot;\n'
    '                    else if (eqa(fn, "GetWindowTextA")) real_GWTA = (void *)*slot;\n'
    '                    else if (eqa(fn, "SetWindowTextA")) real_SWTA = (void *)*slot;\n'
    '                    else if (eqa(fn, "SetDlgItemTextA")) real_SDITA = (void *)*slot;\n'
    '                    else if (eqa(fn, "IsDlgButtonChecked")) real_IDBC = (void *)*slot;\n'
    '                    else if (eqa(fn, "CheckDlgButton")) real_CDB = (void *)*slot;\n'
    '                    else if (eqa(fn, "GetDlgCtrlID")) real_GetDlgCtrlID = (void *)*slot;\n')
rep('                    else if (eqa(fn, "SendMessageA") && real_SendMessageA) patch(slot, (void *)my_SendMessageA);\n',
    '                    else if (eqa(fn, "SendMessageA") && real_SendMessageA) patch(slot, (void *)my_SendMessageA);\n'
    '                    else if (eqa(fn, "SendDlgItemMessageA") && real_SDIMA) patch(slot, (void *)my_SDIMA);\n'
    '                    else if (eqa(fn, "GetWindowTextA") && real_GWTA) patch(slot, (void *)my_GWTA);\n'
    '                    else if (eqa(fn, "SetWindowTextA") && real_SWTA) patch(slot, (void *)my_SWTA);\n'
    '                    else if (eqa(fn, "SetDlgItemTextA") && real_SDITA) patch(slot, (void *)my_SDITA);\n'
    '                    else if (eqa(fn, "IsDlgButtonChecked") && real_IDBC) patch(slot, (void *)my_IDBC);\n'
    '                    else if (eqa(fn, "CheckDlgButton") && real_CDB) patch(slot, (void *)my_CDB);\n')
open(p, 'w').write(s)
print('patched9')
