# -----------------------------------------------------------------------------
# Copyright (c) 2026, Oracle and/or its affiliates.
#
# This software is dual-licensed to you under the Universal Permissive License
# (UPL) 1.0 as shown at https://oss.oracle.com/licenses/upl and Apache License
# 2.0 as shown at http://www.apache.org/licenses/LICENSE-2.0.
# -----------------------------------------------------------------------------

import socket
import threading

import oracledb
import pytest


class Socks5TestProxy:
    def __init__(self, require_auth=False, username=None, password=None):
        self._require_auth = require_auth
        self._username = username
        self._password = password
        self._listener = None
        self.host = "127.0.0.1"
        self.port = None
        self._thread = None
        self._stop = threading.Event()
        self.seen_connect_host = None
        self.seen_connect_port = None
        self.seen_auth = False

    def start(self):
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind((self.host, 0))
        self._listener.listen(1)
        self.port = self._listener.getsockname()[1]
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._listener is not None:
            try:
                self._listener.close()
            except Exception:
                pass
        if self._thread is not None:
            self._thread.join(timeout=1)

    def _recv_exact(self, conn, nbytes):
        data = b""
        while len(data) < nbytes:
            chunk = conn.recv(nbytes - len(data))
            if not chunk:
                break
            data += chunk
        return data

    def _run(self):
        try:
            conn, _ = self._listener.accept()
        except Exception:
            return
        with conn:
            # greeting
            hdr = self._recv_exact(conn, 2)
            if len(hdr) != 2 or hdr[0] != 5:
                return
            nmethods = hdr[1]
            methods = self._recv_exact(conn, nmethods)
            if len(methods) != nmethods:
                return
            if self._require_auth:
                if 2 not in methods:
                    conn.sendall(b"\x05\xff")
                    return
                conn.sendall(b"\x05\x02")
                auth_hdr = self._recv_exact(conn, 2)
                if len(auth_hdr) != 2 or auth_hdr[0] != 1:
                    return
                ulen = auth_hdr[1]
                user = self._recv_exact(conn, ulen)
                plen_b = self._recv_exact(conn, 1)
                if len(plen_b) != 1:
                    return
                plen = plen_b[0]
                pw = self._recv_exact(conn, plen)
                if (
                    user.decode() != self._username
                    or pw.decode() != self._password
                ):
                    conn.sendall(b"\x01\x01")
                    return
                self.seen_auth = True
                conn.sendall(b"\x01\x00")
            else:
                if 0 not in methods:
                    conn.sendall(b"\x05\xff")
                    return
                conn.sendall(b"\x05\x00")

            # connect request
            req = self._recv_exact(conn, 4)
            if len(req) != 4 or req[0] != 5 or req[1] != 1:
                return
            atyp = req[3]
            if atyp == 3:
                ln_b = self._recv_exact(conn, 1)
                if len(ln_b) != 1:
                    return
                ln = ln_b[0]
                host = self._recv_exact(conn, ln).decode(
                    "ascii", errors="ignore"
                )
            elif atyp == 1:
                host = socket.inet_ntoa(self._recv_exact(conn, 4))
            elif atyp == 4:
                host = socket.inet_ntop(
                    socket.AF_INET6, self._recv_exact(conn, 16)
                )
            else:
                return
            port_bytes = self._recv_exact(conn, 2)
            if len(port_bytes) != 2:
                return
            port = (port_bytes[0] << 8) | port_bytes[1]
            self.seen_connect_host = host
            self.seen_connect_port = port

            # reply success with IPv4 bind addr 0.0.0.0:0
            conn.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")

            # do not forward; just wait briefly for client to send next bytes
            conn.settimeout(0.5)
            try:
                conn.recv(1)
            except Exception:
                pass


def _get_host_port_from_connect_string(connect_string: str):
    # Use ConnectParams parsing to avoid duplicating Easy Connect parsing.
    params = oracledb.ConnectParams()
    params.parse_connect_string(connect_string)
    host = params.host if isinstance(params.host, str) else params.host[0]
    port = params.port if isinstance(params.port, int) else params.port[0]
    return host, port


def test_4530_socks_proxy_handshake_no_auth(test_env):
    if not oracledb.is_thin_mode():
        pytest.skip("SOCKS proxy support is Thin mode only")
    proxy = Socks5TestProxy(require_auth=False)
    proxy.start()
    try:
        dsn = test_env.connect_string
        target_host, target_port = _get_host_port_from_connect_string(dsn)
        params = test_env.get_connect_params()
        params.set(socks_proxy=proxy.host, socks_proxy_port=proxy.port)
        with pytest.raises(oracledb.Error):
            oracledb.connect(dsn=dsn, params=params)
        assert proxy.seen_connect_host == target_host
        assert proxy.seen_connect_port == target_port
        assert proxy.seen_auth is False
    finally:
        proxy.stop()


def test_4531_socks_proxy_handshake_userpass(test_env):
    if not oracledb.is_thin_mode():
        pytest.skip("SOCKS proxy support is Thin mode only")
    proxy = Socks5TestProxy(
        require_auth=True,
        username="scott",
        password="tiger",
    )
    proxy.start()
    try:
        dsn = test_env.connect_string
        target_host, target_port = _get_host_port_from_connect_string(dsn)
        params = test_env.get_connect_params()
        params.set(
            socks_proxy=proxy.host,
            socks_proxy_port=proxy.port,
            socks_proxy_username="scott",
            socks_proxy_password="tiger",
        )
        with pytest.raises(oracledb.Error):
            oracledb.connect(dsn=dsn, params=params)
        assert proxy.seen_connect_host == target_host
        assert proxy.seen_connect_port == target_port
        assert proxy.seen_auth is True
    finally:
        proxy.stop()


async def test_4532_socks_proxy_handshake_async_userpass(test_env):
    if not oracledb.is_thin_mode():
        pytest.skip("SOCKS proxy support is Thin mode only")
    proxy = Socks5TestProxy(
        require_auth=True,
        username="scott",
        password="tiger",
    )
    proxy.start()
    try:
        dsn = test_env.connect_string
        target_host, target_port = _get_host_port_from_connect_string(dsn)
        params = test_env.get_connect_params()
        params.set(
            socks_proxy=proxy.host,
            socks_proxy_port=proxy.port,
            socks_proxy_username="scott",
            socks_proxy_password="tiger",
        )
        with pytest.raises(oracledb.Error):
            await oracledb.connect_async(dsn=dsn, params=params)
        assert proxy.seen_connect_host == target_host
        assert proxy.seen_connect_port == target_port
        assert proxy.seen_auth is True
    finally:
        proxy.stop()
