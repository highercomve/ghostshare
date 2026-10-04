#!/usr/bin/env python3
"""Run under Oriel headless.sh: isolated portal, notifications and tray tests."""
import ctypes
import multiprocessing as mp
import os
from pathlib import Path
import subprocess
import tempfile
import time

from gi.repository import Gio, GLib
from quickshare_loopback import port, worker, request

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
notifications = []
xml = """<node><interface name="org.freedesktop.Notifications">
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
</interface><interface name="org.freedesktop.portal.Settings">
<method name="ReadOne"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<signal name="SettingChanged"><arg type="s"/><arg type="s"/><arg type="v"/></signal>
</interface></node>"""
info = Gio.DBusNodeInfo.new_for_xml(xml)

def method(connection, sender, path, interface, name, parameters, invocation):
    if name == "ReadOne": invocation.return_value(GLib.Variant("(v)", (GLib.Variant("u", 1),)))
    elif name == "Notify":
        notifications.append(parameters.unpack())
        invocation.return_value(GLib.Variant("(u)", (1,)))
    elif name == "GetCapabilities": invocation.return_value(GLib.Variant("(as)", (["actions", "body"],)))
    elif name == "GetServerInformation": invocation.return_value(GLib.Variant("(ssss)", ("test", "GhostFile", "1", "1.2")))
    else: invocation.return_value(None)

def command(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode: raise AssertionError(str(args) + result.stderr)
    return result.stdout.strip()

def pump(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        while GLib.MainContext.default().pending(): GLib.MainContext.default().iteration(False)
        if predicate(): return
        time.sleep(.05)
    raise AssertionError("Desktop action timed out")

def dbus(destination, path, method_name, *args):
    return command("gdbus", "call", "--session", "--dest", destination, "--object-path", path, "--method", method_name, *args)

def close_window(window):
    # WM_DELETE_WINDOW, sent without a window manager on the private Xvfb.
    class ClientMessage(ctypes.Structure):
        _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int), ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong), ("format", ctypes.c_int), ("data", ctypes.c_long * 5)]
    class Event(ctypes.Union):
        _fields_ = [("client", ClientMessage), ("padding", ctypes.c_long * 24)]
    x = ctypes.CDLL("libX11.so.6")
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]; x.XOpenDisplay.restype = ctypes.c_void_p
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]; x.XInternAtom.restype = ctypes.c_ulong
    x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(Event)]
    x.XFlush.argtypes = [ctypes.c_void_p]; x.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x.XOpenDisplay(None)
    event = Event()
    event.client.type = 33; event.client.display = display; event.client.window = int(window)
    event.client.message_type = x.XInternAtom(display, b"WM_PROTOCOLS", 0); event.client.format = 32
    event.client.data[0] = x.XInternAtom(display, b"WM_DELETE_WINDOW", 0)
    x.XSendEvent(display, int(window), 0, 0, ctypes.byref(event)); x.XFlush(display); x.XCloseDisplay(display)

def visible():
    return subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "^GhostFile$"], capture_output=True).returncode == 0

def main():
    assert os.environ.get("ORIEL_HEADLESS_INNER"), "Use Oriel headless.sh to isolate the desktop"
    mp.set_start_method("spawn")
    for name in ["org.freedesktop.Notifications", "org.freedesktop.portal.Desktop"]:
        bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", GLib.Variant("(su)", (name, 0)), None, Gio.DBusCallFlags.NONE, 1000, None)
    bus.register_object("/org/freedesktop/Notifications", info.interfaces[0], method, None, None)
    bus.register_object("/org/freedesktop/portal/desktop", info.interfaces[1], method, None, None)
    with tempfile.TemporaryDirectory(prefix="ghostfile-desktop-") as temporary:
        folder = Path(temporary)
        receiver_port = port()
        app = subprocess.Popen(["./zig-out/bin/ghostfile"], env=dict(os.environ, GHOSTFILE_PORT=str(receiver_port), GHOSTFILE_DOWNLOAD_DIR=str(folder / "received")), stdout=open("artifacts/desktop.log", "w"), stderr=subprocess.STDOUT)
        sender, child = mp.Pipe()
        engine = mp.Process(target=worker, args=(child, folder / "sender", port()))
        engine.start(); child.close()
        try:
            pump(visible)
            assert sender.poll(15) and sender.recv()["ok"]
            window = command("xdotool", "search", "--onlyvisible", "--name", "^GhostFile$").splitlines()[0]
            tray = f"org.kde.StatusNotifierItem-{app.pid}-1"
            pump(lambda: tray in bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", None, None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0])
            dbus(tray, "/MenuBar", "com.canonical.dbusmenu.GetLayout", "0", "3", "[]")
            command("import", "-window", "root", "artifacts/system-dark.png")
            bus.emit_signal(None, "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged", GLib.Variant("(ssv)", ("org.freedesktop.appearance", "color-scheme", GLib.Variant("u", 2))))
            time.sleep(.5)
            command("import", "-window", "root", "artifacts/system-light.png")
            from PIL import Image
            assert Image.open("artifacts/system-dark.png").getpixel((20, 100)) == (32, 35, 31)
            assert Image.open("artifacts/system-light.png").getpixel((20, 100)) == (245, 241, 233)
            close_window(window)
            pump(lambda: not visible())
            path = folder / "received-test.txt"; path.write_text("Encrypted desktop integration test\n")
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Desktop", paths=[str(path)])
            pump(lambda: notifications)
            assert app.poll() is None and not visible(), "Receiving must continue while hidden"
            assert not list((folder / "received").iterdir()), "Notification must not auto-accept"
            bus.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked", GLib.Variant("(us)", (1, "default")))
            pump(visible)
            time.sleep(1)
            command("import", "-window", "root", "artifacts/incoming-ui.png")
            command("xdotool", "mousemove", "--window", window, "284", "526", "click", "1")
            pump(lambda: subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "Save incoming files"], capture_output=True).returncode == 0)
            folder_dialog = command("xdotool", "search", "--onlyvisible", "--name", "Save incoming files").splitlines()[0]
            command("xdotool", "windowfocus", "--sync", folder_dialog)
            command("xdotool", "key", "Escape")
            pump(lambda: subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "Save incoming files"], capture_output=True).returncode != 0)
            assert not list((folder / "received").iterdir()), "Cancelling the folder picker must leave approval pending"
            time.sleep(.5)
            command("xdotool", "mousemove", "--window", window, "138", "526", "click", "1")
            pump(lambda: (folder / "received" / path.name).exists() and (folder / "received" / path.name).read_bytes() == path.read_bytes())
            pump(lambda: len(notifications) >= 2)
            assert notifications[-1][3] == "Files received"
            command("xdotool", "mousemove", "--window", window, "900", "700", "click", "5", "click", "5")
            time.sleep(.5)
            command("import", "-window", "root", "artifacts/received-ui.png")
            dbus(tray, "/MenuBar", "com.canonical.dbusmenu.Event", "2", "clicked", "<0>", "0")
            pump(lambda: subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "Choose a file to share"], capture_output=True).returncode == 0)
            # Quitting from the tray must cancel an open picker and stop cleanly.
            dbus(tray, "/MenuBar", "com.canonical.dbusmenu.Event", "4", "clicked", "<0>", "0")
            pump(lambda: app.poll() is not None)
            assert app.returncode == 0
            print("PASS: background receiving, clickable notifications, folder picker cancellation, default consent, tray send, live theme, quit with picker open")
        finally:
            if app.poll() is None:
                app.kill(); app.wait(8)
            sender.send(None); engine.join(8)
            if engine.is_alive(): engine.terminate(); engine.join()

if __name__ == "__main__": main()
