"""Runs WinHTTP against disposable loopback SSE endpoints; never uses stored keys."""
import argparse
import http.server
import json
import subprocess
import threading
import time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        mode = self.path.split('/')[1]
        if mode == 'unexpected':
            self.server.redirected = True
        assert self.path.endswith('/models')
        assert self.headers['Authorization'] == 'Bearer rimes-loopback-test'
        self.send_response(302 if mode == 'models_redirect' else 401 if mode == 'models_http_error' else 200)
        if mode == 'models_redirect':
            self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/unexpected/models')
        self.end_headers()
        if mode == 'models_timeout':
            time.sleep(4)
            return
        if mode == 'models_malformed':
            self.wfile.write(b'not json')
            return
        rows = [{'id': name} for name in ('beta', 'alpha', 'alpha', 'invalid\nmodel', 'invalid\0model')]
        if mode == 'models_oversize':
            rows = [{'id': 'model'}] * 4097
        self.wfile.write(json.dumps({'data': rows}).encode())

    def do_POST(self):
        mode = self.path.split('/')[1]
        body = self.rfile.read(int(self.headers['Content-Length']))
        assert b'local-test' in body and self.headers['Authorization'] == 'Bearer rimes-loopback-test'
        self.send_response(503 if mode == 'http_error' else 200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        if mode == 'timeout':
            time.sleep(7)
            return
        if mode == 'malformed':
            self.wfile.write(b'data: invalid\n\n')
            return
        data = 'data: {"choices":[{"delta":{"content":"你好💡"}}]}\r\n\r\n'.encode()
        if mode not in ('disconnect', 'http_error'):
            data += b'data: [DONE]\n\n'
        try:
            for byte in data:
                self.wfile.write(bytes([byte]))
                self.wfile.flush()
        except (ConnectionError, OSError):
            pass

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('probe')
    args = parser.parse_args()
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        server.redirected = False
        threading.Thread(target=server.serve_forever, daemon=True).start()
        for mode in ('success', 'disconnect', 'malformed', 'http_error', 'cancel', 'timeout'):
            subprocess.run([args.probe, f'http://127.0.0.1:{server.server_port}/{mode}', mode], check=True, timeout=20)
        for mode in ('models_success', 'models_redirect', 'models_http_error', 'models_malformed', 'models_oversize', 'models_timeout'):
            subprocess.run([args.probe, f'http://127.0.0.1:{server.server_port}/{mode}', mode], check=True, timeout=20)
        assert not server.redirected, 'model discovery must never forward credentials through a redirect'
        server.shutdown()
    # No listener: immediate connection failure must retain the source contract.
    subprocess.run([args.probe, f'http://127.0.0.1:{server.server_port}', 'offline'], check=True, timeout=20)
    subprocess.run([args.probe, f'http://127.0.0.1:{server.server_port}', 'models_offline'], check=True, timeout=20)
