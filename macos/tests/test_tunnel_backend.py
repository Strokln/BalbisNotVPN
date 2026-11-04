import hashlib
import importlib.util
from pathlib import Path
import platform
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'tunnel'
spec = importlib.util.spec_from_file_location('endpoints', ROOT / 'endpoints.py')
endpoints = importlib.util.module_from_spec(spec)
spec.loader.exec_module(endpoints)


class TunnelBackendTests(unittest.TestCase):
    def test_release_asset_integrity(self):
        for arch, digest in [('x86_64', 'bf68aeac95311d9a7c7229249a3188901bb252beff18737e2643e2558efcbb2a'),
                             ('arm64', '9f2b2b268d5d5ffe272cc40f07df374190becab65117512d683f3a17b90a9d25')]:
            self.assertEqual(hashlib.sha256((ROOT/'bin'/f'opera-proxy-{arch}').read_bytes()).hexdigest(), digest)

    def test_native_binary_launch_and_contract(self):
        binary = ROOT/'bin'/('opera-proxy-arm64' if platform.machine() == 'arm64' else 'opera-proxy-x86_64')
        self.assertEqual(subprocess.check_output([str(binary), '-version'], text=True).strip(), 'v1.31.0')
        result = subprocess.run([str(binary), '-help'], capture_output=True, text=True, timeout=5)
        for flag in ['-bind-address', '-country', '-proxy', '-server-selection', '-list-proxies-all-out', '-override-proxy-address']:
            self.assertIn(flag, result.stdout + result.stderr)

    def test_discovery_csv_dedup_and_untrusted_values(self):
        rows = 'country_code,country_name,host,ip_address,port\nEU,Europe,test,77.111.247.19,443\nEU,Europe,test,77.111.247.19,443\nEU,Europe,test,127.0.0.1,443\nEU,Europe,test,77.111.247.19,99999\nXX,unknown,test,8.8.8.8,443\n'
        self.assertEqual(endpoints.parse_endpoints(rows), [{'country': 'EU', 'endpoint': '77.111.247.19:443'}])

    def test_benchmark_csv_excludes_failed(self):
        rows = 'country_code,country_name,host,ip_address,port,speed_ms,speed_status\nEU,Europe,test,77.111.244.47,443,,timeout\nEU,Europe,test,77.111.247.19,443,100,ok\n'
        self.assertEqual(endpoints.parse_endpoints(rows), [{'country': 'EU', 'endpoint': '77.111.247.19:443'}])


if __name__ == '__main__':
    unittest.main()
