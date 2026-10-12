#!/usr/bin/env python3
"""Minimal LocalSend v2 client (stdlib only): discover devices and send files.

    ./localsend-send.py discover
    ./localsend-send.py send --to 9se FILE [FILE...]
    ./localsend-send.py send --to 10.0.0.5 --pin 1234 FILE

Notes
-----
* LocalSend 2.1+ receivers may serve their API over HTTPS and require a client
  certificate (mutual TLS). This script reuses the certificate of the LocalSend
  app installed on this machine (~/.local/share/org.localsend.localsend_app/
  shared_preferences.json -> flutter.ls_security_context), so an HTTPS-only
  peer is reachable without driving the GUI.
* The receiver shows an "accept" prompt on the phone; tap Accept and the
  transfer starts. With "Quick Save" enabled on the phone there is no prompt.
"""
import argparse
import concurrent.futures
import http.client
import json
import os
import pathlib
import random
import socket
import ssl
import string
import sys
import time
import urllib.parse

MULTICAST_ADDR = "224.0.0.167"
MULTICAST_PORT = 53317
HTTP_PORT = 53317
LS_PREFS = pathlib.Path.home() / ".local/share/org.localsend.localsend_app/shared_preferences.json"
CERT_DIR = pathlib.Path(__file__).resolve().parent.parent / ".ls-client"


# --------------------------------------------------------------------------- #
# identity / TLS
# --------------------------------------------------------------------------- #
def fingerprint():
    return "".join(random.choices(string.ascii_letters + string.digits, k=32))


def device_info(alias, port=HTTP_PORT, protocol="http", fp=None):
    return {
        "alias": alias,
        "version": "2.0",
        "deviceModel": "Linux",
        "deviceType": "desktop",
        "fingerprint": fp or fingerprint(),
        "port": port,
        "protocol": protocol,
        "download": False,
    }


def own_fingerprint():
    try:
        prefs = json.loads(LS_PREFS.read_text())
        return json.loads(prefs["flutter.ls_security_context"])["certificateHash"]
    except Exception:
        return None


def mtls_context():
    """SSL context carrying the local LocalSend app's client certificate."""
    try:
        prefs = json.loads(LS_PREFS.read_text())
        sc = json.loads(prefs["flutter.ls_security_context"])
    except Exception:
        return None
    CERT_DIR.mkdir(exist_ok=True)
    cert, key = CERT_DIR / "cert.pem", CERT_DIR / "key.pem"
    cert.write_text(sc["certificate"])
    key.write_text(sc["privateKey"])
    cert.chmod(0o600)
    key.chmod(0o600)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        ctx.load_cert_chain(str(cert), str(key))
    except ssl.SSLError:
        return None
    return ctx


def plain_tls_context():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
def http_request(host, port, method, path, body=None, headers=None, timeout=15,
                 ssl_ctx=None, raw_body=None):
    cls = http.client.HTTPSConnection if ssl_ctx is not None else http.client.HTTPConnection
    kwargs = {"timeout": timeout}
    if ssl_ctx is not None:
        kwargs["context"] = ssl_ctx
    conn = cls(host, port, **kwargs)
    try:
        hdrs = dict(headers or {})
        payload = raw_body
        if body is not None:
            payload = json.dumps(body).encode()
            hdrs.setdefault("Content-Type", "application/json")
        conn.request(method, path, body=payload, headers=hdrs)
        resp = conn.getresponse()
        return resp.status, dict(resp.getheaders()), resp.read()
    finally:
        conn.close()


def request_json(host, port, method, path, body=None, timeout=15, ssl_ctx=None):
    status, _, data = http_request(host, port, method, path, body=body,
                                   timeout=timeout, ssl_ctx=ssl_ctx)
    try:
        return status, json.loads(data.decode() or "{}")
    except json.JSONDecodeError:
        return status, {"_raw": data[:300].decode(errors="replace")}


def probe(ip, port=HTTP_PORT, timeout=2.0):
    """Return (device_info, scheme_label, ssl_ctx) for a LocalSend peer, or None."""
    mtls = mtls_context()
    for label, ctx in (("http", None), ("https", plain_tls_context()), ("https+mtls", mtls)):
        if label == "https+mtls" and ctx is None:
            continue
        try:
            status, dev = request_json(ip, port, "GET", "/api/localsend/v2/info",
                                       timeout=timeout, ssl_ctx=ctx)
        except Exception:
            continue
        if status == 200 and isinstance(dev, dict) and dev.get("fingerprint"):
            return dev, label, ctx
    return None


# --------------------------------------------------------------------------- #
# discovery
# --------------------------------------------------------------------------- #
def local_ips():
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            ip = info[4][0]
            if ":" not in ip:
                ips.add(ip)
    except socket.gaierror:
        pass
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
    except OSError:
        pass
    finally:
        s.close()
    return ips


def multicast_discover(timeout=5.0, alias="dsh"):
    info = device_info(alias, fp=own_fingerprint() or fingerprint())
    msg = json.dumps(info).encode()
    found = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("", MULTICAST_PORT))
    except OSError:
        sock.bind(("", 0))
    sock.settimeout(0.5)
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        for iface in local_ips():
            try:
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(iface))
            except OSError:
                pass
        sock.sendto(msg, (MULTICAST_ADDR, MULTICAST_PORT))
    except OSError as exc:
        print(f"  multicast send failed: {exc}", file=sys.stderr)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            continue
        except OSError:
            break
        try:
            dev = json.loads(data.decode())
        except json.JSONDecodeError:
            continue
        if isinstance(dev, dict) and dev.get("fingerprint") != info["fingerprint"]:
            dev["ip"] = addr[0]
            found[dev["fingerprint"]] = dev
    sock.close()
    return list(found.values())


def neighbour_ips():
    """IPs with a resolved MAC in the kernel ARP table (fast, no scanning)."""
    ips = []
    try:
        with open("/proc/net/arp") as fh:
            next(fh)
            for line in fh:
                parts = line.split()
                if len(parts) >= 4 and parts[3] != "00:00:00:00:00:00":
                    ips.append(parts[0])
    except OSError:
        pass
    return ips


def probe_many(ips, timeout=2.0, max_workers=32, port=HTTP_PORT):
    found = {}
    own = own_fingerprint()

    def work(ip):
        got = probe(ip, port=port, timeout=timeout)
        if got:
            dev, label, _ = got
            if dev.get("fingerprint") != own:
                dev["ip"] = ip
                dev["scheme"] = label
                return dev
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        for dev in pool.map(work, ips):
            if dev:
                found[dev["fingerprint"]] = dev
    return list(found.values())


def subnet_scan(timeout=1.0, port=HTTP_PORT):
    prefixes = set()
    for ip in local_ips():
        if ip.startswith(("127.", "172.1", "172.2", "169.254")):
            continue
        prefixes.add(ip.rsplit(".", 1)[0])
    return probe_many([f"{p}.{h}" for p in prefixes for h in range(1, 255)],
                      timeout=timeout, max_workers=128, port=port)


def print_devices(devices):
    if not devices:
        print("  (no LocalSend device found)")
        return
    for dev in sorted(devices, key=lambda d: str(d.get("alias", ""))):
        print(f"  {dev.get('alias','?'):<22} {dev.get('ip','?'):<16} "
              f"{dev.get('scheme', dev.get('protocol','http')):<11} "
              f"ver={dev.get('version','?'):<4} type={dev.get('deviceType','?'):<7} "
              f"model={dev.get('deviceModel','?')}")


def find_target(devices, target):
    for dev in devices:
        if dev.get("ip") == target:
            return dev
    t = target.lower()
    for dev in devices:
        if t and t in str(dev.get("alias", "")).lower():
            return dev
    return None


def discover_all(args):
    devices = {d["fingerprint"]: d for d in multicast_discover(args.timeout, args.alias)}
    neigh = neighbour_ips()
    if neigh:
        devices.update({d["fingerprint"]: d for d in probe_many(neigh)})
    return list(devices.values())


# --------------------------------------------------------------------------- #
# sending
# --------------------------------------------------------------------------- #
def send_file(dev, path, sender, pin=None):
    host, port = dev["ip"], int(dev.get("port", HTTP_PORT))
    label = dev.get("scheme", "http")
    ctx = None
    if label.startswith("https"):
        ctx = mtls_context() if label.endswith("mtls") else plain_tls_context()
    size, name = os.path.getsize(path), os.path.basename(path)
    file_id = fingerprint()[:16]

    try:
        request_json(host, port, "POST", "/api/localsend/v2/register", body=sender,
                     timeout=10, ssl_ctx=ctx)
    except Exception as exc:
        print(f"    register: {exc} (continuing)", file=sys.stderr)

    body = {"info": sender, "files": {file_id: {
        "id": file_id, "fileName": name, "size": size,
        "fileType": "application/octet-stream", "sha256": None, "preview": None}}}
    query = f"?pin={urllib.parse.quote(pin)}" if pin else ""
    print(f"    prepare-upload -> {host}:{port} ({label})")
    try:
        status, resp = request_json(host, port, "POST",
                                    f"/api/localsend/v2/prepare-upload{query}",
                                    body=body, timeout=180, ssl_ctx=ctx)
    except Exception as exc:
        return False, f"prepare-upload failed: {exc}"
    if status == 401:
        return False, "receiver wants a PIN (--pin <code shown on the phone>)"
    if status == 403:
        return False, "receiver declined the transfer"
    if status == 429:
        return False, "receiver busy (another transfer running)"
    if status != 200:
        return False, f"prepare-upload HTTP {status}: {resp}"
    session = resp.get("sessionId")
    token = (resp.get("files") or {}).get(file_id)
    if not session or not token:
        return False, f"unexpected prepare-upload response: {resp}"

    print(f"    uploading {name} ({size/1048576:.1f} MB)…")
    with open(path, "rb") as fh:
        payload = fh.read()
    q = (f"/api/localsend/v2/upload?sessionId={urllib.parse.quote(session)}"
         f"&fileId={urllib.parse.quote(file_id)}&token={urllib.parse.quote(str(token))}")
    try:
        status, headers, data = http_request(
            host, port, "POST", q,
            headers={"Content-Type": "application/octet-stream",
                     "Content-Length": str(len(payload))},
            raw_body=payload, timeout=1800, ssl_ctx=ctx)
    except Exception as exc:
        return False, f"upload failed: {exc}"
    if status in (200, 204):
        return True, f"uploaded ({size/1048576:.1f} MB)"
    return False, f"upload HTTP {status}: {data[:200]!r}"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("discover", help="find LocalSend devices")
    d.add_argument("--timeout", type=float, default=4.0)
    d.add_argument("--alias", default=socket.gethostname() or "dsh")
    d.add_argument("--scan", action="store_true", help="also scan every host on the /24")

    s = sub.add_parser("send", help="send files")
    s.add_argument("--to", required=True, help="alias (e.g. 9se) or IP address")
    s.add_argument("--pin", default=None)
    s.add_argument("--alias", default=socket.gethostname() or "dsh")
    s.add_argument("--timeout", type=float, default=4.0)
    s.add_argument("files", nargs="+")

    args = ap.parse_args()

    if args.cmd == "discover":
        print("LocalSend 设备 / devices:")
        devices = discover_all(args)
        print_devices(devices)
        if args.scan:
            print("full /24 scan…")
            devices = {d_["fingerprint"]: d_ for d_ in devices}
            devices.update({d_["fingerprint"]: d_ for d_ in subnet_scan()})
            print_devices(list(devices.values()))
        return 0 if devices else 2

    for path in args.files:
        if not os.path.isfile(path):
            print(f"no such file: {path}", file=sys.stderr)
            return 1

    print(f"looking for {args.to!r} …")
    dev = find_target(discover_all(args), args.to)
    if dev is None:
        print("  not in multicast/ARP, scanning subnet …")
        dev = find_target(subnet_scan(), args.to)
    if dev is None:
        print(f"  no LocalSend device matches {args.to!r}", file=sys.stderr)
        return 2

    print(f"  target: {dev.get('alias')} @ {dev['ip']}:{dev.get('port', HTTP_PORT)} "
          f"[{dev.get('scheme','?')}]")
    sender = device_info(args.alias)
    rc = 0
    for path in args.files:
        good, msg = send_file(dev, path, sender, pin=args.pin)
        print(("  OK   " if good else "  FAIL ") + f"{os.path.basename(path)}: {msg}")
        if not good:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
