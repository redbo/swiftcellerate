import swift
import swift.common.wsgi
import swift.common.utils
import swift.obj.server
from swiftcellerate import libeventhub, wsgi, tpool

def get_hub():
    return libeventhub.Hub

def filter_factory(global_conf, **local_conf):
    swift.common.wsgi.wsgi = wsgi
    swift.common.utils.get_hub = get_hub
    swift.obj.server.tpool = tpool

    def app_returner(app):
        return app
    return app_returner

