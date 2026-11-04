#!/usr/bin/env python3
"""Explicit opt-in live probe: traffic uses the new localhost HTTP proxy only."""
import argparse
import json
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import time


def probe(binary, country='EU', endpoint=None):
    with socket.socket() as reserved:
        reserved.bind(('127.0.0.1', 0))
        port = reserved.getsockname()[1]
    args = [str(Path(binary).resolve()), '-bind-address', f'127.0.0.1:{port}', '-country', country,
            '-init-retries', '1', '-timeout', '15s', '-server-selection', 'first', '-verbosity', '40']
    if endpoint:
        args += ['-override-proxy-address', endpoint]
    with tempfile.TemporaryDirectory(prefix='balbis-opera-probe-') as state, tempfile.TemporaryFile() as log:
        process = subprocess.Popen(args, cwd=state, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            ready = False
            for _ in range(300):
                if process.poll() is not None:
                    break
                try:
                    with socket.create_connection(('127.0.0.1', port), .1):
                        ready = True
                        break
                except OSError:
                    time.sleep(.1)
            if not ready:
                return {'ok': False, 'country_requested': country, 'error': 'backend did not listen', 'exit': process.poll()}
            # --noproxy '' prevents inherited NO_PROXY from silently bypassing this proxy.
            result = subprocess.run(['curl', '--noproxy', '', '--proxy', f'http://127.0.0.1:{port}',
                                     '--connect-timeout', '20', '--max-time', '30', '--fail', '--silent', '--show-error',
                                     'https://www.cloudflare.com/cdn-cgi/trace'], capture_output=True, text=True)
            fields = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
            # Avoid publishing the user's or exit IP, credentials, or raw upstream logs.
            return {'ok': result.returncode == 0, 'country_requested': country, 'exit_country': fields.get('loc'),
                    'curl_status': result.returncode, 'error': result.stderr.strip() or None}
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--country', choices=['EU', 'AM', 'AS'], default='EU')
    parser.add_argument('--endpoint')
    parser.add_argument('--binary', default=str(Path(__file__).parent / 'bin' / ('opera-proxy-arm64' if platform.machine() == 'arm64' else 'opera-proxy-x86_64')))
    args = parser.parse_args()
    result = probe(args.binary, args.country, args.endpoint)
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0 if result['ok'] else 1)
