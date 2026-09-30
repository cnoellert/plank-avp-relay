# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded root-only IPC with cached reads and one owner of slow backend work."""
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError
import copy
import json
import os
from pathlib import Path
import queue
import signal
import socket
import struct
import threading
import time


class ControllerWorker:
    """Only this worker calls the backend; socket handlers read public copies.

    A mutation is durable before its receipt is published. The worker waits for
    the socket handler to send (or abandon) that receipt before applying it.
    A lost response never cancels an accepted operation.
    """
    def __init__(self, controller):
        self.controller = controller
        self.jobs = queue.Queue(maxsize=4)
        self.stopping = threading.Event()
        self.failed = False
        self.lock = threading.Lock()
        self.cache = controller.public_state()
        self.thread = threading.Thread(target=self.run, name='network-controller')

    def publish(self):
        public = self.controller.public_state()
        with self.lock: self.cache = public

    def start(self): self.thread.start()

    def run(self):
        try:
            self.controller.start()
            self.publish()
            next_tick = time.monotonic()
            while not self.stopping.is_set():
                try: job = self.jobs.get(timeout=max(0, next_tick - time.monotonic()))
                except queue.Empty: job = None
                if job:
                    command, result, sent = job
                    try:
                        reply = self.controller.request(command)
                        self.publish()
                        result.set_result(reply)
                        # The handler has its own bounded I/O timeout. Do not
                        # delay accepted work indefinitely for a dead client.
                        sent.wait(0.6)
                        next_tick = time.monotonic()
                    except ValueError as error:
                        result.set_result({'error': str(error)[:512]})
                    except (KeyError, TypeError, OSError, RuntimeError):
                        result.set_result({'error': 'The network request could not be accepted. Refresh its status.'})
                if time.monotonic() >= next_tick:
                    self.controller.tick()
                    self.publish()
                    next_tick = time.monotonic() + self.controller.poll_interval
        except Exception:
            # A failed worker must restart the service, without logging backend
            # exception text that could include submitted credentials.
            self.failed = True
        finally:
            self.stopping.set()
            try: self.controller.stop()
            except Exception: self.failed = True
            while True:
                try: _, result, _ = self.jobs.get_nowait()
                except queue.Empty: break
                result.set_result({'error': 'The network service is stopping. Refresh its status.'})

    def request(self, command, sent=None):
        with self.lock: cache = copy.deepcopy(self.cache)
        reply = self.controller.read_cached(command, cache)
        if reply is not None: return reply
        if self.stopping.is_set(): raise RuntimeError('Network service stopped.')
        result, event = Future(), sent or threading.Event()
        if sent is None: event.set()
        try: self.jobs.put_nowait((copy.deepcopy(command), result, event))
        except queue.Full:
            return {'error': 'The network service is busy. Refresh its status.'}
        try: return result.result(timeout=0.5)
        except TimeoutError:
            # Do not cancel/replay the queued mutation: its request ID is the
            # receipt to consult even if the original reply cannot be delivered.
            return {'error': 'The network request is pending. Refresh its status.', 'code': 'busy'}

    def close(self):
        self.stopping.set()
        self.thread.join()


def serve(path, controller):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.unlink(missing_ok=True)
    running = True
    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    worker = ControllerWorker(controller)
    slots = threading.BoundedSemaphore(4)
    def respond(connection):
        try:
            with connection:
                try: handle(connection, worker)
                except (OSError, ValueError): pass
        finally: slots.release()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(path))
        os.chmod(path, 0o600)
        listener.listen(4)
        listener.settimeout(0.2)
        worker.start()
        try:
            with ThreadPoolExecutor(max_workers=4, thread_name_prefix='network-ipc') as handlers:
                while running and not worker.stopping.is_set():
                    try: connection, _ = listener.accept()
                    except socket.timeout: continue
                    if slots.acquire(blocking=False): handlers.submit(respond, connection)
                    else: connection.close()
        finally:
            worker.close()
            path.unlink(missing_ok=True)
    return 1 if worker.failed else 0


def handle(connection, controller):
    _, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i')))
    if uid != 0: return
    connection.settimeout(0.5)
    data = bytearray()
    sent = threading.Event()
    try:
        try:
            while not data.endswith(b'\n'):
                part = connection.recv(1025 - len(data))
                if not part or len(data) + len(part) > 1024: raise ValueError('Invalid management request length.')
                data.extend(part)
            command = json.loads(data)
            if not isinstance(command, dict): raise ValueError('Expected a management request.')
            reply = controller.request(command, sent) if isinstance(controller, ControllerWorker) else controller.request(command)
        except ValueError as error:
            reply = {'error': str(error)[:512]}
        except (KeyError, TypeError, RuntimeError):
            reply = {'error': 'The network request could not be completed. Refresh its status.'}
        encoded = json.dumps(reply, separators=(',', ':'), ensure_ascii=False).encode() + b'\n'
        if len(encoded) > 4000: encoded = b'{"error":"The management response exceeded its limit."}\n'
        connection.sendall(encoded)
    finally: sent.set()
