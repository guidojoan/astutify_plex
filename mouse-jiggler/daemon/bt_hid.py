"""Bluetooth HID mouse peripheral.

Registers an HID (0x1124) SDP record over BlueZ's D-Bus ProfileManager1 API
(BlueZ 5 has no hidd/sdptool), sets the adapter's Class of Device so hosts
recognize the Pi as a mouse, registers a NoInputNoOutput pairing agent for
headless "Just Works" pairing, and owns the raw L2CAP control/interrupt
sockets used to send HID movement reports directly (BlueZ's profile
registration here only serves SDP queries; it does not hand back sockets
for HID the way it does for other profiles).

NOTE: this is new, not yet run against real BlueZ/hardware. The SDP record
attribute IDs and the exact pairing handshake are the highest-risk part of
this design -- expect to iterate here while testing against a real Mac
(see mouse-jiggler/README.md, "Verification").
"""
import asyncio
import logging
import socket
import subprocess

from dbus_next import Variant
from dbus_next.aio import MessageBus
from dbus_next.constants import BusType
from dbus_next.errors import DBusError
from dbus_next.service import ServiceInterface, method

logger = logging.getLogger("bt_hid")

BLUEZ_SERVICE = "org.bluez"
ADAPTER_PATH = "/org/bluez/hci0"
PROFILE_PATH = "/astutify/mousejiggler/profile"
AGENT_PATH = "/astutify/mousejiggler/agent"
HID_UUID = "00001124-0000-1000-8000-00805f9b34fb"

PSM_CONTROL = 0x11
PSM_INTERRUPT = 0x13

# Minimal 3-byte relative-mouse HID report descriptor: buttons + dx + dy.
HID_REPORT_DESCRIPTOR = bytes(
    [
        0x05, 0x01,  # Usage Page (Generic Desktop)
        0x09, 0x02,  # Usage (Mouse)
        0xA1, 0x01,  # Collection (Application)
        0x09, 0x01,  #   Usage (Pointer)
        0xA1, 0x00,  #   Collection (Physical)
        0x05, 0x09,  #     Usage Page (Buttons)
        0x19, 0x01,  #     Usage Min (1)
        0x29, 0x03,  #     Usage Max (3)
        0x15, 0x00,  #     Logical Min (0)
        0x25, 0x01,  #     Logical Max (1)
        0x95, 0x03,  #     Report Count (3)
        0x75, 0x01,  #     Report Size (1)
        0x81, 0x02,  #     Input (Data,Var,Abs)   -- 3 button bits
        0x95, 0x01,  #     Report Count (1)
        0x75, 0x05,  #     Report Size (5)
        0x81, 0x03,  #     Input (Const)          -- 5 bits padding
        0x05, 0x01,  #     Usage Page (Generic Desktop)
        0x09, 0x30,  #     Usage (X)
        0x09, 0x31,  #     Usage (Y)
        0x15, 0x81,  #     Logical Min (-127)
        0x25, 0x7F,  #     Logical Max (127)
        0x75, 0x08,  #     Report Size (8)
        0x95, 0x02,  #     Report Count (2)
        0x81, 0x06,  #     Input (Data,Var,Rel)   -- dx, dy
        0xC0,        #   End Collection
        0xC0,        # End Collection
    ]
)


def _sdp_record_xml():
    descriptor_hex = "".join(f"{b:02x}" for b in HID_REPORT_DESCRIPTOR)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<record>
  <attribute id="0x0001"><sequence><uuid value="0x1124"/></sequence></attribute>
  <attribute id="0x0004">
    <sequence>
      <sequence><uuid value="0x0100"/><uint16 value="0x0011"/></sequence>
      <sequence><uuid value="0x0011"/></sequence>
    </sequence>
  </attribute>
  <attribute id="0x0005"><sequence><uuid value="0x1002"/></sequence></attribute>
  <attribute id="0x0006"><sequence><uint16 value="0x656e"/><uint16 value="0x006a"/><uint16 value="0x0100"/></sequence></attribute>
  <attribute id="0x0009"><sequence><sequence><uuid value="0x1124"/><uint16 value="0x0101"/></sequence></sequence></attribute>
  <attribute id="0x0100"><text value="Astutify Mouse Jiggler"/></attribute>
  <attribute id="0x0101"><text value="Bluetooth HID mouse jiggler"/></attribute>
  <attribute id="0x0200"><uint16 value="0x0100"/></attribute>
  <attribute id="0x0201"><uint16 value="0x0111"/></attribute>
  <attribute id="0x0202"><uint8 value="0x02"/></attribute>
  <attribute id="0x0203"><uint8 value="0x21"/></attribute>
  <attribute id="0x0204"><boolean value="true"/></attribute>
  <attribute id="0x0205"><boolean value="false"/></attribute>
  <attribute id="0x0206">
    <sequence>
      <sequence>
        <uint8 value="0x22"/>
        <text encoding="hex" value="{descriptor_hex}"/>
      </sequence>
    </sequence>
  </attribute>
  <attribute id="0x020b"><uint16 value="0x0100"/></attribute>
  <attribute id="0x020c"><uint16 value="0x0640"/></attribute>
  <attribute id="0x020d"><boolean value="false"/></attribute>
  <attribute id="0x020e"><boolean value="true"/></attribute>
</record>"""


class HIDProfile(ServiceInterface):
    """org.bluez.Profile1 -- registered purely so BlueZ answers SDP queries
    for the HID UUID. Actual data flows over the raw L2CAP sockets below."""

    def __init__(self):
        super().__init__("org.bluez.Profile1")

    @method()
    def Release(self):
        logger.info("HID profile released by BlueZ")

    @method()
    def NewConnection(self, device: "o", fd: "h", fd_properties: "a{sv}"):
        logger.info("NewConnection callback for %s (unused; HID uses raw L2CAP sockets)", device)

    @method()
    def RequestDisconnection(self, device: "o"):
        logger.info("RequestDisconnection for %s", device)


class NoInputNoOutputAgent(ServiceInterface):
    """org.bluez.Agent1 that auto-accepts everything ("Just Works" pairing),
    the only viable flow for a headless Pi."""

    def __init__(self):
        super().__init__("org.bluez.Agent1")

    @method()
    def Release(self):
        pass

    @method()
    def RequestPinCode(self, device: "o") -> "s":
        return "0000"

    @method()
    def DisplayPinCode(self, device: "o", pincode: "s"):
        pass

    @method()
    def RequestPasskey(self, device: "o") -> "u":
        return 0

    @method()
    def DisplayPasskey(self, device: "o", passkey: "u", entered: "q"):
        pass

    @method()
    def RequestConfirmation(self, device: "o", passkey: "u"):
        pass

    @method()
    def RequestAuthorization(self, device: "o"):
        pass

    @method()
    def AuthorizeService(self, device: "o", uuid: "s"):
        pass

    @method()
    def Cancel(self):
        pass


class BluetoothHID:
    def __init__(self, on_state_change=None):
        self._bus = None
        self._control_sock = None
        self._interrupt_sock = None
        self._control_conn = None
        self._interrupt_conn = None
        self._peer_address = None
        self._on_state_change = on_state_change or (lambda **kw: None)
        self._accept_task = None

    async def start(self):
        self._set_class_of_device()
        self._bus = await MessageBus(bus_type=BusType.SYSTEM).connect()

        self._bus.export(PROFILE_PATH, HIDProfile())
        self._bus.export(AGENT_PATH, NoInputNoOutputAgent())

        introspection = await self._bus.introspect(BLUEZ_SERVICE, "/org/bluez")
        obj = self._bus.get_proxy_object(BLUEZ_SERVICE, "/org/bluez", introspection)
        profile_mgr = obj.get_interface("org.bluez.ProfileManager1")
        agent_mgr = obj.get_interface("org.bluez.AgentManager1")

        await self._register_profile_with_retry(profile_mgr)
        await agent_mgr.call_register_agent(AGENT_PATH, "NoInputNoOutput")
        await agent_mgr.call_request_default_agent(AGENT_PATH)

        self._control_sock = self._make_listening_socket(PSM_CONTROL)
        self._interrupt_sock = self._make_listening_socket(PSM_INTERRUPT)
        self._accept_task = asyncio.create_task(self._accept_loop())
        logger.info("Bluetooth HID mouse profile registered, listening on PSM 0x11/0x13")

    async def _register_profile_with_retry(self, profile_mgr, attempts=5, delay=1.0):
        # If this daemon was just restarted after a crash, BlueZ may not yet
        # have released the HID UUID registration held by the previous
        # instance's now-closed D-Bus connection -- that cleanup isn't
        # instantaneous, and systemd's RestartSec can easily be faster than
        # it. Retry instead of dying, so a crash-restart storm self-heals.
        opts = {
            "ServiceRecord": Variant("s", _sdp_record_xml()),
            "Role": Variant("s", "server"),
            "RequireAuthentication": Variant("b", False),
            "RequireAuthorization": Variant("b", False),
            "AutoConnect": Variant("b", True),
        }
        for attempt in range(1, attempts + 1):
            try:
                await profile_mgr.call_register_profile(PROFILE_PATH, HID_UUID, opts)
                return
            except DBusError as exc:
                if attempt == attempts:
                    raise
                logger.warning(
                    "RegisterProfile failed (%s), retrying in %.1fs (attempt %d/%d)",
                    exc,
                    delay,
                    attempt,
                    attempts,
                )
                await asyncio.sleep(delay)

    @staticmethod
    def _set_class_of_device():
        # Best-effort only: /etc/bluetooth/main.conf's [General] Class=
        # (set by install.sh) is the durable source of truth, applied by
        # bluetoothd itself on every restart. btmgmt can hang indefinitely
        # if it races bluetoothd for the adapter, so it must never be
        # allowed to block daemon startup.
        try:
            subprocess.run(
                ["btmgmt", "class", "0x05", "0xC0"],
                check=True,
                capture_output=True,
                timeout=5,
            )
        except subprocess.TimeoutExpired:
            logger.warning(
                "btmgmt class command timed out after 5s; relying on "
                "/etc/bluetooth/main.conf Class= instead"
            )
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            logger.warning("Could not set Class of Device via btmgmt: %s", exc)

    @staticmethod
    def _make_listening_socket(psm):
        sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
        sock.bind(("00:00:00:00:00:00", psm))
        sock.listen(1)
        sock.setblocking(False)
        return sock

    async def _accept_loop(self):
        loop = asyncio.get_running_loop()
        while True:
            try:
                ctrl_conn, _ctrl_addr = await loop.sock_accept(self._control_sock)
                intr_conn, intr_addr = await loop.sock_accept(self._interrupt_sock)
            except OSError as exc:
                logger.error("L2CAP accept failed: %s", exc)
                await asyncio.sleep(1)
                continue

            ctrl_conn.setblocking(False)
            intr_conn.setblocking(True)
            self._control_conn = ctrl_conn
            self._interrupt_conn = intr_conn
            self._peer_address = intr_addr[0] if isinstance(intr_addr, tuple) else str(intr_addr)
            logger.info("Bluetooth peer connected: %s", self._peer_address)
            self._on_state_change(connected=True, peer=self._peer_address)
            asyncio.create_task(self._drain_control_channel(ctrl_conn))

    async def _drain_control_channel(self, ctrl_conn):
        # The control channel must stay open for the life of the connection
        # -- HID hosts (macOS included) use it for the handshake/protocol
        # messages, and treat it disappearing as reason to tear the whole
        # link down. We don't need to act on anything sent over it, just
        # keep it open and notice if the peer closes it.
        loop = asyncio.get_running_loop()
        try:
            while True:
                data = await loop.sock_recv(ctrl_conn, 64)
                if not data:
                    break
        except OSError:
            pass
        finally:
            if self._control_conn is ctrl_conn:
                self.reset_connection()

    def send_move(self, dx, dy, buttons=0):
        if not self._interrupt_conn:
            return False
        report = bytes([0xA1, buttons & 0xFF, dx & 0xFF, dy & 0xFF])
        try:
            self._interrupt_conn.send(report)
            return True
        except OSError as exc:
            logger.warning("Failed to send HID report, dropping connection: %s", exc)
            self.reset_connection()
            return False

    def reset_connection(self):
        for conn in (self._interrupt_conn, self._control_conn):
            if conn:
                try:
                    conn.close()
                except OSError:
                    pass
        self._interrupt_conn = None
        self._control_conn = None
        self._peer_address = None
        self._on_state_change(connected=False, peer=None)

    @property
    def connected(self):
        return self._interrupt_conn is not None

    @property
    def peer_address(self):
        return self._peer_address

    async def set_discoverable(self, discoverable, timeout_s=120):
        introspection = await self._bus.introspect(BLUEZ_SERVICE, ADAPTER_PATH)
        obj = self._bus.get_proxy_object(BLUEZ_SERVICE, ADAPTER_PATH, introspection)
        props = obj.get_interface("org.freedesktop.DBus.Properties")
        await props.call_set("org.bluez.Adapter1", "DiscoverableTimeout", Variant("u", timeout_s))
        await props.call_set("org.bluez.Adapter1", "Pairable", Variant("b", discoverable))
        await props.call_set("org.bluez.Adapter1", "Discoverable", Variant("b", discoverable))
