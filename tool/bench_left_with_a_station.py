#!/usr/bin/env python3
"""
bench_left_with_a_station.py -- the prime use case, on real hardware, over
Bluetooth only (spec/USECASES.md 10, docs/store-and-forward.md 5.5).

    A writes a chat message to B while B is away. A station that heard it
    keeps it. A leaves. B comes within Bluetooth reach of that station and
    gets the message without doing anything, once. A comes back and gets the
    "delivered" receipt from whichever station kept it.

Every scenario runs that loop and checks five things:

    sent       A put the message on the air
    delivered  B received it after A had left -- so a station, not A, handed it over
    once       B shows it once, however many stations repeat it
    receipt    A learns it was delivered after coming back

Devices (all on the Pi's USB):

    phone:<adb serial>[:<local port>]   the XPRS app, remote API on (Settings >
                                        Developer); the script forwards the port
    board:<serial by-id path>           an ESP32 station (USB-JTAG console)

"Away" is the device's Bluetooth off: `svc bluetooth disable` on a phone,
`cfg set ble_on 0` + restart on a board (opening a board's console restarts
it, which is also how the setting applies). Phones are put on Bluetooth only
first (Wi-Fi and mobile data off, bearers only:ble5) so a pass is a Bluetooth
pass, and boards get ESP-NOW off. The script restores nothing it did not
change and prints what it changed.

Run it with a Python that has pyserial (the PlatformIO one on the Pi):

    ~/.platformio/penv/bin/python3 tool/bench_left_with_a_station.py \\
        --phone C61000000004616 --phone TANK200000007933 \\
        --board /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_48:CA:43:4B:B7:C4-if00 \\
        --board /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_AC:27:6E:74:0C:FC-if00

With two phones and two boards it runs, in order:

    1. phone -> phone, a board in the middle   (the case people live)
    2. phone -> board, a board in the middle
    3. phone -> board, the other phone in the middle (the boards that are not
       the recipient stay away, so only the phone can carry it)

A missing kind of device skips the scenarios that need it. Exit status 0 only
when every scenario that ran passed. Takes about 7 minutes a scenario.
"""
import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request

try:
    import serial  # pyserial
except ImportError:
    sys.exit("needs pyserial: run with ~/.platformio/penv/bin/python3")

AIRINGS_S = 75        # the writer's three airings (0, +20, +40 s) and a margin
DELIVER_S = 300       # how long B may take once back in reach
RECEIPT_S = 300       # how long A may take to learn it, once back
BOOT_S = 12           # a board's console session: restart and boot


def log(msg):
    print(time.strftime('%H:%M:%S'), msg, flush=True)


# ── phones ──────────────────────────────────────────────────────────────────

class Phone:
    def __init__(self, spec, port):
        parts = spec.split(':')
        self.serial = parts[0]
        self.port = int(parts[1]) if len(parts) > 1 else port
        self.kind = 'phone'
        subprocess.run(['adb', '-s', self.serial, 'forward', f'tcp:{self.port}',
                        'tcp:3456'], check=True, capture_output=True)
        self.call = self.api('GET', '/api/status').get('callsign', '?')

    def __str__(self):
        return f'phone {self.call}'

    def api(self, method, path, body=None):
        req = urllib.request.Request(f'http://127.0.0.1:{self.port}{path}',
                                     method=method)
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            req.add_header('content-type', 'application/json')
        with urllib.request.urlopen(req, data=data, timeout=15) as r:
            return json.loads(r.read() or b'{}')

    def adb(self, *args):
        return subprocess.run(['adb', '-s', self.serial, 'shell', *args],
                              capture_output=True, text=True).stdout

    def bluetooth_only(self):
        self.adb('svc', 'wifi', 'disable')
        self.adb('svc', 'data', 'disable')
        self.api('POST', '/api/xprs/bearers', {'only': ['ble5']})
        log(f'{self}: Wi-Fi and data off, sends on ble5 only')

    def away(self):
        self.adb('svc', 'bluetooth', 'disable')

    def back(self):
        self.adb('svc', 'bluetooth', 'enable')

    def lines(self, n=3000):
        d = self.api('GET', f'/api/log?n={n}')
        return [str(x) for x in (d.get('lines', d) if isinstance(d, dict) else d)]

    def send(self, to, text):
        r = self.api('POST', '/api/xprs/send',
                     {'type': 'message', 'd': to, 'm': text})
        if not r.get('ok'):
            raise RuntimeError(f'{self}: send refused: {r}')
        return r['wire']

    def rows(self, mid, writer):
        """The recipient's archive rows for the message: the one copy Chat
        shows. Keyed by identifier, so a repeat is counted in `heard`, never
        as a second row."""
        d = self.api('GET', f'/api/xprs/history?only={writer}&limit=300')
        return [r for r in d.get('rows', []) if r.get('id') == mid]

    def learned(self, mid):
        return [l for l in self.lines(800)
                if f'{mid} is delivered' in l or f'{mid} is read' in l]


# ── boards ──────────────────────────────────────────────────────────────────

class Board:
    def __init__(self, path):
        self.path = path
        self.kind = 'board'
        out = self.console([], BOOT_S)
        m = re.search(r'XPRS station (\w+)', out) or re.search(r'call=(\w+)', out)
        self.call = m.group(1) if m else '?'

    def __str__(self):
        return f'board {self.call}'

    def console(self, cmds, wait, watch=0):
        """Open the console (the board restarts), wait, type cmds, read on."""
        s = serial.Serial()
        s.port, s.baudrate, s.timeout = self.path, 115200, 0.2
        s.dtr = s.rts = False
        s.open()
        buf = b''
        t = time.time()
        while time.time() - t < wait:
            buf += s.read(4096)
        for c in cmds:
            for ch in (c + '\r').encode():
                s.write(bytes([ch]))
                time.sleep(0.02)
            e = time.time() + 2
            while time.time() < e:
                buf += s.read(4096)
        t = time.time()
        while time.time() - t < watch:
            buf += s.read(4096)
        s.close()
        return re.sub(r'\x1b\[[0-9;]*m', '', buf.decode('utf-8', 'replace'))

    def bluetooth_only(self):
        self.console(['cfg set espnow_on 0'], BOOT_S)
        log(f'{self}: ESP-NOW off')

    def away(self):
        self.console(['cfg set ble_on 0'], BOOT_S)
        self.console([], 4)        # restart into the setting

    def back_and_watch(self, secs):
        self.console(['cfg set ble_on 1'], BOOT_S)
        return self.console([], 1, watch=secs)   # restart into it, and listen

    def back(self):
        self.console(['cfg set ble_on 1'], BOOT_S)
        self.console([], 4)


# ── one scenario ────────────────────────────────────────────────────────────

def scenario(name, writer, recipient, middle, others):
    log(f'=== {name}: {writer} -> {recipient}, kept by {middle}')
    res = {'name': name, 'writer': writer.call, 'recipient': recipient.call,
           'middle': middle.call}
    # Everybody else away, so the only station that can carry it is `middle`.
    for o in others:
        o.away()
    recipient.away()
    time.sleep(5)
    text = f'{name} {time.strftime("%H:%M:%S")}'
    wire = writer.send(recipient.call, text)
    ts = re.search(r'ts:(\S+)', wire).group(1)
    time.sleep(3)
    mid = None
    for l in writer.lines(400):
        m = re.search(r'parked (\w{6}) ' + writer.call + ' -> ' + recipient.call, l)
        if m:
            mid = m.group(1)
    res['id'], res['sent'] = mid, mid is not None
    log(f'sent {mid} ({text})')
    time.sleep(AIRINGS_S)
    writer.away()
    log(f'{writer} away; {recipient} back')
    t0 = time.time()
    if recipient.kind == 'board':
        out = recipient.back_and_watch(DELIVER_S)
        got = [l for l in out.splitlines()
               if f't:message f:{writer.call} d:{recipient.call} ts:{ts}' in l]
        res['delivered'] = bool(got)
        res['via'] = (re.search(r'via:(\S+)', got[0]).group(1)
                      if got and 'via:' in got[0] else '')
        res['once'] = len([l for l in out.splitlines()
                           if f'acked {mid}' in l]) >= 1
    else:
        recipient.back()
        got = []
        while time.time() - t0 < DELIVER_S and not got:
            time.sleep(5)
            got = recipient.rows(mid, writer.call)
        res['delivered'] = bool(got)
        res['after_s'] = round(time.time() - t0)
        time.sleep(90)    # let every holder repeat it at the recipient
        rows = recipient.rows(mid, writer.call)
        res['once'] = len(rows) == 1
        res['heard'] = rows[0].get('heard') if rows else 0
        res['via'] = ''
    log(f'delivered={res["delivered"]} via={res.get("via")}')
    writer.back()
    t0 = time.time()
    learned = []
    while time.time() - t0 < RECEIPT_S and not learned:
        time.sleep(5)
        learned = writer.learned(mid)
    res['receipt'] = bool(learned)
    res['receipt_s'] = round(time.time() - t0)
    for o in others:
        o.back()
    if recipient.kind == 'board':
        recipient.back()
    res['pass'] = all(res.get(k) for k in ('sent', 'delivered', 'once', 'receipt'))
    log(f'--> {"PASS" if res["pass"] else "FAIL"} {json.dumps(res)}')
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('--phone', action='append', default=[])
    ap.add_argument('--board', action='append', default=[])
    a = ap.parse_args()
    phones = [Phone(p, 3470 + i) for i, p in enumerate(a.phone)]
    boards = [Board(b) for b in a.board]
    for d in phones + boards:
        d.bluetooth_only()
    results = []
    if len(phones) >= 2 and boards:
        results.append(scenario('phone-phone/board', phones[0], phones[1],
                                boards[0], boards[1:]))
    if phones and len(boards) >= 2:
        results.append(scenario('phone-board/board', phones[0], boards[1],
                                boards[0], phones[1:]))
    if len(phones) >= 2 and boards:
        results.append(scenario('phone-board/phone', phones[0], boards[0],
                                phones[1], boards[1:]))
    print(json.dumps(results, indent=1))
    sys.exit(0 if results and all(r['pass'] for r in results) else 1)


if __name__ == '__main__':
    main()
