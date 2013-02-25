import os
import threading
import fcntl

import eventlet
from eventlet.hubs import trampoline


class ThreadPool(object):
    def __init__(self):
        self.rqfd, self.wqfd = os.pipe()
        self.queue = []
        self.threads = []
        self.pipe_pool = []
        self.in_use = 0

    def _launch_thread(self):
        t = threading.Thread(target=self._runner)
        t.setDaemon(True)
        t.start()
        self.threads.append(t)

    def execute(self, func, *args, **kwargs):
        execfunc = lambda: func(*args, **kwargs)
        if self.in_use >= len(self.threads):
            self._launch_thread()
        self.in_use += 1
        try:
            rfd, wfd = self.pipe_pool.pop()
        except IndexError:
            rfd, wfd = os.pipe()
        retval = []
        try:
            self.queue.append((execfunc, wfd, retval))
            os.write(self.wqfd, 'X')
            trampoline(rfd, read=True)
            os.read(rfd, 1)
            if isinstance(retval[0], BaseException):
                raise retval[0]
            return retval[0]
        finally:
            self.in_use -= 1
            self.pipe_pool.append((rfd, wfd))

    def _runner(self):
        while True:
            os.read(self.rqfd, 1)
            execfunc, wfd, retval = self.queue.pop()
            try:
                retval.append(execfunc())
            except BaseException, e:
                retval.append(e)
            finally:
                os.write(wfd, 'X')

default_threadpool = ThreadPool()
execute = default_threadpool.execute
