#!/usr/bin/env python3
"""Discover Opera endpoint IPs without requesting or printing credential output."""
import argparse
import csv
import ipaddress
import io
import json
from pathlib import Path
import platform
import subprocess
import tempfile


def parse_endpoints(text):
    result, seen = [], set()
    for row in csv.DictReader(io.StringIO(text)):
        try:
            ip = ipaddress.ip_address(row['ip_address'])
            port = int(row['port'])
            country = row['country_code']
            if not ip.is_global or not 1 <= port <= 65535 or country not in ('EU', 'AM', 'AS'):
                continue
            if row.get('speed_status') not in (None, 'ok'):
                continue
            endpoint = f'[{ip}]:{port}' if ip.version == 6 else f'{ip}:{port}'
            if (country, endpoint) not in seen:
                result.append({'country': country, 'endpoint': endpoint})
                seen.add((country, endpoint))
        except (KeyError, ValueError, TypeError):
            continue
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--country', choices=['EU', 'AM', 'AS', 'EU,AM'], default='EU,AM')
    parser.add_argument('--through-socks', type=int)
    parser.add_argument('--binary', default=str(Path(__file__).parent / 'bin' / ('opera-proxy-arm64' if platform.machine() == 'arm64' else 'opera-proxy-x86_64')))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='balbis-opera-discover-') as state:
        output = Path(state) / 'endpoints.csv'
        cmd = [str(Path(args.binary).resolve()), '-country', args.country, '-list-proxies-all-out', str(output),
               '-verbosity', '40', '-init-retries', '1', '-timeout', '15s']
        if args.through_socks:
            if not 1 <= args.through_socks <= 65535:
                parser.error('invalid SOCKS port')
            cmd += ['-proxy', f'socks5://127.0.0.1:{args.through_socks}']
        try:
            done = subprocess.run(cmd, cwd=state, capture_output=True, timeout=60)
            if done.returncode:
                raise RuntimeError('Opera discovery failed')
            endpoints = parse_endpoints(output.read_text())
            if not endpoints:
                raise RuntimeError('Opera discovery returned no usable endpoints')
            print(json.dumps(endpoints))
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
            # Do not forward arbitrary upstream output, which may contain sensitive data.
            parser.exit(1, f'{type(error).__name__}: discovery unavailable\n')
