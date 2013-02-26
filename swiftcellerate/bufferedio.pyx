cdef extern from *:
    int errno
    ctypedef unsigned long size_t
    int EWOULDBLOCK


cdef extern from 'string.h' nogil:
    void *memchr(void *s, int c, size_t n)


cdef int circ_memchr2(char *haystack, char needle, int hsize, int hstart, int hlen):
    cdef int pos = 0
    for pos in xrange(hlen):
        if haystack[(hstart + pos) % hsize] == needle:
            return pos
    return -1

cdef int circ_memchr(char *haystack, char needle, int hsize, int hstart, int hlen):
    cdef void *loc
    if hstart + hlen <= hsize:
        loc = memchr(&haystack[hstart], needle, hlen)
        if loc != NULL:
            return <char *>loc - &haystack[hstart]
    else:
        loc = memchr(&haystack[hstart], needle, hsize - hstart)
        if loc != NULL:
            return <char *>loc - &haystack[hstart]
        loc = memchr(haystack, needle, hlen - (hsize - hstart))
        if loc != NULL:
            return (<char *>loc - haystack) + (hsize - hstart)
    return -1


cdef class BufferedIO:
    cdef bufferedio_init(self, int fd):
        self.fd = fd
        self.disconnected = 0
        self.buf_start = 0
        self.buf_length = 0

    cpdef int fileno(self):
        return self.fd

    cpdef read(self, int length=-1):
        if length < 0:
            retval = []
            chunk = self.read(8192)
            while chunk:
                retval.append(chunk)
                chunk = self.read(8192)
            return ''.join(retval)
        if self.buf_length < length:
            self._fill_buffer()
        if self.buf_length < length:
            length = self.buf_length
        if self.buf_start + length > sizeof(self.buf):
            retval = self.buf[self.buf_start:sizeof(self.buf)] + \
                     self.buf[0:length - (sizeof(self.buf) - self.buf_start)]
        else:
            retval = self.buf[self.buf_start:self.buf_start + length]
        self._consume(len(retval))
        return retval

    cpdef read_to_char(self, char search, int limit=-1):
        if limit < 0 or limit > (sizeof(self.buf) - 1):
            limit = sizeof(self.buf)
        cdef int pos = circ_memchr(self.buf, search, sizeof(self.buf),
                                   self.buf_start, self.buf_length)
        while pos < 0 and self.buf_length < limit and self.disconnected == 0:
            self._fill_buffer()
            pos = circ_memchr(self.buf, search, sizeof(self.buf),
                              self.buf_start, self.buf_length)
        if pos < 0:
            retval = self.read(limit)
        else:
            retval = self.read(pos)
        self._consume(1)
        return retval

    cpdef readline(self, int limit=-1):
        if limit < 0 or limit > (sizeof(self.buf) - 1):
            limit = sizeof(self.buf)
        cdef int pos = circ_memchr(self.buf, '\n', sizeof(self.buf),
                                   self.buf_start, self.buf_length)
        while pos < 0 and self.buf_length < limit and self.disconnected == 0:
            self._fill_buffer()
            pos = circ_memchr(self.buf, '\n', sizeof(self.buf),
                              self.buf_start, self.buf_length)
        if pos < 0:
            return self.read(limit)
        else:
            return self.read(pos + 1)

    cdef _fill_buffer(self):
        cdef int readlen = -1
        if self.disconnected != 0 or self.buf_length == sizeof(self.buf):
            return
        cdef int tofill
        if (self.buf_start + self.buf_length) >= sizeof(self.buf):
            tofill = sizeof(self.buf) - self.buf_length
        else:
            tofill = sizeof(self.buf) - (self.buf_start + self.buf_length)
        while readlen <= 0:
            readlen = self._fdread(&self.buf[(self.buf_start +
                self.buf_length) % sizeof(self.buf)], tofill)
            if readlen <= 0:
                if errno != EWOULDBLOCK:
                    self.disconnected = 1
                    return
        self.buf_length += readlen

    cdef _consume(self, int bytes):
        self.buf_start = (self.buf_start + bytes) % sizeof(self.buf)
        self.buf_length -= bytes

    cdef _fdread(self, char *buf, int length):
        raise NotImplemented()
