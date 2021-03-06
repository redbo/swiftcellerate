import swift
import swift.common.wsgi
import swift.common.utils
import swift.obj.server
import os
from swiftcellerate import libeventhub, wsgi, tpool, fileio

def get_hub():
    return libeventhub.Hub

class OS(object):
    path = os.path
    listdir = os.listdir
    close = os.close
    unlink = os.unlink
    write = fileio.os_write
    read = fileio.os_read

def filter_factory(global_conf, **local_conf):
    def app_returner(app):
        swift.common.wsgi.wsgi = wsgi
        swift.common.utils.get_hub = get_hub
        swift.obj.server.tpool = tpool
#        swift.obj.server.os = OS

# not there yet...
#        __builtins__['file'] = fileio.File
#        __builtins__['open'] = fileio.File
#        os.read = fileio.os_read
#        os.write = fileio.os_write
#        os.fsync = fileio.os_fsync
#        os.fdatasync = fileio.os_fdatasync
        return app
    return app_returner

