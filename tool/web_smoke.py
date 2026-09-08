#!/usr/bin/env python3
"""Drive the web build in headless Chromium over the DevTools protocol.

The launcher draws with CanvasKit, so nothing useful is in the DOM and
Chromium's own --screenshot fires on `load`, long before Flutter has painted.
This opens a page over --remote-debugging-port, streams console lines and
uncaught exceptions (LogService mirrors the log ring to the console on web),
runs the steps you give it, and captures screenshots when asked.

    (cd build/web && python3 -m http.server 8099 --bind 127.0.0.1 &)
    CDP_FRESH=1 tool/web_smoke.py http://127.0.0.1:8099/ 12 /tmp/run \
        shot:welcome click:304,384 wait:10 shot:launcher reload wait:14 shot:back

Arguments: URL, seconds to wait after navigation, output prefix, then steps:
  wait:N        sleep N seconds
  click:X,Y     left-click at page coordinates
  key:TEXT      type TEXT
  shot:NAME     screenshot to <prefix>-NAME.png
  reload        Page.reload (the IndexedDB stores survive; this is the
                persistence test)
  eval:JS       evaluate JS (awaits a promise) and print the value
A final screenshot lands at <prefix>.png; the console log at <prefix>.log.

CDP_FRESH=1 wipes the Chromium profile first (a first-run, no stored data).
The snap Chromium can only write under ~/snap/chromium/common, which is where
the profile lives. Never point this at DISPLAY=:0: headless needs no display.
Only python3 and the `websockets` module are needed.
"""
import asyncio, json, subprocess, sys, time, urllib.request, base64, os, shutil
import websockets

url, secs, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
# steps after OUT: wait:N | click:X,Y | shot:NAME | reload | eval:JS | key:TEXT
steps = sys.argv[4:]
port = 9333
prof = os.path.expanduser('~/snap/chromium/common/xprs-cdp-profile')
if os.environ.get('CDP_FRESH') == '1' and os.path.isdir(prof):
    shutil.rmtree(prof)
chrome = subprocess.Popen(['chromium', '--headless=new', '--disable-gpu', '--no-sandbox',
    '--enable-unsafe-swiftshader', '--window-size=1280,800', f'--remote-debugging-port={port}',
    f'--user-data-dir={prof}', 'about:blank'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        try:
            targets = json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/json'))
            break
        except Exception:
            time.sleep(0.2)
    page = [t for t in targets if t['type'] == 'page'][0]
    lines = []
    async def run():
        async with websockets.connect(page['webSocketDebuggerUrl'], max_size=2**28) as ws:
            mid = 0
            pending = {}
            async def send(method, params=None):
                nonlocal mid
                mid += 1
                fut = asyncio.get_event_loop().create_future()
                pending[mid] = fut
                await ws.send(json.dumps({'id': mid, 'method': method, 'params': params or {}}))
                return await fut
            async def reader():
                async for raw in ws:
                    m = json.loads(raw)
                    if 'id' in m:
                        f = pending.pop(m['id'], None)
                        if f: f.set_result(m.get('result', m))
                        continue
                    ev, p = m.get('method'), m.get('params', {})
                    t = time.strftime('%H:%M:%S')
                    if ev == 'Runtime.consoleAPICalled':
                        args = ' '.join(str(a.get('value', a.get('description', ''))) for a in p['args'])
                        lines.append(f'{t} console.{p["type"]}: {args}')
                    elif ev == 'Runtime.exceptionThrown':
                        d = p['exceptionDetails']
                        desc = d.get('exception', {}).get('description') or d.get('text')
                        lines.append(f'{t} EXCEPTION: {desc}')
                    elif ev == 'Log.entryAdded':
                        e = p['entry']
                        if e.get('level') in ('error', 'warning'):
                            lines.append(f'{t} log.{e["level"]}: {e.get("text")} {e.get("url", "")}')
            rt = asyncio.ensure_future(reader())
            await send('Runtime.enable'); await send('Log.enable'); await send('Page.enable')
            await send('Page.navigate', {'url': url})
            await asyncio.sleep(secs)
            async def shot(name):
                r = await send('Page.captureScreenshot', {'format': 'png'})
                with open(name + '.png', 'wb') as f:
                    f.write(base64.b64decode(r['data']))
                lines.append(f'{time.strftime("%H:%M:%S")} SHOT {name}.png')
            for st in steps:
                kind, _, arg = st.partition(':')
                if kind == 'wait':
                    await asyncio.sleep(float(arg))
                elif kind == 'click':
                    x, y = [int(v) for v in arg.split(',')]
                    for t in ('mouseMoved', 'mousePressed', 'mouseReleased'):
                        await send('Input.dispatchMouseEvent', {'type': t, 'x': x, 'y': y, 'button': 'left', 'clickCount': 1})
                        await asyncio.sleep(0.05)
                    lines.append(f'{time.strftime("%H:%M:%S")} CLICK {x},{y}')
                elif kind == 'key':
                    for ch in arg:
                        await send('Input.dispatchKeyEvent', {'type': 'keyDown', 'text': ch, 'key': ch})
                        await send('Input.dispatchKeyEvent', {'type': 'keyUp', 'key': ch})
                elif kind == 'shot':
                    await shot(out + '-' + arg)
                elif kind == 'reload':
                    await send('Page.reload')
                    lines.append(f'{time.strftime("%H:%M:%S")} RELOAD')
                elif kind == 'eval':
                    r = await send('Runtime.evaluate', {'expression': arg, 'returnByValue': True, 'awaitPromise': True})
                    lines.append('EVAL: ' + json.dumps(r.get('result', r))[:4000])
            await shot(out)
            rt.cancel()
    asyncio.get_event_loop().run_until_complete(run())
finally:
    chrome.terminate()
with open(out + '.log', 'w') as f:
    f.write('\n'.join(lines) + '\n')
print('\n'.join(lines))
