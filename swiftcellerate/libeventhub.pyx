import sys
import traceback
import collections

from eventlet.support import greenlets
from eventlet.hubs.hub import BaseHub, READ, WRITE
import eventlet.hubs


__version__ = '0.1'

cdef extern from *:
    int errno

cdef extern from "Python.h":
    void Py_INCREF(object)
    void Py_DECREF(object)
    int Py_REFCNT(object)

cdef extern from 'sys/time.h':
    struct timeval:
        unsigned long tv_sec
        unsigned long tv_usec

cdef extern from "event.h":
    struct event_base:
        pass
    struct event:
        pass

    void evtimer_set(event *ev, void (*handler)(int fd, short evtype, void *arg), void *arg)
    int event_pending(event *ev, short, timeval *tv)
    int event_add(event *, timeval *)
    int event_del(event *)
    void event_set(event *, int, short, void (*)(int, short, void *), void *)
    int event_base_set(event_base *, event *)
    int event_base_loopbreak(event_base *)
    int event_base_free(event_base *)
    int event_base_loop(event_base *, int) nogil
    event_base *event_base_new()

    int EVLOOP_ONCE, EVLOOP_NONBLOCK
    int EV_TIMEOUT, EV_READ, EV_WRITE, EV_SIGNAL, EV_PERSIST

event_pool = collections.deque(maxlen=1024)

cdef void event_callback(int fd, short evtype, void *arg) with gil:
    cdef object evt = <object>arg
    evt()


cdef class Event:
    cdef event ev
    cdef public object fileno, cb, hub
    cdef object args
    cdef short _evtype
    cdef char cancelled

    cdef add(self, event_base *base, callback, arg=None, short evtype=0,
             fileno=-1, seconds=None, hub=None):
        cdef timeval tv, *tvp
        self.cb = callback
        self.args = arg
        self._evtype = evtype
        self.fileno = fileno
        self.hub = hub
        event_set(&self.ev, fileno, evtype, event_callback, <void *>self)
        Py_INCREF(self)
        self.cancelled = 0
        event_base_set(base, &self.ev)
        if seconds is not None:
            tv.tv_sec = <unsigned long>seconds
            tv.tv_usec = <unsigned long>((<double>seconds -
                <double>tv.tv_sec) * 1000000.0)
            tvp = &tv
        else:
            tvp = NULL
        if event_add(&self.ev, tvp) != 0:
            print "OMGWAT"
        if self._evtype in (EV_READ, EV_WRITE):
            self.hub.listeners[self.evtype][self.fileno] = self

    def __call__(self):
        try:
            self.cb(*self.args)
        except:
            self.hub.async_exception_occurred()
        finally:
            self.cancel(True)

    def pending(self):
        return event_pending(&self.ev, EV_TIMEOUT | EV_SIGNAL | EV_READ | EV_WRITE, NULL)

    def cancel(self, keep=True):
        if self._evtype & EV_PERSIST:
            return
        if self.cancelled == 0:
            event_del(&self.ev)
            if self._evtype & EV_READ or self._evtype & EV_WRITE:
                self.hub.listeners[self.evtype].pop(self.fileno, None)
            self.cancelled = 1
            Py_DECREF(self)
            event_pool.append(self)

    @property
    def evtype(self):
        if self._evtype & EV_READ:
            return READ
        elif self._evtype & EV_WRITE:
            return WRITE
        elif self._evtype & EV_TIMEOUT:
            return 'timeout'
        elif self._evtype & EV_SIGNAL:
            return 'signal'


def _scheduled_call(evt, callback, args, kwargs, caller_greenlet=None):
    if not caller_greenlet or not caller_greenlet.dead:
        callback(*args, **kwargs)


cdef class EventBase:
    cdef event_base *_base

    def __cinit__(self):
        self._base = event_base_new()

    def __dealloc__(self):
        event_base_free(self._base)

    cpdef event_loop(self):
        cdef int response
        with nogil:
            response = event_base_loop(self._base, EVLOOP_ONCE)
        return response

    cpdef abort_loop(self):
        event_base_loopbreak(self._base)

    cdef Event _get_event(self):
        if event_pool and Py_REFCNT(event_pool[0]) == 2:
            return event_pool.popleft()
        return Event()

    cpdef new_event(self, callback, arg, short evtype, handle=-1,
                 seconds=None):
        cdef Event evt = self._get_event()
        evt.add(self._base, callback, arg, evtype, handle, seconds, self)
        return evt


class Hub(EventBase, BaseHub):

    def __init__(self):
        super(Hub, self).__init__()
        self._event_exc = None
        self.signal_exc_info = None
        self.signal(2, self.keyboard_interrupt)

    def keyboard_interrupt(self, signalnum, frame):
        self.greenlet.parent.throw(KeyboardInterrupt)

    def run(self):
        while True:
            try:
                result = self.event_loop()
                if self._event_exc is not None:
                    t = self._event_exc
                    self._event_exc = None
                    raise t[0], t[1], t[2]

                if result != 0:
                    return result
            except greenlets.GreenletExit:
                break
            except self.SYSTEM_EXCEPTIONS:
                raise
            except:
                if self.signal_exc_info is not None:
                    self.schedule_call_global(
                        0, greenlets.getcurrent().parent.throw, *self.signal_exc_info)
                    self.signal_exc_info = None
                else:
                    self.squelch_timer_exception(None, sys.exc_info())

    def abort(self, wait=True):
        self.schedule_call_global(0, self.greenlet.throw, greenlets.GreenletExit)
        if wait:
            assert self.greenlet is not greenlets.getcurrent(), \
                        "Can't abort with wait from inside the hub's greenlet."
            self.switch()

    def _getrunning(self):
        return bool(self.greenlet)

    def _setrunning(self, value):
        pass  # exists for compatibility with BaseHub
    running = property(_getrunning, _setrunning)

    def add(self, evtype, fileno, cb, persist=False):
        cdef short event_type
        if evtype is READ:
            event_type = EV_READ
        elif evtype is WRITE:
            event_type = EV_WRITE
        if persist:
            event_type &= EV_PERSIST
        evt = self.new_event(cb, (fileno,), event_type, fileno)
        return evt

    def remove(self, listener):
        listener.cancel(False)

    def remove_descriptor(self, fileno):
        for lcontainer in self.listeners.itervalues():
            if fileno in lcontainer:
                try:
                    lcontainer.pop(fileno).cancel()
                except self.SYSTEM_EXCEPTIONS:
                    raise
                except:
                    traceback.print_exc()

    def _signal_wrapper(self, signalnum, handler):
        try:
            handler(signalnum, None)
        except:
            self.signal_exc_info = sys.exc_info()
            self.abort_loop()

    def signal(self, signalnum, handler):
        evt = self.new_event(self._signal_wrapper, (signalnum, handler),
                             EV_SIGNAL | EV_PERSIST, signalnum)
        return evt

    def schedule_call_local(self, seconds, cb, *args, **kwargs):
        current = greenlets.getcurrent()
        if current is self.greenlet:
            return self.schedule_call_global(seconds, cb, *args, **kwargs)
        args = [None, cb, args, kwargs, current]
        evt = self.new_event(_scheduled_call, args, EV_TIMEOUT, seconds=seconds)
        args[0] = evt
        return evt

    schedule_call = schedule_call_local

    def schedule_call_global(self, seconds, cb, *args, **kwargs):
        args = [None, cb, args, kwargs]
        evt = self.new_event(_scheduled_call, args, EV_TIMEOUT, seconds=seconds)
        args[0] = evt
        return evt

    def async_exception_occurred(self):
        self._event_exc = sys.exc_info()

def use():
    eventlet.hubs.use_hub(Hub)
