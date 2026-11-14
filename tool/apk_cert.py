"""Print the SHA-256 of the first signer certificate in an APK's v2/v3
signing block (keytool reads only v1 JAR signatures; apksigner is absent).
usage: python3 tool/apk_cert.py file.apk   (the release key prints
2a4b4625895e700839415a81c091d949699167abe03c22794376d18f2f7ec2d2)"""
import hashlib, struct, sys

data = open(sys.argv[1], 'rb').read()
# End of central directory -> start of central directory.
eocd = data.rfind(b'PK\x05\x06')
cd_off = struct.unpack('<I', data[eocd + 16:eocd + 20])[0]
magic = data[cd_off - 16:cd_off]
assert magic == b'APK Sig Block 42', 'no APK signing block'
size = struct.unpack('<Q', data[cd_off - 24:cd_off - 16])[0]
block = data[cd_off - size - 8:cd_off - 24]
pos = 8
while pos < len(block):
    ln = struct.unpack('<Q', block[pos:pos + 8])[0]
    bid = struct.unpack('<I', block[pos + 8:pos + 12])[0]
    val = block[pos + 12:pos + 8 + ln]
    pos += 8 + ln
    if bid not in (0x7109871a, 0xf05368c0):   # v2, v3
        continue
    def lp(b, o):
        n = struct.unpack('<I', b[o:o + 4])[0]
        return b[o + 4:o + 4 + n], o + 4 + n
    signers, _ = lp(val, 0)
    signer, _ = lp(signers, 0)
    signed, _ = lp(signer, 0)
    _digests, o = lp(signed, 0)
    certs, _ = lp(signed, o)
    cert, _ = lp(certs, 0)
    print(('v2' if bid == 0x7109871a else 'v3'), hashlib.sha256(cert).hexdigest())
    break
