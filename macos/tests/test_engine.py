"""Loopback-only integration checks; no system proxies, DNS, routes or VPN changes."""
import contextlib
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ENGINE = Path(os.environ.get('BALBIS_TPWS', Path(__file__).resolve().parents[1] / 'engine/bin/tpws-x86_64'))
STRATEGIES = [[], ['--split-pos=1,midsld'], ['--split-pos=1,midsld', '--tlsrec=sniext+1']]


def receive(sock, size):
    result = b''
    while len(result) < size:
        part = sock.recv(size-len(result))
        if not part:
            raise EOFError('socket closed')
        result += part
    return result


def listener():
    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    sock.listen(8)
    sock.settimeout(5)
    return sock


@contextlib.contextmanager
def proxy(flags):
    with listener() as reserved:
        port = reserved.getsockname()[1]
    with tempfile.TemporaryFile() as log:
        proc = subprocess.Popen([str(ENGINE), '--bind-addr=127.0.0.1', f'--port={port}', '--socks', *flags], stdout=log, stderr=log)
        try:
            for _ in range(100):
                if proc.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read().decode())
                try:
                    with socket.create_connection(('127.0.0.1', port), .1) as ready:
                        ready.sendall(b'\x05\x01\x00')
                        if receive(ready, 2) == b'\x05\x00':
                            break
                except OSError:
                    time.sleep(.03)
            else:
                raise TimeoutError('SOCKS readiness')
            yield port
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def connect(proxy_port, destination):
    sock = socket.create_connection(('127.0.0.1', proxy_port), 5)
    sock.settimeout(5)
    sock.sendall(b'\x05\x01\x00')
    assert receive(sock, 2) == b'\x05\x00'
    sock.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('!H', destination))
    reply = receive(sock, 4)
    assert reply[:2] == b'\x05\x00', reply
    receive(sock, 6 if reply[3] == 1 else 18)
    return sock


class EngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global ENGINE
        cls.build_dir = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build_dir.cleanup)
        ENGINE = Path(cls.build_dir.name) / 'tpws-loopback-test'
        build = Path(__file__).resolve().parents[1] / 'engine/build.sh'
        subprocess.run([str(build), 'x86_64', str(ENGINE)], env={**os.environ, 'BALBIS_TEST_ALLOW_LOOPBACK': '1'}, check=True, capture_output=True)

    def test_http_all_strategies(self):
        for flags in STRATEGIES:
            with self.subTest(flags=flags), listener() as server, proxy(flags) as port:
                with connect(port, server.getsockname()[1]) as client, server.accept()[0] as upstream:
                    payload = b'GET / HTTP/1.1\r\nHost: example.test\r\n\r\n'
                    client.sendall(payload)
                    self.assertEqual(receive(upstream, len(payload)), payload)
                    upstream.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK')
                    self.assertTrue(client.recv(4096).endswith(b'OK'))

    def test_tls_record_split(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        tls = context.wrap_bio(incoming, outgoing, server_hostname='example.test')
        with self.assertRaises(ssl.SSLWantReadError):
            tls.do_handshake()
        hello = outgoing.read()
        with listener() as server, proxy(STRATEGIES[2]) as port:
            with connect(port, server.getsockname()[1]) as client, server.accept()[0] as upstream:
                client.sendall(hello)
                first = receive(upstream, 5)
                data1 = receive(upstream, int.from_bytes(first[3:5], 'big'))
                second = receive(upstream, 5)
                data2 = receive(upstream, int.from_bytes(second[3:5], 'big'))
                self.assertEqual(first[:3], hello[:3])
                self.assertEqual(second[:3], hello[:3])
                self.assertEqual(data1 + data2, hello[5:])
                self.assertGreater(len(data1), 0)
                self.assertGreater(len(data2), 0)

    def test_real_tls_all_strategies(self):
        with tempfile.TemporaryDirectory() as directory:
            cert, key = Path(directory)/'cert.pem', Path(directory)/'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=example.test', '-days', '1', '-out', str(cert), '-keyout', str(key)], check=True, capture_output=True)
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(cert, key)
            client_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            client_context.check_hostname = False
            client_context.verify_mode = ssl.CERT_NONE
            for flags in STRATEGIES:
                with self.subTest(flags=flags), listener() as server, proxy(flags) as port:
                    errors = []
                    def serve():
                        try:
                            with server.accept()[0] as raw, server_context.wrap_socket(raw, server_side=True) as tls:
                                self.assertEqual(receive(tls, 4), b'ping')
                                tls.sendall(b'pong')
                        except Exception as exc:
                            errors.append(exc)
                    worker = threading.Thread(target=serve)
                    worker.start()
                    with connect(port, server.getsockname()[1]) as raw, client_context.wrap_socket(raw, server_hostname='example.test') as tls:
                        tls.sendall(b'ping')
                        self.assertEqual(receive(tls, 4), b'pong')
                    worker.join(6)
                    self.assertFalse(worker.is_alive())
                    if errors:
                        raise errors[0]


if __name__ == '__main__':
    unittest.main()
