"""Loopback-only sign-in fixture for testing external-browser handoff, not real accounts."""
import json
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

pins = {}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, body, kind='application/json', status=200):
        data = (json.dumps(body) if kind == 'application/json' else body).encode()
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        if self.path == '/pins':
            identifier = len(pins) + 1
            pins[identifier] = dict(id=identifier, code=uuid.uuid4().hex, expiresIn=300, authToken=None)
            self.send(pins[identifier], status=201)
        else: self.send({}, status=404)
    def do_GET(self):
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        if parsed.path.startswith('/pins/'):
            pin = pins.get(int(parsed.path.split('/')[-1]))
            if pin and query.get('code') == [pin['code']]: self.send(pin)
            else: self.send({}, status=404)
        elif parsed.path == '/resources':
            if self.headers.get('X-Plex-Token') != 'auth-fixture-token': return self.send({}, status=401)
            self.send([dict(name='Browser Test Server',clientIdentifier='browser-test-server',provides='server',accessToken='auth-fixture-token',connections=[])])
        elif parsed.path == '/auth':
            code = query.get('code',[''])[0]
            self.send('''<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="font:20px system-ui;padding:24px"><h1>Plex browser test</h1>
<p>This is a local test page. No real account is used.</p>
<form action="/authorize"><label>Email <input name="email" type="email" aria-label="Test email"></label>
<input type="hidden" name="code" value="''' + code + '''"><p><button type="submit">Authorize test account</button></p></form></body></html>''', 'text/html')
        elif parsed.path == '/authorize':
            code = query.get('code',[''])[0]
            for pin in pins.values():
                if pin['code'] == code: pin['authToken'] = 'auth-fixture-token'
            self.send('<html><body><h1>Test sign-in complete</h1><p>Return to better-plex.</p></body></html>', 'text/html')
        else: self.send({}, status=404)

print('Auth fixture listening on 127.0.0.1:18766', flush=True)
ThreadingHTTPServer(('127.0.0.1',18766),Handler).serve_forever()
