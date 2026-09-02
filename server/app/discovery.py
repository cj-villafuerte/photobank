"""LAN discovery: announce this server over mDNS/Bonjour so the mobile app
can find it LocalSend-style instead of asking for an IP address."""

import logging
import socket

from zeroconf import ServiceInfo, Zeroconf

log = logging.getLogger("photobank.discovery")

SERVICE_TYPE = "_photobank._tcp.local."


def _local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))  # no packets sent; just picks the outbound interface
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def register(port: int) -> tuple[Zeroconf, ServiceInfo] | None:
    try:
        hostname = socket.gethostname()
        ip = _local_ip()
        info = ServiceInfo(
            SERVICE_TYPE,
            f"Photobank on {hostname}.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(ip)],
            port=port,
            properties={"name": hostname, "version": "1"},
            server=f"{hostname}.local.",
        )
        zc = Zeroconf()
        zc.register_service(info)
        log.info("mDNS: announcing Photobank at %s:%s", ip, port)
        return zc, info
    except Exception:
        log.exception("mDNS registration failed - discovery disabled, server still reachable by IP")
        return None


def unregister(handle: tuple[Zeroconf, ServiceInfo] | None) -> None:
    if handle is None:
        return
    zc, info = handle
    try:
        zc.unregister_service(info)
        zc.close()
    except Exception:
        pass
