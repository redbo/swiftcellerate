import os
import sys
import urllib2
from itertools import chain
import uuid
import socket

from eventlet.hubs import trampoline
from eventlet import greenpool

from swiftcellerate import tpool


MAX_TOKEN_SIZE = 64
MAX_URL_SIZE = 1024 * 8
MAX_HEADER_SIZE = 1024 * 8


cdef extern from *:
    int errno
    int EWOULDBLOCK
    ctypedef unsigned long off_t
    ctypedef unsigned long size_t
    ctypedef long ssize_t
    ctypedef char* const_char_ptr "const char*"


cdef extern from 'string.h' nogil:
    void *memchr(void *s, int c, size_t n)


cdef extern from 'sys/sendfile.h' nogil:
    ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count)


cdef extern from 'sys/socket.h':
     ssize_t recv(int sockfd, void *buf, size_t len, int flags)
     int MSG_DONTWAIT


class HTTPError(Exception):
    def __init__(self, code, msg):
        self.code = code
        self.msg = msg


class ClientDisconnectError(IOError):
    pass


class DropConnection(BaseException):
    pass


class FileWrapper:
    def __init__(self, fp, block_size):
        self.fp = fp
        self.block_size = block_size
        if hasattr(self.fp, 'close'):
            self.close = fp.close
        if hasattr(self.fp, 'fileno'):
            self.fileno = fp.fileno

    def __iter__(self):
        return self

    def next(self):
        return self.fp.read(self.block_size)


class Input:
    def __init__(self, read):
        self.read = read


_environ_template = {
    'wsgi.errors': sys.stderr,
    'wsgi.version': (1, 0),
    'wsgi.multithread': True,
    'wsgi.multiprocess': False,
    'wsgi.run_once': False,
    'wsgi.url_scheme': 'http',
    'wsgi.file_wrapper': FileWrapper,
    'swiftcellerate.client_disconnect': ClientDisconnectError,
    'swiftcellerate.drop_connection': DropConnection,
    'SCRIPT_NAME': '',
}


def parse_ranges(range_header, file_size):
    ranges = []
    if not range_header or '=' not in range_header:
        return ranges
    units, range_str = range_header.split('=')
    if units.strip().lower() != 'bytes':
        return ranges
    for range in range_str.split(','):
        if '-' not in range:
            continue
        start, end = range.split('-', 1)
        start = start.strip()
        end = end.strip()
        if (not (end or start)) or (start and not start.isdigit()) or (end and not end.isdigit()):
            continue
        elif not start:
            start = file_size - int(end)
            end = file_size
        elif not end:
            start = int(start)
            end = file_size
        else:
            start = int(start)
            end = int(end) + 1
        if start >= end:
            continue
        ranges.append((max(0, start), min(end, file_size)))
    return ranges


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


cdef class ConnectionHandler:
    cdef object status, headers, sock
    cdef char buf[128 * 1024]
    cdef long request_length
    cdef long buf_length, buf_start
    cdef long chunk_len, chunk_pos, chunk_final
    cdef int fileno
    cdef char headers_sent
    cdef char disconnected
    cdef char expect

    def start_response(self, status, headers, exc_info=None):
        if exc_info:
            raise exc_info[0], exc_info[1], exc_info[2]
        self.status = status
        self.headers = dict([(header.title(), value)
                             for header, value in headers])

    def send_headers(self):
        self.cork()
        self.send('HTTP/1.1 %s\r\n' % self.status)
        for header in self.headers.iteritems():
            self.send('%s: %s\r\n' % header)
        self.send('\r\n')
        self.headers_sent = 1

    def sendfile(self, fp, range_header):
        cdef ssize_t result = 0
        cdef off_t offset = 0
        cdef int in_fd = fp.fileno()
        cdef unsigned long file_size = os.fstat(fp.fileno()).st_size
        cdef unsigned long endoffset = file_size

        ranges = parse_ranges(range_header, file_size)

        if len(ranges) < 2:
            if len(ranges) == 1:
                offset, endoffset = ranges[0]
                self.headers['Content-Range'] = '%d-%d/%d' % (offset, endoffset - 1, file_size)
            self.headers['Content-Length'] = str(endoffset - offset)
            self.send_headers()
            with nogil:
                while offset < endoffset and result >= 0:
                    result = sendfile(self.fileno, in_fd, &offset, endoffset - offset)
            return result != 0
        else:
            boundary = str(uuid.uuid4()).replace('-', '')
            content_type = self.headers['Content-Type']
            self.headers['Content-Type'] = 'multipart/byteranges; boundary=%s' % boundary
            common_length = 49 + len(boundary) + len(content_type) + len(str(endoffset))
            self.headers['Content-Length'] = str(sum(
                [(end - start) + len(str(start)) + len(str(end - 1)) + common_length for start, end in ranges]
                ) + 8 + len(boundary))
            self.send_headers()
            for offset, endoffset in ranges:
                self.send('--%s\r\nContent-Type: %s\r\nContent-Range: bytes %s-%s/%s\r\n\r\n' %
                          (boundary, content_type, offset, endoffset - 1, file_size))
                with nogil:
                    while offset < endoffset and result >= 0:
                        result = sendfile(self.fileno, in_fd, &offset, endoffset - offset)
                if result < 0:
                    raise ClientDisconnectError()
                self.send('\r\n')
            self.send('\r\n--%s--\r\n' % boundary)

    def input_read(self, length=None):
        if self.expect != 0:
            self.nodelay()
            self.send('HTTP/1.1 100 Continue\r\n\r\n')
            self.expect = 0
        cdef char size_line[256]
        cdef int size_line_len
        if length is None:
            resp = []
            chunk = True
            while chunk:
                chunk = self.input_read(65536)
                resp.append(chunk)
            return ''.join(resp)
        else:
            if self.request_length == 0:
                return ''
            elif self.request_length < 0:
                return self.chunked_read(length)
            elif length > self.request_length:
                length = self.request_length
            retval = self.read(length)
            self.request_length -= len(retval)
            return retval

    cdef chunk_reset(self):
        self.chunk_len = self.chunk_pos = self.chunk_final = 0

    cdef chunked_read(self, int length):
        cdef int txtlen = 0
        cdef object txt = []
        if self.chunk_final != 0:
            return ''
        while txtlen < length and self.chunk_final == 0:
            if self.chunk_pos == self.chunk_len:
                self.chunk_len = int(self.readline(MAX_TOKEN_SIZE), 16)
                self.chunk_pos = 0
                if self.chunk_len == 0:
                    self.chunk_final = 1
            if (self.chunk_len - self.chunk_pos) > (length - txtlen):
                chunk = self.read(length - txtlen)
            else:
                chunk = self.read(self.chunk_len - self.chunk_pos)
            self.chunk_pos += len(chunk)
            if self.chunk_len == self.chunk_pos:
                self.readline(MAX_TOKEN_SIZE)
            txtlen += len(chunk)
            txt.append(chunk)
        return ''.join(txt)

    cdef read(self, int bytes):
        cdef int orig_bytes = bytes
        if self.buf_length < bytes:
            self.fill_buffer(0)
        if self.buf_length == 0 and self.disconnected != 0:
            raise ClientDisconnectError()
        if self.buf_length < bytes:
            bytes = self.buf_length
        if self.buf_start + bytes > sizeof(self.buf):
            retval = self.buf[self.buf_start:sizeof(self.buf)] + \
                     self.buf[0:bytes - (sizeof(self.buf) - self.buf_start)]
        else:
            retval = self.buf[self.buf_start:self.buf_start + bytes]
        self.consume(len(retval))
        return retval

    cdef read_to_char(self, char search, int limit):
        cdef int pos = circ_memchr(self.buf, search, sizeof(self.buf),
                                   self.buf_start, self.buf_length)
        while pos < 0 and self.buf_length < limit:
            self.fill_buffer(1)
            pos = circ_memchr(self.buf, search, sizeof(self.buf),
                              self.buf_start, self.buf_length)
        if pos > limit or pos < 0:
            raise HTTPError(400, 'Invalid Request')
        retval = self.read(pos)
        self.consume(1)
        return retval

    cdef readline(self, int limit):
        cdef int pos = circ_memchr(self.buf, '\r', sizeof(self.buf),
                                   self.buf_start, self.buf_length)
        while pos < 0 and self.buf_length < limit:
            self.fill_buffer(1)
            pos = circ_memchr(self.buf, '\r', sizeof(self.buf),
                              self.buf_start, self.buf_length)
        while pos == self.buf_length:
            self.fill_buffer(1)
        if pos > limit or pos < 0:
            raise HTTPError(400, 'Invalid Request')
        retval = self.read(pos)
        if chr(self.buf[(self.buf_start + 1) % sizeof(self.buf)]) == '\n':
            self.consume(2)
        else:
            self.consume(1)
        return retval

    cdef fill_buffer(self, int disconnect_on_error):
        cdef int readlen = -1
        if self.disconnected != 0 and disconnect_on_error != 0:
            raise ClientDisconnectError()
        if self.disconnected != 0 or self.buf_length == sizeof(self.buf):
            return
        cdef int tofill
        if (self.buf_start + self.buf_length) >= sizeof(self.buf):
            tofill = sizeof(self.buf) - self.buf_length
        else:
            tofill = sizeof(self.buf) - (self.buf_start + self.buf_length)
        while readlen <= 0:
            trampoline(self.fileno, read=True)
            readlen = recv(self.fileno, &self.buf[(self.buf_start +
                self.buf_length) % sizeof(self.buf)], tofill, MSG_DONTWAIT)
            if readlen <= 0:
                if errno != EWOULDBLOCK:
                    self.disconnected = 1
                    if disconnect_on_error != 0:
                        raise ClientDisconnectError()
                    return
        self.buf_length += readlen

    cdef consume(self, int bytes):
        self.buf_start = (self.buf_start + bytes) % sizeof(self.buf)
        self.buf_length -= bytes

    cdef send(self, txt):
        self.sock.sendall(txt)

    cdef nodelay(self):
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    cdef cork(self):
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_CORK, 1)

    cdef uncork(self):
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_CORK, 0)

    def handle(self, app, sock):
        cdef long response_length
        cdef char chunked
        cdef char keepalive
        cdef object environ
        cdef object header, header_name, header_value
        cdef object result, resultiter, chunk
        self.sock = sock
        self.fileno = sock.fileno()
        self.disconnected = 0
        self.buf_start = 0
        self.buf_length = 0
        self.disconnected = 0
        try:
            while self.disconnected == 0:
                self.chunk_reset()
                self.headers_sent = 0
                self.request_length = 0
                response_length = 0
                self.status = None
                environ = _environ_template.copy()
                environ['REQUEST_METHOD'] = self.read_to_char(' ', MAX_TOKEN_SIZE)
                environ['RAW_PATH_INFO'] = self.read_to_char(' ', MAX_URL_SIZE)
                environ['SERVER_PROTOCOL'] = self.readline(MAX_TOKEN_SIZE)
                try:
                    path_info, environ['QUERY_STRING'] = environ['RAW_PATH_INFO'].split('?', 1)
                    environ['PATH_INFO'] = urllib2.unquote(path_info)
                except ValueError:
                    environ['PATH_INFO'] = urllib2.unquote(environ['RAW_PATH_INFO'])
                    environ['QUERY_STRING'] = ''
                header = self.readline(MAX_HEADER_SIZE)
                while header:
                    try:
                        header_name, header_value = header.split(': ', 1)
                    except ValueError:
                        raise HTTPError(400, 'Invalid Request')
                    environ['HTTP_' + header_name.upper().replace('-', '_')] = header_value
                    header = self.readline(MAX_HEADER_SIZE)
                self.expect = (environ.get('HTTP_EXPECT') == '100-continue')
                http_connection = environ.get('HTTP_CONNECTION', 'close').lower()
                keepalive = (http_connection == 'keep-alive' or
                             (environ['SERVER_PROTOCOL'] == 'HTTP/1.1' and http_connection != 'close'))
                if 'HTTP_CONTENT_LENGTH' in environ:
                    if not environ['HTTP_CONTENT_LENGTH'].isdigit():
                        raise HTTPError(400, 'Bad Request')
                    environ['CONTENT_LENGTH'] = environ.pop('HTTP_CONTENT_LENGTH')
                    self.request_length = int(environ['CONTENT_LENGTH'])
                if 'HTTP_CONTENT_TYPE' in environ:
                    environ['CONTENT_TYPE'] = environ.pop('HTTP_CONTENT_TYPE')
                if environ.get('HTTP_TRANSFER_ENCODING') == 'chunked':
                    self.request_length = -1
                environ['wsgi.input'] = Input(self.input_read)
                result = app(environ, self.start_response)

                if environ['REQUEST_METHOD'] != 'HEAD' and isinstance(result, (list, tuple)):
                    self.headers['Content-Length'] = str(sum(map(len, result)))
                try:
                    if self.status is None:
                        resultiter = iter(result)
                        result = chain(next(resultiter), resultiter)
                except StopIteration:
                    result = []

                if keepalive == 0:
                    self.headers['Connection'] = 'close'
                else:
                    self.headers['Connection'] = 'keep-alive'

                if hasattr(result, 'fileno'):
                    tpool.execute(self.sendfile, result,
                                  environ.get('HTTP_RANGE'))
                else:
                    if 'Content-Length' in self.headers:
                        response_length = int(self.headers['Content-Length'])
                        chunked = 0
                    else:
                        self.headers['Transfer-Encoding'] = 'chunked'
                        chunked = 1
                    self.send_headers()
                    if chunked != 0:
                        for chunk in result:
                            self.send('%x\r\n' % len(chunk))
                            self.send(chunk)
                            self.send('\r\n')
                        self.send('0\r\n\r\n')
                    else:
                        for chunk in result:
                            self.send(chunk)
                            response_length -= len(chunk)
                        if response_length != 0:
                            return
                self.uncork()
                self.expect = 0
                while self.input_read(1024 * 32):
                    pass
                if hasattr(result, 'close'):
                    result.close()
                if keepalive == 0:
                    return
        except ClientDisconnectError:
            pass
        except HTTPError, e:
            if self.headers_sent == 0:
                self.send(
                    'HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\n\r\n%s'
                    % (e.code, e.msg, e.msg))
        except (Exception, DropConnection), e:
            if self.headers_sent == 0:
                self.send(
                    'HTTP/1.1 500 Internal Server Error\r\n'
                    'Content-Type: text/plain\r\n\r\nInternal Server Error')
            import traceback
            traceback.print_exc()
        finally:
            self.sock.close()


handler_pool = []
def handle_connection(app, sock):
    try:
        handler = handler_pool.pop()
    except:
        handler = ConnectionHandler()
    try:
        handler.handle(app, sock)
    finally:
        handler_pool.append(handler)


def server(server_sock, app, log=None, custom_pool=None):
    if custom_pool is not None:
        pool = custom_pool
    else:
        pool = greenpool.GreenPool(1024)
    while True:
        sock, addr = server_sock.accept()
        pool.spawn_n(handle_connection, app, sock)
