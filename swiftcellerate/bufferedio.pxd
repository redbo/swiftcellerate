cdef class BufferedIO:
    cdef char buf[128 * 1024]
    cdef long buf_length, buf_start
    cdef int fd
    cdef char disconnected
    cdef object invalid_length_error
    cdef object disconnect_error

    cdef bufferedio_init(self, int fd)
    cpdef int fileno(self)
    cpdef read(self, int length=?)
    cpdef read_to_char(self, char search, int limit=?)
    cpdef readline(self, int limit=?)
    cdef _fill_buffer(self)
    cdef _consume(self, int bytes)
    cdef _fdread(self, char *buf, int length)
