# fake-obs.py — 在 8765 上伪造 StreamDockOBSPlugin 的 JSON-RPC 2.0,验证 OBS 插件全链路(无需真 OBS)
# 用法:python3 Scripts/fake-obs.py  (后台跑,插件的 3 秒重连会自动接入;M2 验收辅助,协议逆向自插件 bundle)
import socket, base64, hashlib, os, json, threading, time, sys

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
state = {"streaming": False, "recording": False}

def log(*a): print("[fakeOBS]", *a, flush=True)

def handle_client(conn):
    buf = b""
    # 握手
    while b"\r\n\r\n" not in buf:
        buf += conn.recv(4096)
    head, buf = buf.split(b"\r\n\r\n", 1)
    key = [l for l in head.decode().split("\r\n") if "SEC-WEBSOCKET-KEY" in l.upper()][0].split(":",1)[1].strip()
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    conn.sendall((f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    log("插件已连入(握手完成)")
    def demo():
        time.sleep(2)
        while True:
            state["streaming"] = not state["streaming"]
            evt = "streaming.started" if state["streaming"] else "streaming.stopped"
            push(evt)
            log("已推送", evt)
            time.sleep(5)
    threading.Thread(target=demo, daemon=True).start()

    def send_text(s):
        payload = s.encode()
        header = bytes([0x81, len(payload)]) if len(payload) < 126 else bytes([0x81, 126]) + len(payload).to_bytes(2, "big")
        conn.sendall(header + payload)

    def reply(id_, result):
        send_text(json.dumps({"jsonrpc": "2.0", "id": id_, "result": result}))

    def push(event_type, data=None):
        send_text(json.dumps({"jsonrpc": "2.0", "method": "event",
                              "params": {"event_type": event_type, "data": data or {}}}))

    def dispatch(msg):
        method = msg.get("method"); id_ = msg.get("id"); params = msg.get("params") or {}
        log("<<", json.dumps(msg, ensure_ascii=False)[:160])
        if id_ is None:
            return  # ping 等
        if method == "version":
            reply(id_, {"version": "3.1.0", "obs_version": "31.0.0"})
        elif method == "events.get_available":
            reply(id_, ["streaming.started", "streaming.stopped", "recording.started", "recording.stopped", "scene.changed"])
        elif method == "events.get_subscriptions":
            reply(id_, [])
        elif method == "events.subscribe":
            reply(id_, 0)
        elif method == "events.unsubscribe":
            reply(id_, 0)
        elif method == "streaming.active":
            reply(id_, state["streaming"])  # 裸布尔:插件按 result 直接当真值用
        elif method == "streaming.start":
            state["streaming"] = True
            reply(id_, {})
            push("streaming.started")
        elif method == "streaming.stop":
            state["streaming"] = False
            reply(id_, {})
            push("streaming.stopped")
        elif method == "recording.active":
            reply(id_, state["recording"])
        elif method == "recording.start":
            state["recording"] = True; reply(id_, {}); push("recording.started")
        elif method == "recording.stop":
            state["recording"] = False; reply(id_, {}); push("recording.stopped")
        else:
            reply(id_, {})

    try:
        while True:
            while len(buf) < 2:
                buf += conn.recv(4096)
            opcode = buf[0] & 0x0F; masked = buf[1] & 0x80
            length = buf[1] & 0x7F; off = 2
            if length == 126: length = int.from_bytes(buf[2:4], "big"); off = 4
            elif length == 127: length = int.from_bytes(buf[2:10], "big"); off = 10
            mask = None
            if masked: mask = buf[off:off+4]; off += 4
            while len(buf) < off + length:
                buf += conn.recv(65536)
            payload = buf[off:off+length]
            if masked: payload = bytes(p ^ mask[i % 4] for i, p in enumerate(payload))
            buf = buf[off+length:]
            if opcode == 0x8:
                log("插件关闭连接"); return
            if opcode == 0x1:
                try: dispatch(json.loads(payload))
                except Exception as e: log("解析失败:", e)
    except Exception as e:
        log("连接异常:", e)

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 8765)); srv.listen(2)
log("假 OBS 就绪 @:8765,等插件连入…")
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle_client, args=(c,), daemon=True).start()
