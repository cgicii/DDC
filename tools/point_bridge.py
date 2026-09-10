#!/usr/bin/env python3
"""HMI 화면 ↔ 장비 사이의 포인트 브리지.

왜 브리지가 필요한가
-------------------
브라우저는 raw TCP 소켓을 열 수 없다. Sedona SOX(5001), Modbus TCP(502),
BACnet/IP(47808) 어느 것도 브라우저가 직접 붙지 못한다. 그래서 중간에
"장비 쪽은 TCP, 화면 쪽은 WebSocket"인 프로세스가 반드시 하나 필요하다.

    [장비] --TCP--> [브리지] --WebSocket--> [브라우저 화면]
                       │
                       └─ 구독 관리 / 변경분만 push / 재연결

설계에서 중요한 것
-----------------
1. **구독 기반**: 화면이 필요한 태그만 등록한다. 전체 포인트를 매 틱 보내면
   포인트가 수백 개인 현장에서 곧 한계가 온다.
2. **변경분만 전송**: 값이 안 바뀐 포인트는 보내지 않는다. 실제 현장 데이터는
   대부분의 틱에서 대부분의 포인트가 그대로다.
3. **화면 전환 시 구독 교체**: 이걸 빠뜨리면 구독이 계속 쌓여 몇 시간 뒤
   브리지가 죽는다. HMI에서 가장 흔한 사고 지점이다.
4. **드라이버 분리**: 프로토콜이 SOX든 Modbus든 BACnet이든 브리지 본체는
   그대로 두고 드라이버만 갈아끼운다.

의존성 없음 (표준 라이브러리만). 현장 폐쇄망에 그대로 올릴 수 있어야 한다.

사용법
------
    python3 tools/point_bridge.py                      # 모의 드라이버
    python3 tools/point_bridge.py --port 8765
    python3 tools/point_bridge.py --driver sox --device 192.168.1.50

화면에서 연결:
    prototype/hmi-authoring-poc.html?ws=ws://localhost:8765
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import random
import socket
import struct
import threading
import time
from typing import Callable

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# ==========================================================================
# 1. 드라이버 — 프로토콜별 구현. 브리지 본체는 이 인터페이스만 안다.
# ==========================================================================

class Driver:
    """포인트 값을 읽어오는 주체."""

    name = "base"

    def connect(self) -> None: ...
    def close(self) -> None: ...

    def points(self) -> dict[str, str]:
        """{태그: 종류('bool'|'float')} — 브리지가 화면에 알려줄 포인트 목록."""
        raise NotImplementedError

    def read(self, tags: list[str]) -> dict[str, float | bool]:
        """구독된 태그들의 현재 값."""
        raise NotImplementedError

    def write(self, tag: str, value) -> bool:
        return False


class MockDriver(Driver):
    """모의 드라이버. 장비 없이 화면·브리지·구독 경로를 검증할 때 쓴다."""

    name = "mock"

    SPEC = {
        "AHU1_SF_RUN":  ("bool", 1),
        "AHU1_RF_RUN":  ("bool", 0),
        "AHU1_SA_TEMP": ("float", (10, 22)),
        "AHU1_RA_TEMP": ("float", (20, 28)),
        "CHW_VLV_POS":  ("float", (0, 100)),
        "OA_DMP_POS":   ("float", (0, 100)),
        "TANK1_LEVEL":  ("float", (0, 100)),
        "PUMP1_RUN":    ("bool", 1),
        "PUMP1_FAULT":  ("bool", 0),
        "FILTER_ALARM": ("bool", 0),
    }

    def __init__(self):
        self.vals: dict[str, float | bool] = {}
        for tag, (kind, init) in self.SPEC.items():
            self.vals[tag] = init if kind == "bool" else sum(init) / 2

    def connect(self): pass
    def close(self): pass

    def points(self):
        return {t: k for t, (k, _) in self.SPEC.items()}

    def read(self, tags):
        for tag in tags:
            spec = self.SPEC.get(tag)
            if not spec:
                continue
            kind, arg = spec
            if kind == "bool":
                if random.random() < 0.05:
                    self.vals[tag] = 0 if self.vals[tag] else 1
            else:
                lo, hi = arg
                step = (hi - lo) * 0.06
                self.vals[tag] = max(lo, min(hi, self.vals[tag] +
                                             (random.random() - 0.5) * step))
        return {t: self.vals[t] for t in tags if t in self.vals}

    def write(self, tag, value):
        if tag in self.SPEC:
            self.vals[tag] = value
            return True
        return False


class SoxDriver(Driver):
    """Sedona SOX 드라이버 (골격).

    ⚠️ 미완성이다. 실제 장비 없이는 완성할 수 없고, 추측으로 채우면
    현장에서 조용히 틀린 값을 표시하게 된다. 필요한 것:

      - 장비의 SOX 프레이밍 확인 (버전에 따라 바이너리 dasp 또는 XML)
      - 컴포넌트/슬롯 주소 ↔ 태그 이름 매핑 규칙
      - 인증 절차와 세션 유지 방식
      - 변경 통지(subscribe) 지원 여부. 없으면 폴링으로 가야 한다

    포트는 5001을 쓴다. 80은 장치 웹서버 전용이라 절대 쓰지 않는다.
    아래 connect()는 TCP 도달성만 확인한다 — 그 이상을 하는 척하지 않는다.
    """

    name = "sox"
    PORT = 5001

    def __init__(self, host: str, timeout: float = 5.0):
        self.host, self.timeout = host, timeout
        self.sock: socket.socket | None = None

    def connect(self):
        self.sock = socket.create_connection((self.host, self.PORT), self.timeout)
        print(f"[sox] {self.host}:{self.PORT} TCP 연결됨 "
              f"— 프로토콜 핸드셰이크는 미구현")

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def points(self):
        raise NotImplementedError(
            "SOX 포인트 조회 미구현 — 장비의 컴포넌트 트리 덤프가 필요합니다")

    def read(self, tags):
        raise NotImplementedError(
            "SOX 값 읽기 미구현 — 프레이밍 확인 후 구현해야 합니다")


DRIVERS: dict[str, Callable[..., Driver]] = {
    "mock": MockDriver,
    "sox": SoxDriver,
}


# ==========================================================================
# 2. WebSocket — 표준 라이브러리만으로 구현 (RFC 6455 중 필요한 부분).
# ==========================================================================

def ws_handshake(conn: socket.socket) -> bool:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return False
        data += chunk
        if len(data) > 65536:
            return False

    key = ""
    for line in data.decode("latin-1").split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
    if not key:
        return False

    accept = base64.b64encode(
        hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    conn.sendall(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: " + accept.encode() + b"\r\n\r\n")
    return True


def ws_send(conn: socket.socket, text: str) -> None:
    payload = text.encode()
    n = len(payload)
    if n < 126:
        header = struct.pack("!BB", 0x81, n)
    elif n < 65536:
        header = struct.pack("!BBH", 0x81, 126, n)
    else:
        header = struct.pack("!BBQ", 0x81, 127, n)
    conn.sendall(header + payload)


def ws_recv(conn: socket.socket) -> str | None:
    """텍스트 프레임 하나를 읽는다. 닫힘/오류면 None."""
    def need(n):
        buf = b""
        while len(buf) < n:
            chunk = conn.recv(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    head = need(2)
    if not head:
        return None
    opcode = head[0] & 0x0F
    masked = head[1] & 0x80
    length = head[1] & 0x7F

    if length == 126:
        ext = need(2)
        if not ext:
            return None
        length = struct.unpack("!H", ext)[0]
    elif length == 127:
        ext = need(8)
        if not ext:
            return None
        length = struct.unpack("!Q", ext)[0]

    if length > 1 << 20:            # 1MB 넘는 프레임은 받지 않는다
        return None

    mask = need(4) if masked else b""
    if masked and mask is None:
        return None
    payload = need(length) if length else b""
    if payload is None:
        return None
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    if opcode == 0x8:               # close
        return None
    if opcode == 0x9:               # ping → pong
        conn.sendall(struct.pack("!BB", 0x8A, len(payload)) + payload)
        return ""
    if opcode != 0x1:               # 텍스트만 처리
        return ""
    return payload.decode("utf-8", "replace")


# ==========================================================================
# 3. 브리지 본체
# ==========================================================================

class Client:
    def __init__(self, conn, addr):
        self.conn, self.addr = conn, addr
        self.tags: set[str] = set()
        self.sent: dict[str, float | bool] = {}   # 마지막으로 보낸 값
        self.alive = True
        self.lock = threading.Lock()

    def send(self, obj) -> bool:
        try:
            with self.lock:
                ws_send(self.conn, json.dumps(obj, ensure_ascii=False))
            return True
        except OSError:
            self.alive = False
            return False


class Bridge:
    def __init__(self, driver: Driver, port: int, interval: float = 1.0,
                 deadband: float = 0.05):
        self.driver = driver
        self.port = port
        self.interval = interval
        self.deadband = deadband        # 이보다 작은 변화는 무시 (float)
        self.clients: list[Client] = []
        self.lock = threading.Lock()
        self.stats = {"ticks": 0, "sent": 0, "skipped": 0}

    # ---- 구독 집계 -------------------------------------------------------
    def active_tags(self) -> list[str]:
        with self.lock:
            tags: set[str] = set()
            for c in self.clients:
                if c.alive:
                    tags |= c.tags
        return sorted(tags)

    # ---- 폴링 루프 -------------------------------------------------------
    def poll_loop(self):
        while True:
            time.sleep(self.interval)
            tags = self.active_tags()
            if not tags:
                continue
            try:
                values = self.driver.read(tags)
            except Exception as e:                       # noqa: BLE001
                print(f"[bridge] 읽기 실패: {e}")
                continue

            self.stats["ticks"] += 1
            with self.lock:
                clients = list(self.clients)

            for c in clients:
                if not c.alive:
                    continue
                # 변경분만 추린다. 이게 없으면 포인트 수백 개 현장에서 금방 막힌다.
                delta = {}
                for tag in c.tags:
                    if tag not in values:
                        continue
                    new = values[tag]
                    old = c.sent.get(tag)
                    if old is None or self._changed(old, new):
                        delta[tag] = new
                        c.sent[tag] = new
                    else:
                        self.stats["skipped"] += 1
                if delta:
                    self.stats["sent"] += len(delta)
                    c.send({"op": "values", "data": delta})

            self.reap()

    def _changed(self, old, new) -> bool:
        if isinstance(old, bool) or isinstance(new, bool):
            return bool(old) != bool(new)
        try:
            return abs(float(new) - float(old)) >= self.deadband
        except (TypeError, ValueError):
            return old != new

    def reap(self):
        with self.lock:
            dead = [c for c in self.clients if not c.alive]
            for c in dead:
                try:
                    c.conn.close()
                except OSError:
                    pass
                self.clients.remove(c)
        if dead:
            print(f"[bridge] 클라이언트 {len(dead)}개 정리, "
                  f"남은 연결 {len(self.clients)}개")

    # ---- 클라이언트 처리 --------------------------------------------------
    def serve_client(self, conn, addr):
        if not ws_handshake(conn):
            conn.close()
            return
        client = Client(conn, addr)
        with self.lock:
            self.clients.append(client)
        print(f"[bridge] 연결 {addr} (총 {len(self.clients)})")

        try:
            points = self.driver.points()
        except NotImplementedError as e:
            client.send({"op": "error", "message": str(e)})
            points = {}
        client.send({"op": "hello", "driver": self.driver.name,
                     "interval": self.interval, "points": points})

        try:
            while client.alive:
                msg = ws_recv(conn)
                if msg is None:
                    break
                if not msg:
                    continue
                try:
                    req = json.loads(msg)
                except json.JSONDecodeError:
                    continue
                self.handle(client, req)
        except OSError:
            pass
        finally:
            client.alive = False
            self.reap()

    def handle(self, client: Client, req: dict):
        op = req.get("op")

        if op == "subscribe":
            tags = {str(t) for t in req.get("tags", []) if t}
            # 교체다. 누적이 아니다. 화면을 옮기면 이전 구독은 사라져야 한다.
            client.tags = tags
            client.sent = {k: v for k, v in client.sent.items() if k in tags}
            print(f"[bridge] {client.addr} 구독 {len(tags)}개 "
                  f"(전체 활성 {len(self.active_tags())}개)")
            try:
                values = self.driver.read(sorted(tags))
                client.sent.update(values)
                client.send({"op": "values", "data": values})
            except Exception as e:                       # noqa: BLE001
                client.send({"op": "error", "message": str(e)})

        elif op == "write":
            tag, value = req.get("tag"), req.get("value")
            ok = False
            try:
                ok = self.driver.write(tag, value)
            except Exception as e:                       # noqa: BLE001
                client.send({"op": "error", "message": f"쓰기 실패: {e}"})
            client.send({"op": "write_ack", "tag": tag, "ok": ok})

        elif op == "ping":
            client.send({"op": "pong", "t": req.get("t")})

    # ---- 기동 -------------------------------------------------------------
    def run(self):
        self.driver.connect()
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", self.port))
        srv.listen(16)
        threading.Thread(target=self.poll_loop, daemon=True).start()
        print(f"[bridge] ws://0.0.0.0:{self.port}  드라이버={self.driver.name}  "
              f"주기={self.interval}s")
        try:
            while True:
                conn, addr = srv.accept()
                threading.Thread(target=self.serve_client,
                                 args=(conn, addr), daemon=True).start()
        except KeyboardInterrupt:
            print(f"\n[bridge] 종료. 통계: {self.stats}")
        finally:
            srv.close()
            self.driver.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description="HMI 포인트 브리지")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--driver", choices=sorted(DRIVERS), default="mock")
    ap.add_argument("--device", help="장비 IP (sox 드라이버)")
    ap.add_argument("--interval", type=float, default=1.0, help="폴링 주기(초)")
    ap.add_argument("--deadband", type=float, default=0.05,
                    help="이보다 작은 변화는 전송하지 않음")
    args = ap.parse_args(argv)

    if args.driver == "sox":
        if not args.device:
            ap.error("sox 드라이버에는 --device 가 필요합니다")
        driver = SoxDriver(args.device)
    else:
        driver = MockDriver()

    Bridge(driver, args.port, args.interval, args.deadband).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
