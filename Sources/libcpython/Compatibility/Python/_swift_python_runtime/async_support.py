"""Wait for host completion and interruption signals on the Python event loop."""


async def wait_for_pipe(descriptor: int) -> None:
    import asyncio

    loop = asyncio.get_running_loop()
    ready = loop.create_future()

    def readable() -> None:
        if not ready.done():
            ready.set_result(None)

    loop.add_reader(descriptor, readable)

    try:
        await ready
    finally:
        loop.remove_reader(descriptor)


async def await_block(coroutine, control):
    import asyncio

    task = asyncio.create_task(coroutine)
    stop = asyncio.create_task(wait_for_pipe(control("descriptor")))

    try:
        done, _ = await asyncio.wait((task, stop), return_when=asyncio.FIRST_COMPLETED)
        if stop in done:
            await stop
            raise KeyboardInterrupt

        return await task
    finally:
        # A trace interrupt can finish either task before wait() resumes.
        # Always retrieve both results, including BaseException subclasses.
        task.cancel()
        stop.cancel()
        await asyncio.gather(task, stop, return_exceptions=True)
