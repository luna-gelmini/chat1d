#!/usr/bin/env python3
import base64
import hashlib
import pathlib
import sys

Q = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, Q - 2, Q)) % Q
I = pow(2, (Q - 1) // 4, Q)
B_Y = (4 * pow(5, Q - 2, Q)) % Q


def modp_inv(x: int) -> int:
    return pow(x, Q - 2, Q)


def xrecover(y: int) -> int:
    xx = (y * y - 1) * modp_inv(D * y * y + 1)
    x = pow(xx, (Q + 3) // 8, Q)
    if (x * x - xx) % Q != 0:
        x = (x * I) % Q
    if x % 2 != 0:
        x = Q - x
    return x


B_X = xrecover(B_Y)
B = (B_X, B_Y)
IDENTITY = (0, 1)


def point_eq(p, q) -> bool:
    return p[0] == q[0] and p[1] == q[1]


def is_strict_public_point(p) -> bool:
    return (not point_eq(p, IDENTITY)) and point_eq(scalar_mult(p, L), IDENTITY)


def is_signature_point(p) -> bool:
    return point_eq(scalar_mult(p, L), IDENTITY)


def point_add(p, q):
    x1, y1 = p
    x2, y2 = q
    denom_x = modp_inv((1 + D * x1 * x2 * y1 * y2) % Q)
    denom_y = modp_inv((1 - D * x1 * x2 * y1 * y2) % Q)
    x3 = ((x1 * y2 + x2 * y1) * denom_x) % Q
    y3 = ((y1 * y2 + x1 * x2) * denom_y) % Q
    return (x3, y3)


def scalar_mult(p, e: int):
    if e == 0:
        return IDENTITY
    q = scalar_mult(p, e // 2)
    q = point_add(q, q)
    if e & 1:
        q = point_add(q, p)
    return q


def point_encode(p) -> bytes:
    x, y = p
    bits = y | ((x & 1) << 255)
    return bits.to_bytes(32, 'little')


def point_decode(s: bytes):
    if len(s) != 32:
        raise ValueError('bad-point-length')
    y = int.from_bytes(s, 'little') & ((1 << 255) - 1)
    sign = (s[31] >> 7) & 1
    if y >= Q:
        raise ValueError('bad-point-y')
    x = xrecover(y)
    if (x & 1) != sign:
        x = Q - x
    p = (x, y)
    if point_encode(p) != s:
        raise ValueError('bad-point-encoding')
    return p


def sha512_mod_l(data: bytes) -> int:
    return int.from_bytes(hashlib.sha512(data).digest(), 'little') % L


def secret_expand(seed: bytes):
    if len(seed) != 32:
        raise ValueError('bad-seed-length')
    h = bytearray(hashlib.sha512(seed).digest())
    h[0] &= 248
    h[31] &= 63
    h[31] |= 64
    a = int.from_bytes(h[:32], 'little')
    prefix = bytes(h[32:])
    return a, prefix


def public_from_seed(seed: bytes) -> bytes:
    a, _ = secret_expand(seed)
    return point_encode(scalar_mult(B, a))


def sign(seed: bytes, message: bytes) -> bytes:
    a, prefix = secret_expand(seed)
    public = point_encode(scalar_mult(B, a))
    r = sha512_mod_l(prefix + message)
    r_point = scalar_mult(B, r)
    r_enc = point_encode(r_point)
    h = sha512_mod_l(r_enc + public + message)
    s = (r + h * a) % L
    return r_enc + s.to_bytes(32, 'little')


def verify(public: bytes, message: bytes, signature: bytes) -> bool:
    if len(public) != 32 or len(signature) != 64:
        return False
    try:
        a_point = point_decode(public)
        r_point = point_decode(signature[:32])
    except ValueError:
        return False
    if not is_strict_public_point(a_point):
        return False
    if not is_signature_point(r_point):
        return False
    s = int.from_bytes(signature[32:], 'little')
    if s >= L:
        return False
    h = sha512_mod_l(signature[:32] + public + message)
    left = scalar_mult(B, s)
    right = point_add(r_point, scalar_mult(a_point, h))
    return point_eq(left, right)


def b64url_decode(text: str) -> bytes:
    if '=' in text:
        raise ValueError('padded-base64url-not-allowed')
    padding = '=' * ((4 - len(text) % 4) % 4)
    return base64.urlsafe_b64decode(text + padding)


def b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode('ascii').rstrip('=')


def cmd_sha256_file(inp: str, out: str):
    data = pathlib.Path(inp).read_bytes()
    pathlib.Path(out).write_text(hashlib.sha256(data).hexdigest() + '\n', encoding='utf-8')


def cmd_sha256_b64url(value: str, out: str):
    data = b64url_decode(value)
    pathlib.Path(out).write_text(hashlib.sha256(data).hexdigest() + '\n', encoding='utf-8')


def cmd_verify_ed25519(pubkey_b64: str, sig_b64: str, message_file: str, out: str):
    public = b64url_decode(pubkey_b64)
    signature = b64url_decode(sig_b64)
    message = pathlib.Path(message_file).read_bytes()
    ok = verify(public, message, signature)
    pathlib.Path(out).write_text('OK\n' if ok else 'FAIL\n', encoding='utf-8')


def cmd_public_from_seed(seed_hex: str, out: str):
    seed = bytes.fromhex(seed_hex)
    public = public_from_seed(seed)
    pathlib.Path(out).write_text(b64url_encode(public) + '\n', encoding='utf-8')


def cmd_sign(seed_hex: str, message_file: str, out: str):
    seed = bytes.fromhex(seed_hex)
    message = pathlib.Path(message_file).read_bytes()
    sig = sign(seed, message)
    pathlib.Path(out).write_text(b64url_encode(sig) + '\n', encoding='utf-8')


def cmd_selftest(out: str):
    seed = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
    expected_public = bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
    expected_sig = bytes.fromhex(
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b'
    )
    public = public_from_seed(seed)
    sig = sign(seed, b'')
    forged_public = point_encode(IDENTITY)
    forged_signature = point_encode(scalar_mult(B, 1)) + (1).to_bytes(32, 'little')
    forged_ok = verify(forged_public, b'msg\n#forge\n00\n1\nYQ\n', forged_signature)
    ok = public == expected_public and sig == expected_sig and verify(public, b'', sig) and (not forged_ok)
    pathlib.Path(out).write_text('OK\n' if ok else 'FAIL\n', encoding='utf-8')


def main(argv):
    if len(argv) < 2:
        raise SystemExit('usage: chat1_crypto_backend.py <command> ...')
    cmd = argv[1]
    if cmd == 'sha256-file' and len(argv) == 4:
        cmd_sha256_file(argv[2], argv[3])
    elif cmd == 'sha256-b64url' and len(argv) == 4:
        cmd_sha256_b64url(argv[2], argv[3])
    elif cmd == 'verify-ed25519' and len(argv) == 6:
        cmd_verify_ed25519(argv[2], argv[3], argv[4], argv[5])
    elif cmd == 'public-from-seed' and len(argv) == 4:
        cmd_public_from_seed(argv[2], argv[3])
    elif cmd == 'sign' and len(argv) == 5:
        cmd_sign(argv[2], argv[3], argv[4])
    elif cmd == 'selftest' and len(argv) == 3:
        cmd_selftest(argv[2])
    else:
        raise SystemExit('bad-args')


if __name__ == '__main__':
    main(sys.argv)
