#!/usr/bin/env python3
"""Exercise the real encrypted Quick Share protocol in two isolated processes."""
import ctypes
import json
import multiprocessing as mp
import os
from pathlib import Path
import socket
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]

def worker(connection, directory, bind_port):
    os.environ["GHOSTFILE_PORT"] = str(bind_port)
    library = ctypes.CDLL(str(ROOT / "target/release/libghostfile_quickshare.so"))
    for name in ("ghostfile_start", "ghostfile_request"):
        fn = getattr(library, name)
        fn.argtypes = [ctypes.c_char_p]
        fn.restype = ctypes.c_void_p
    library.ghostfile_free.argtypes = [ctypes.c_void_p]
    def invoke(fn, value):
        pointer = fn(value)
        assert pointer
        try:
            result = json.loads(ctypes.string_at(pointer))
        finally:
            library.ghostfile_free(pointer)
        return result
    connection.send(invoke(library.ghostfile_start, os.fsencode(directory)))
    try:
        while True:
            value = connection.recv()
            if value is None:
                break
            connection.send(invoke(library.ghostfile_request, json.dumps(value).encode()))
    finally:
        library.ghostfile_stop()
        connection.close()

def request(connection, command, **args):
    connection.send(dict(command=command, **args))
    assert connection.poll(12), "engine did not answer"
    result = connection.recv()
    assert result["ok"], result
    return result["data"]

def wait(connection, predicate):
    deadline = time.monotonic() + 20
    last = None
    while time.monotonic() < deadline:
        last = request(connection, "snapshot")
        match = next((t for t in last["transfers"] if predicate(t)), None)
        if match:
            return match
        time.sleep(0.1)
    raise AssertionError(last)

def main():
    mp.set_start_method("spawn")
    with tempfile.TemporaryDirectory(prefix="ghostfile-test-") as temporary:
        directory = Path(temporary)
        destination = directory / "received"
        destination.mkdir()
        sender_port, receiver_port = port(), port()
        processes, connections = [], []
        for folder, bind_port in ((directory / "sender", sender_port), (destination, receiver_port)):
            parent, child = mp.Pipe()
            process = mp.Process(target=worker, args=(child, folder, bind_port))
            process.start()
            child.close()
            processes.append(process)
            connections.append(parent)
        try:
            for connection in connections:
                assert connection.poll(15), "startup timed out"
                ready = connection.recv()
                assert ready["ok"], ready
            sender, receiver = connections
            files = []
            for name, data in (("hello.txt", b"Hello from GhostFile!\n"), ("binary.dat", os.urandom(2_000_000)), ("empty.txt", b"")):
                path = directory / name
                path.write_bytes(data)
                files.append(str(path))
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=files)
            incoming = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            assert not list(destination.iterdir()), "files created without approval"
            outgoing = wait(sender, lambda t: t.get("meta", {}).get("pin_code") is not None)
            assert incoming["meta"]["pin_code"] == outgoing["meta"]["pin_code"], "PIN mismatch"
            request(receiver, "decide", id=incoming["id"], accept=True)
            wait(receiver, lambda t: t["id"] == incoming["id"] and t["state"] == "Finished")
            wait(sender, lambda t: t["id"] == outgoing["id"] and t["state"] == "Finished")
            for path in map(Path, files):
                assert (destination / path.name).read_bytes() == path.read_bytes()
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=[files[0]])
            incoming2 = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            request(receiver, "decide", id=incoming2["id"], accept=False)
            wait(receiver, lambda t: t["id"] == incoming2["id"] and t["state"] == "Rejected")
            assert sorted(p.name for p in destination.iterdir()) == ["binary.dat", "empty.txt", "hello.txt"]
            assert request(receiver, "visibility", visible=False) is True
            assert request(receiver, "snapshot")["visible"] is False
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=[files[0]])
            incoming3 = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            request(receiver, "decide", id=incoming3["id"], accept=True)
            wait(receiver, lambda t: t["id"] == incoming3["id"] and t["state"] == "Finished")
            assert (destination / "1_hello.txt").read_bytes() == Path(files[0]).read_bytes()
            # A per-transfer folder must not change the default for later transfers.
            chosen = directory / "chosen folder"
            chosen.mkdir()
            (chosen / "hello.txt").write_bytes(b"keep existing")
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=[files[0]])
            incoming_chosen = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            request(receiver, "decide", id=incoming_chosen["id"], accept=True, directory=str(chosen))
            completed = wait(receiver, lambda t: t["id"] == incoming_chosen["id"] and t["state"] == "Finished")
            assert completed["meta"]["saved_files"] == [str(chosen / "1_hello.txt")]
            assert (chosen / "hello.txt").read_bytes() == b"keep existing"
            assert request(receiver, "resolve_path", id=incoming_chosen["id"], index=0, folder=False) == str(chosen / "1_hello.txt")
            assert request(receiver, "resolve_path", id=incoming_chosen["id"], index=0, folder=True) == str(chosen)
            assert request(receiver, "snapshot")["download_dir"] == str(destination)
            # Cancel before consent; neither endpoint may write another file.
            known_ids = {t["id"] for t in request(sender, "snapshot")["transfers"]}
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=[files[0]])
            incoming4 = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            outbound4 = wait(sender, lambda t: t["id"] not in known_ids and t.get("meta") is not None)
            request(sender, "cancel", id=outbound4["id"])
            wait(sender, lambda t: t["id"] == outbound4["id"] and t["state"] == "Cancelled")
            wait(receiver, lambda t: t["id"] == incoming4["id"] and t["state"] == "Disconnected")
            assert not (destination / "2_hello.txt").exists()
            # Connection failures must be visible under the correct outgoing ID.
            known_ids = {t["id"] for t in request(sender, "snapshot")["transfers"]}
            request(sender, "send", address=f"127.0.0.1:{port()}", name="Offline", paths=[files[0]])
            wait(sender, lambda t: t["id"] not in known_ids and t["state"] == "Disconnected" and t["rtype"] == "Outbound")
            print("PASS: encrypted batches, empty files, matching PINs, consent, decline, cancellation, visibility, duplicate preservation, connection failures")
        finally:
            for connection in connections:
                connection.send(None)
            for process in processes:
                process.join(8)
                if process.is_alive():
                    process.terminate()
                    process.join()
                    raise AssertionError("engine failed to stop")
                assert process.exitcode == 0, process.exitcode

if __name__ == "__main__":
    main()
