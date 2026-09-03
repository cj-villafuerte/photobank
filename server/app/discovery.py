"""LAN discovery: announce this server over mDNS/Bonjour so the mobile app
can find it LocalSend-style instead of asking for an IP address."""

import logging
import socket

from zeroconf import ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

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


async def register(port: int) -> tuple[AsyncZeroconf, ServiceInfo] | None:
    try:
        hostname = socket.gethostname()
        ip = _local_ip()
        info = ServiceInfo(
            SERVICE_TYPE,
            f"Photobank on {hostname}.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(ip)],
            port=port,
            properties={"name": hostname, "version": "1", "ip": ip},
            server=f"{hostname}.local.",
        )
        azc = AsyncZeroconf()
        await azc.async_register_service(info)
        log.info("mDNS: announcing Photobank at %s:%s", ip, port)
        return azc, info
    except Exception:
        log.exception("mDNS registration failed - discovery disabled, server still reachable by IP")
        return None


async def unregister(handle: tuple[AsyncZeroconf, ServiceInfo] | None) -> None:
    if handle is None:
        return
    azc, info = handle
    try:
        await azc.async_unregister_service(info)
        await azc.async_close()
    except Exception:
        pass
