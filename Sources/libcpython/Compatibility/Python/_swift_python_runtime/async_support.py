"""Drive the session event loop and dispatch asynchronous calls between Python and Swift."""

import atexit
from _swift_python import drive_event_loop, owns_context
from contextlib import contextmanager
from contextvars import ContextVar, copy_context
from inspect import isawaitable

from .streams import capture

_runner = None
_exports = set()

_in_scheduler = ContextVar("swift-python.in-scheduler", default=False)


def run(coroutine, control):
    """Drive one host operation on this interpreter's loop, using its current Python context."""
    loop = _runner.get_loop()
    operation = _Operation(loop, control)
    previous = loop._swift_operation
    loop._swift_operation = operation

    try:
        # The driver runs in scheduler context. The root task runs as user code.
        context = copy_context()
        with _in_scheduler.set(True):
            return drive_event_loop(operation.interrupt, operation.run, coroutine, context)
    finally:
        loop._swift_operation = previous


class _Operation:
    def __init__(self, loop, control):
        self.loop = loop
        self.control = control
        self.descriptor = control("descriptor")

        self.cancelled = set()
        self.stopping = False
        self.joiner = None

    def run(self, coroutine, context):
        with _reader(self.loop, self.descriptor, self.stop):
            root = self.loop.create_task(coroutine, context=context)
            try:
                return self.loop.run_until_complete(root)
            finally:
                self.join(root)

    def join(self, root):
        # An export may still be pending from a task started by an earlier operation.
        pending = {task for task in _exports if task.get_loop() is self.loop}
        if not root.done() or root.cancelled() or self.control("interrupted"):
            pending.update(self.owned_tasks())
            pending.add(root)

        if pending:
            self.joiner = self.loop.create_task(_cancel_and_wait(pending, self))
            self.loop.run_until_complete(self.joiner)

    def owned_tasks(self):
        import asyncio

        return {
            task
            for task in asyncio.all_tasks(self.loop)
            if task is not self.joiner and owns_context(task.get_context())
        }

    def cancel(self, tasks):
        for task in tasks:
            if task not in self.cancelled and not task.cancelling():
                self.cancelled.add(task)
                task.cancel()

    def stop(self):
        if self.stopping:
            return

        self.stopping = True
        self.loop.remove_reader(self.descriptor)
        self.cancel(_cancellation_roots(self.owned_tasks()))

    def interrupt(self):
        import asyncio

        if self.stopping:
            return None
        if _in_scheduler.get():
            # The interruption pipe wakes the selector without unwinding the scheduler.
            return False

        task = asyncio.current_task(self.loop)
        # A busy task cannot reach the reader. Deliver once, including if its finally awaits.
        if task is not None:
            if task in self.cancelled:
                return False
            self.cancelled.add(task)
        return True


@contextmanager
def _reader(loop, descriptor, callback):
    loop.add_reader(descriptor, callback)
    try:
        yield
    finally:
        loop.remove_reader(descriptor)


async def _wait_for_pipe(descriptor: int) -> None:
    import asyncio

    loop = asyncio.get_running_loop()
    ready = loop.create_future()

    def readable() -> None:
        if not ready.done():
            ready.set_result(None)

    with _reader(loop, descriptor, readable):
        await ready


def _cancellation_roots(tasks):
    # TaskGroup, gather and directly awaited tasks receive cancellation from their parent.
    return {task for task in tasks if tasks.isdisjoint(task._asyncio_awaited_by or ())} or tasks


async def _cancel_and_wait(tasks, operation):
    import asyncio

    tasks = set(tasks)
    while tasks:
        roots = _cancellation_roots(tasks)
        if operation is None:
            for task in roots:
                task.cancel()
        else:
            operation.cancel(roots)

        await asyncio.gather(*roots, return_exceptions=True)
        tasks.difference_update(roots)


def run_imported(request, control, await_result):
    with capture(control, {}, collect=False):
        run(_call_imported(request, await_result), control)


async def _call_imported(request, await_result=True):
    import asyncio

    try:
        result = request("call")
        if await_result and isawaitable(result):
            result = await result
        request("return", result)
    except asyncio.CancelledError:
        request("cancel")
        raise
    except BaseException as error:
        request("raise", error)


@contextmanager
def _pending_export():
    import asyncio

    task = asyncio.current_task()
    operation = getattr(asyncio.get_running_loop(), "_swift_operation", None)
    _exports.add(task)
    try:
        yield operation
    finally:
        _exports.discard(task)


async def call_export(invoke, index: int, arguments: tuple):
    tasks = {}
    with _pending_export() as operation, _in_scheduler.set(True):
        descriptor, ticket = invoke("start", index, arguments)
        try:
            while True:
                await _wait_for_pipe(descriptor)
                requests = invoke("poll", ticket)
                if requests is not None:
                    _dispatch_imports(requests, tasks)
                    continue

                if operation is not None and operation.control("interrupted"):
                    # Both pipes can become readable together. Let the awaiting task deliver
                    # cancellation before taking the reply.
                    operation.stop()
                    await operation.loop.create_future()

                return invoke("take", ticket)
        finally:
            invoke("cancel", ticket)
            if tasks:
                await _cancel_and_wait(tasks.values(), operation)


def _dispatch_imports(requests, tasks):
    import asyncio

    for request, task in tuple(tasks.items()):
        if not request("pending"):
            task.cancel()

    for request in requests:
        if request("pending"):
            with _in_scheduler.set(False):
                task = asyncio.create_task(_call_imported(request))
            tasks[request] = task
            task.add_done_callback(lambda _, request=request: tasks.pop(request, None))


def resolve_address(arguments):
    import socket

    return _socket_result(socket.getaddrinfo, arguments)


def resolve_name(arguments):
    import socket

    return _socket_result(socket.getnameinfo, arguments)


def _socket_result(lookup, arguments):
    try:
        return lookup(*arguments)
    except OSError as error:
        # Pass the exception through Swift so the event loop can raise its original socket subtype.
        return error


def configure_restricted_loop(dns) -> None:
    import asyncio
    from selectors import DefaultSelector

    async def resolve(reverse, arguments):
        result = await call_export(dns, 0, (reverse, arguments))
        if isinstance(result, OSError):
            raise result
        return result

    class Loop(asyncio.SelectorEventLoop):
        _swift_operation = None

        def __init__(self):
            super().__init__(selector=DefaultSelector())

        async def getaddrinfo(self, host, port, *, family=0, type=0, proto=0, flags=0):
            return await resolve(False, (host, port, family, type, proto, flags))

        async def getnameinfo(self, sockaddr, flags=0):
            return await resolve(True, (sockaddr, flags))

        # Swift callbacks and interruption wake the interpreter thread through their own pipes.
        def _make_self_pipe(self):
            pass

        def _close_self_pipe(self):
            pass

        def _write_to_self(self):
            pass

    asyncio.events.new_event_loop = asyncio.new_event_loop = Loop
    global _runner
    _runner = asyncio.Runner(loop_factory=Loop)
    atexit.register(_runner.close)
