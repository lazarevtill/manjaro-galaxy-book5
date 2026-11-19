"""Verify a PAM service's stack loads and password auth still works.

Written because pamtester is not packaged here and changing PAM without a way to
test it is how people lock themselves out. Uses libpam directly via ctypes.
Password auth is checked with a deliberately WRONG password: a correct-password
test would need the real one, but a wrong password must return
PAM_AUTH_ERR (7) -- and crucially, NOT a config error (6 = PAM_SERVICE_ERR,
which is what a broken stack returns). That distinguishes 'stack works, password
rejected' from 'stack is broken'.
"""
import ctypes, ctypes.util, sys

libpam = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0")
# PAM takes ownership of the response array and frees it with free(), so it must
# come from malloc -- a Python-allocated buffer gives "free(): invalid size" and
# a core dump right after pam_authenticate returns.
libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
libc.malloc.restype = ctypes.c_void_p
libc.malloc.argtypes = [ctypes.c_size_t]
libc.strdup.restype = ctypes.c_void_p
libc.strdup.argtypes = [ctypes.c_char_p]

class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]
class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_char_p), ("resp_retcode", ctypes.c_int)]
CONV = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int,
                        ctypes.POINTER(ctypes.POINTER(PamMessage)),
                        ctypes.POINTER(ctypes.POINTER(PamResponse)), ctypes.c_void_p)
class PamConv(ctypes.Structure):
    _fields_ = [("conv", CONV), ("appdata_ptr", ctypes.c_void_p)]

libpam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                             ctypes.POINTER(PamConv), ctypes.POINTER(ctypes.c_void_p)]
libpam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
libpam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
libpam.pam_strerror.argtypes = [ctypes.c_void_p, ctypes.c_int]
libpam.pam_strerror.restype = ctypes.c_char_p

PROMPTS = []
import time as _t
_T0 = [None]

def check(service, user, password):
    del PROMPTS[:]
    @CONV
    def conv(n, msgs, resp, _):
        buf = libc.malloc(ctypes.sizeof(PamResponse) * n)
        arr = ctypes.cast(buf, ctypes.POINTER(PamResponse))
        for i in range(n):
            m = msgs[i].contents
            if _T0[0] is None: _T0[0] = _t.time()
            PROMPTS.append((m.msg_style, (m.msg or b"").decode(errors="replace"),
                            _t.time() - _T0[0]))
            # 1 = PAM_PROMPT_ECHO_OFF (password), 2 = PAM_PROMPT_ECHO_ON
            if m.msg_style in (1, 2):
                arr[i].resp = ctypes.cast(libc.strdup(password.encode()), ctypes.c_char_p)
            else:
                arr[i].resp = None
            arr[i].resp_retcode = 0
        resp[0] = arr
        return 0
    h = ctypes.c_void_p()
    c = PamConv(conv, None)
    rc = libpam.pam_start(service.encode(), user.encode(), ctypes.byref(c), ctypes.byref(h))
    if rc != 0:
        return rc, "pam_start failed"
    rc = libpam.pam_authenticate(h, 0)
    msg = libpam.pam_strerror(h, rc).decode()
    libpam.pam_end(h, rc)
    return rc, msg

if __name__ == "__main__":
    svc, user = sys.argv[1], sys.argv[2]
    rc, msg = check(svc, user, "deliberately-wrong-password-for-testing")
    verdict = {6: "\033[31mSTACK BROKEN (PAM_SERVICE_ERR)\033[0m",
               7: "\033[32mstack OK\033[0m (wrong password correctly rejected)",
               0: "\033[31mUNEXPECTED SUCCESS with a wrong password\033[0m"}.get(
                   rc, f"rc={rc} ({msg})")
    print(f"  {svc:<10} rc={rc:<3} {verdict}")
    for style, text, dt in PROMPTS:
        if text.strip():
            print(f"      t+{dt:5.1f}s  {text.strip()[:64]}")
