"""Local-only Plex protocol fixture. Never used by production builds."""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

parser = argparse.ArgumentParser()
parser.add_argument('media', type=Path)
parser.add_argument('--port', type=int, default=18765)
args = parser.parse_args()
size = args.media.stat().st_size
lock = threading.Lock()
requests = []
history_updates = []
offline = False

def media(key, title, kind='movie', **extra):
    return dict(ratingKey=str(key), title=title, type=kind, year=2026,
                summary='A local test title for verifying direct Plex downloads.',
                duration=60000,
                Media=[dict(id=key, videoResolution='720', container='mp4', videoCodec='h264',
                            Part=[dict(key=f'/library/parts/{key}/1/file.mp4', size=size, container='mp4')])], **extra)

items = {
 '101': media(101, 'Open Skies'),
 '102': media(102, 'Permission Test'),
 '103': media(103, 'Slow Journey'),
 '105': media(105, 'Resume Test', viewOffset=12000, viewCount=0, lastViewedAt=0),
 '201': dict(ratingKey='201', title='The Long Weekend', type='show', summary='A two-episode test series.', leafCount=2),
 '202': dict(ratingKey='202', title='Season 1', type='season', index=1, leafCount=2),
 '203': media(203, 'The Arrival', 'episode', parentIndex=1, index=1, grandparentTitle='The Long Weekend'),
 '204': media(204, 'Homeward', 'episode', parentIndex=1, index=2, grandparentTitle='The Long Weekend'),
}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def json(self, body, code=200):
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        global offline
        parsed = urlsplit(self.path); query = parse_qs(parsed.query)
        if parsed.path == '/test/offline':
            offline = query.get('enabled') == ['1']
            return self.json({'offline': offline})
        if parsed.path != '/:/timeline': return self.json({},404)
        if offline: return self.json({},503)
        if self.headers.get('X-Plex-Token') != 'fixture-token': return self.json({},401)
        identifier = query.get('ratingKey',[''])[0]
        if identifier not in items: return self.json({},404)
        update = {k:v[0] for k,v in query.items()}
        update['session'] = self.headers.get('X-Plex-Session-Identifier')
        history_updates.append(update)
        offset = int(update['time']); duration = int(update['duration'])
        items[identifier]['viewOffset'] = 0 if offset >= duration else offset
        items[identifier]['viewCount'] = int(offset >= duration)
        items[identifier]['lastViewedAt'] = int(update['updated'])
        return self.json({'MediaContainer':{'size':0}})
    def do_PUT(self):
        parsed = urlsplit(self.path); query = parse_qs(parsed.query)
        if offline: return self.json({},503)
        if self.headers.get('X-Plex-Token') != 'fixture-token': return self.json({},401)
        identifier = query.get('key',[''])[0]
        if identifier not in items or parsed.path not in ['/:/scrobble','/:/unscrobble']: return self.json({},404)
        items[identifier]['viewCount'] = int(parsed.path == '/:/scrobble')
        items[identifier]['viewOffset'] = 0
        return self.json({'MediaContainer':{'size':0}})
    def do_GET(self):
        parsed = urlsplit(self.path); path = parsed.path
        if path == '/test/requests': return self.json(requests)
        if path == '/test/history': return self.json(history_updates)
        if offline: return self.json({},503)
        if self.headers.get('X-Plex-Token') != 'fixture-token': return self.json({'error':'unauthorized'},401)
        with lock: requests.append(path)
        if path == '/': return self.json({'MediaContainer':dict(machineIdentifier='test-server', friendlyName='Screening Room')})
        if path == '/library/sections':
            return self.json({'MediaContainer': {'Directory':[dict(key='1', title='Movies', type='movie'),dict(key='2',title='TV Shows',type='show')]}})
        ids = None
        if path == '/library/sections/1/all': ids = ['101','102','103','105']
        elif path == '/library/sections/2/all': ids = ['201']
        elif path == '/library/metadata/201/children': ids = ['202']
        elif path == '/library/metadata/202/children': ids = ['203','204']
        elif path.startswith('/library/metadata/') and path.split('/')[-1] in items: ids = [path.split('/')[-1]]
        if ids is not None:
            # Force multiple pages, even though client requests 200 per page.
            offset = int(parse_qs(parsed.query).get('X-Plex-Container-Start',['0'])[0])
            return self.json({'MediaContainer':dict(Metadata=[items[i] for i in ids[offset:offset+1]], offset=offset,totalSize=len(ids),size=len(ids[offset:offset+1]))})
        if path.startswith('/library/parts/'):
            if parse_qs(parsed.query).get('download') != ['1']: return self.json({'error':'download parameter required'},400)
            part = path.split('/')[3]
            if part == '102': return self.json({'error':'download forbidden'},403)
            start = 0
            if self.headers.get('Range'): start = int(self.headers['Range'].split('=')[1].split('-')[0])
            self.send_response(206 if start else 200)
            self.send_header('Content-Type','video/mp4'); self.send_header('Content-Length',str(size-start)); self.send_header('Accept-Ranges','bytes'); self.send_header('ETag','"fixture-v1"')
            if start: self.send_header('Content-Range',f'bytes {start}-{size-1}/{size}')
            self.end_headers()
            try:
                with args.media.open('rb') as f:
                    f.seek(start)
                    while chunk := f.read(65536):
                        self.wfile.write(chunk)
                        if part == '103': time.sleep(.04)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        self.json({'error':'not found'},404)

print(f'Plex fixture listening on 127.0.0.1:{args.port}',flush=True)
ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
