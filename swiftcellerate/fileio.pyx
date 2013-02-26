import os
import struct
import eventlet.hubs
from eventlet.support import greenlets as greenlet
import threading

from swiftcellerate cimport bufferedio

from stdlib cimport malloc, free

_threadlocal = threading.local()


cdef extern from 'string.h':
    void *memset(void *s, int c, size_t n)

cdef extern from 'fcntl.h':
    int O_RDONLY, O_WRONLY, O_APPEND, O_CREAT

cdef extern from 'unistd.h' nogil:
    ctypedef int off_t
    int close(int fd)
    int open(char *pathname, int flags)
    int read(int fd, void *buf, size_t count)
    int pread(int fd, void *buf, size_t count, off_t offset)
    int pwrite(int fd, void *buf, size_t count, off_t offset)
    off_t lseek(int fd, off_t offset, int whence)
    int SEEK_CUR

cdef extern from 'sys/eventfd.h':
    int eventfd(unsigned int initval, int flags)
    int EFD_NONBLOCK

cdef extern from 'time.h':
    ctypedef unsigned long time_t
    struct timespec:
        time_t tv_sec
        long tv_nsec

cdef extern from 'libaio.h':
    struct io_context:
        pass
    struct iocb:
        void *data
    struct io_event:
        iocb *obj
        int res
        int res2
    ctypedef io_context *aio_context_t
    int io_setup(unsigned int nr_events, aio_context_t *ctxp)
    int io_destroy(aio_context_t ctx)
    int io_submit(aio_context_t ctx_id, long nr, iocb **iocbpp)
    int io_cancel(aio_context_t ctx_id, iocb *iocb, io_event *result)
    void io_set_eventfd(iocb *iocb, int eventfd)
    void io_prep_pread(iocb *iocb, int fd, void *buf, size_t count, long long offset)
    void io_prep_pwrite(iocb *iocb, int fd, void *buf, size_t count, long long offset)
    void io_prep_fsync(iocb *iocb, int fd)
    int io_getevents(aio_context_t ctx_id, long min_nr, long nr,
               io_event *events, timespec *timeout)

cdef class IOCB:
    cdef iocb cb, *cbp

    def __init__(self):
        self.cbp = &self.cb


class IOSubmitError(Exception):
    pass


cdef class FileHub:
    cdef io_context *ctx
    cdef int evfd
    cdef object hub, hub_listener

    def __init__(self):
        self.ctx = NULL
        io_setup(1024, &self.ctx)
        self.evfd = eventfd(0, EFD_NONBLOCK)
        self.hub = eventlet.hubs.get_hub()
        self.hub_listener = self.hub.add(self.hub.READ, self.evfd, self._eventfire)

    def __dealloc__(self):
        io_destroy(self.ctx)

    def _eventfire(self, *args):
        cdef char retval[8]
        self.hub.remove(self.hub_listener)
        read(self.evfd, retval, sizeof(retval))
        cdef io_event events[256]
        cdef int count = io_getevents(self.ctx, 1, 256, events, NULL)
        cdef object cbdata
        for x in xrange(count):
            cbdata = <object>(events[x].obj.data)
            switcher = cbdata[0]
            cbdata[:] = [events[x].res, events[x].res2]
            switcher()
        self.hub_listener = self.hub.add(self.hub.READ, self.evfd, self._eventfire)

    cdef _execute(self, IOCB cb):
        io_set_eventfd(cb.cbp, self.evfd)
        cbdata = [greenlet.getcurrent().switch]
        cb.cb.data = <void *>cbdata
        cdef int retval = io_submit(self.ctx, 1, &cb.cbp)
        if retval <= 0:
            raise IOSubmitError()
        self.hub.switch()
        if cbdata[0] < 0:
            raise IOError()
        return cbdata[0]

    cdef int pread(self, int fd, char *buf, long long offset, size_t count):
        cdef IOCB cb = IOCB()
        io_prep_pread(cb.cbp, fd, buf, count, offset)
        try:
            return self._execute(cb)
        except IOSubmitError:
            with nogil:
                return pread(fd, buf, count, offset)

    cdef int pwrite(self, int fd, unsigned long offset, object txt):
        cdef int length = len(txt)
        cdef IOCB cb = IOCB()
        io_prep_pwrite(cb.cbp, fd, <char *>txt, length, offset)
        try:
            return self._execute(cb)
        except IOSubmitError:
            with nogil:
                return pwrite(fd, <char *>txt, length, offset)

    cdef fsync(self, int fd):
        cdef IOCB cb = IOCB()
        io_prep_fsync(cb.cbp, fd)
        return self._execute(cb)


cdef FileHub get_hub():
    try:
        return _threadlocal.hub
    except AttributeError:
        _threadlocal.hub = FileHub()
        return _threadlocal.hub


cdef class File(bufferedio.BufferedIO):
    cdef int pos

    def __init__(self, filename, mode='r'):
        if mode.startswith('r'):
            self.bufferedio_init(open(filename, O_RDONLY))
        elif mode.startswith('w'):
            self.bufferedio_init(open(filename, O_WRONLY | O_CREAT))
        elif mode.startswith('a'):
            self.bufferedio_init(open(filename, O_APPEND))
        if self.fd < 0:
            raise IOError()
        self.pos = lseek(self.fd, 0, SEEK_CUR)

    cdef _fdread(self, char *buf, int length):
        cdef int retval = get_hub().pread(self.fd, buf, self.pos, length)
        self.pos += retval
        return retval

    def readlines(self):
        lines = []
        line = self.readline()
        while line:
            lines.append(line)
            line = self.readline()
        return lines

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()

    def write(self, txt):
        cdef int retval, writelen
        writelen = 0
        while txt:
            retval = get_hub().pwrite(self.fd, self.pos, txt)
            self.pos += retval
            txt = txt[retval:]
        return retval

    def tell(self):
        return self.pos

    def seek(self, loc, whence=0):
        if whence == 0:
            self.pos = loc
        elif whence == 1:
            self.pos += loc
        elif whence == 2:
            statinfo = os.fstat(self.fd)
            self.pos = statinfo.st_size - loc

    def close(self):
        close(self.fd)


def os_read(int fd, unsigned long length):
    cdef char *buf = <char *>malloc(length)
    cdef int rval
    try:
        rval = get_hub().pread(fd, buf, lseek(fd, 0, SEEK_CUR), length)
        if rval < 0:
            return ''
        lseek(fd, rval, SEEK_CUR)
        return buf[0:rval]
    finally:
        free(buf)

def os_write(int fd, object txt):
    cdef int wval = get_hub().pwrite(fd, lseek(fd, 0, SEEK_CUR), txt)
    if wval > 0:
        lseek(fd, wval, SEEK_CUR)
    return wval
