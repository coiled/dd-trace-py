"""CPU profiling collector."""
from __future__ import absolute_import

import sys
import threading
import typing
import weakref

import attr
import six

from ddtrace import context
from ddtrace import span as ddspan
from ddtrace.internal import compat
from ddtrace.internal import nogevent
from ddtrace.profiling import collector
from ddtrace.profiling import event
from ddtrace.profiling.collector import _threading
from ddtrace.profiling.collector import _traceback
from ddtrace.utils import attr as attr_utils
from ddtrace.utils import formats


# NOTE: Do not use LOG here. This code runs under a real OS thread and is unable to acquire any lock of the `logging`
# module without having gevent crashing our dedicated thread.


# These are special features that might not be available depending on your Python version and platform
FEATURES = {
    "cpu-time": False,
    "stack-exceptions": False,
    "gevent-tasks": False,
}


_gevent_tracer = None
try:
    import gevent._tracer
    import gevent.thread
except ImportError:
    _gevent_tracer = None
else:
    # NOTE: bold assumption: this module is always imported by the MainThread.
    # A GreenletTracer is local to the thread instantiating it and we assume this is run by the MainThread.
    _gevent_tracer = gevent._tracer.GreenletTracer()
    FEATURES["gevent-tasks"] = True


IF UNAME_SYSNAME == "Linux":
    FEATURES['cpu-time'] = True

    from posix.time cimport clock_gettime
    from posix.time cimport timespec
    from posix.types cimport clockid_t

    from cpython.exc cimport PyErr_SetFromErrno

    cdef extern from "<pthread.h>":
        # POSIX says this might be a struct, but CPython relies on it being an unsigned long.
        # We should be defining pthread_t here like this:
        # ctypedef unsigned long pthread_t
        # but e.g. musl libc defines pthread_t as a struct __pthread * which breaks the arithmetic Cython
        # wants to do.
        # We pay this with a warning at compilation time, but it works anyhow.
        int pthread_getcpuclockid(unsigned long thread, clockid_t *clock_id)

    cdef p_pthread_getcpuclockid(tid):
        cdef clockid_t clock_id
        if pthread_getcpuclockid(tid, &clock_id) == 0:
            return clock_id
        PyErr_SetFromErrno(OSError)

    # Python < 3.3 does not have `time.clock_gettime`
    cdef p_clock_gettime_ns(clk_id):
        cdef timespec tp
        if clock_gettime(clk_id, &tp) == 0:
            return int(tp.tv_nsec + tp.tv_sec * 10e8)
        PyErr_SetFromErrno(OSError)

    cdef class _ThreadTime(object):
        cdef dict _last_thread_time

        def __init__(self):
            # This uses a tuple of (pthread_id, thread_native_id) as the key to identify the thread: you'd think using
            # the pthread_t id would be enough, but the glibc reuses the id.
            self._last_thread_time = {}

        # Only used in tests
        def _get_last_thread_time(self):
            return dict(self._last_thread_time)

        def __call__(self, pthread_ids):
            cdef list cpu_times = []
            for pthread_id in pthread_ids:
                # TODO: Use QueryThreadCycleTime on Windows?
                # ⚠ WARNING ⚠
                # `pthread_getcpuclockid` can make Python segfault if the thread is does not exist anymore.
                # In order avoid this, this function must be called with the GIL being held the entire time.
                # This is why this whole file is compiled down to C: we make sure we never release the GIL between
                # calling sys._current_frames() and pthread_getcpuclockid, making sure no thread disappeared.
                try:
                    cpu_time = p_clock_gettime_ns(p_pthread_getcpuclockid(pthread_id))
                except OSError:
                    # Just in case it fails, set it to 0
                    # (Note that glibc never fails, it segfaults instead)
                    cpu_time = 0
                cpu_times.append(cpu_time)

            cdef dict pthread_cpu_time = {}

            # We should now be safe doing more Pythonic stuff and maybe releasing the GIL
            for pthread_id, cpu_time in zip(pthread_ids, cpu_times):
                thread_native_id = _threading.get_thread_native_id(pthread_id)
                key = pthread_id, thread_native_id
                # Do a max(0, …) here just in case the result is < 0:
                # This should never happen, but it can happen if the one chance in a billion happens:
                # - A new thread has been created and has the same native id and the same pthread_id.
                # - We got an OSError with clock_gettime_ns
                pthread_cpu_time[key] = max(0, cpu_time - self._last_thread_time.get(key, cpu_time))
                self._last_thread_time[key] = cpu_time

            # Clear cache
            keys = list(pthread_cpu_time.keys())
            for key in list(self._last_thread_time.keys()):
                if key not in keys:
                    del self._last_thread_time[key]

            return pthread_cpu_time
ELSE:
    cdef class _ThreadTime(object):
        cdef long _last_process_time

        def __init__(self):
            self._last_process_time = compat.process_time_ns()

        def __call__(self, pthread_ids):
            current_process_time = compat.process_time_ns()
            cpu_time = current_process_time - self._last_process_time
            self._last_process_time = current_process_time
            # Spread the consumed CPU time on all threads.
            # It's not fair, but we have no clue which CPU used more unless we can use `pthread_getcpuclockid`
            # Check that we don't have zero thread — _might_ very rarely happen at shutdown
            nb_threads = len(pthread_ids)
            if nb_threads == 0:
                cpu_time = 0
            else:
                cpu_time //= nb_threads
            return {
                (pthread_id, _threading.get_thread_native_id(pthread_id)): cpu_time
                for pthread_id in pthread_ids
            }


@event.event_class
class StackSampleEvent(event.StackBasedEvent):
    """A sample storing executions frames for a thread."""

    # Wall clock
    wall_time_ns = attr.ib(default=0)
    # CPU time in nanoseconds
    cpu_time_ns = attr.ib(default=0)


@event.event_class
class StackExceptionSampleEvent(event.StackBasedEvent):
    """A a sample storing raised exceptions and their stack frames."""

    exc_type = attr.ib(default=None)

from cpython.object cimport PyObject


# The head lock (the interpreter mutex) is only exposed in a data structure in Python ≥ 3.7
IF UNAME_SYSNAME != "Windows" and PY_MAJOR_VERSION >= 3 and PY_MINOR_VERSION >= 7:
    FEATURES['stack-exceptions'] = True

    from cpython cimport PyInterpreterState
    from cpython cimport PyInterpreterState_Head
    from cpython cimport PyInterpreterState_Next
    from cpython cimport PyInterpreterState_ThreadHead
    from cpython cimport PyThreadState_Next
    from cpython.pythread cimport PY_LOCK_ACQUIRED
    from cpython.pythread cimport PyThread_acquire_lock
    from cpython.pythread cimport PyThread_release_lock
    from cpython.pythread cimport PyThread_type_lock
    from cpython.pythread cimport WAIT_LOCK

    cdef extern from "<Python.h>":
        # This one is provided as an opaque struct from Cython's cpython/pystate.pxd,
        # but we need to access some of its fields so we redefine it here.
        ctypedef struct PyThreadState:
            unsigned long thread_id
            PyObject* frame

        _PyErr_StackItem * _PyErr_GetTopmostException(PyThreadState *tstate)

        ctypedef struct _PyErr_StackItem:
            PyObject* exc_type
            PyObject* exc_value
            PyObject* exc_traceback

    IF PY_MINOR_VERSION == 7:
        # Python 3.7
        cdef extern from "<internal/pystate.h>":

            cdef struct pyinterpreters:
                PyThread_type_lock mutex

            ctypedef struct _PyRuntimeState:
                pyinterpreters interpreters

            cdef extern _PyRuntimeState _PyRuntime

    ELIF PY_MINOR_VERSION >= 8:
        # Python 3.8
        cdef extern from "<internal/pycore_pystate.h>":

            cdef struct pyinterpreters:
                PyThread_type_lock mutex

            ctypedef struct _PyRuntimeState:
                pyinterpreters interpreters

            cdef extern _PyRuntimeState _PyRuntime

        IF PY_MINOR_VERSION >= 9:
            # Needed for accessing _PyGC_FINALIZED when we build with -DPy_BUILD_CORE
            cdef extern from "<internal/pycore_gc.h>":
                pass
ELSE:
    from cpython.ref cimport Py_DECREF

    cdef extern from "<pystate.h>":
        PyObject* _PyThread_CurrentFrames()


cdef get_task(thread_id):
    """Return the task id and name for a thread."""
    # gevent greenlet support:
    # we only support tracing tasks in the greenlets are run in the MainThread.
    if thread_id == nogevent.main_thread_id and _gevent_tracer is not None:
        if _gevent_tracer.active_greenlet is None:
            # That means gevent never switch to another greenlet, we're still in the main one
            task_id = compat.main_thread.ident
        else:
            task_id = gevent.thread.get_ident(_gevent_tracer.active_greenlet)

        # Greenlets might be started as Thread in gevent
        task_name = _threading.get_thread_name(task_id)
    else:
        task_id = None
        task_name = None

    return task_id, task_name


cdef collect_threads(thread_id_ignore_list, thread_time, thread_span_links) with gil:
    cdef dict current_exceptions = {}

    IF UNAME_SYSNAME != "Windows" and PY_MAJOR_VERSION >= 3 and PY_MINOR_VERSION >= 7:
        cdef PyInterpreterState* interp
        cdef PyThreadState* tstate
        cdef _PyErr_StackItem* exc_info
        cdef PyThread_type_lock lmutex = _PyRuntime.interpreters.mutex

        cdef dict running_threads = {}

        # This is an internal lock but we do need it.
        # See https://bugs.python.org/issue1021318
        if PyThread_acquire_lock(lmutex, WAIT_LOCK) == PY_LOCK_ACQUIRED:
            # Do not try to do anything fancy here:
            # Even calling print() will deadlock the program has it will try
            # to lock the GIL and somehow touching this mutex.
            try:
                interp = PyInterpreterState_Head()

                while interp:
                    tstate = PyInterpreterState_ThreadHead(interp)
                    while tstate:
                        # The frame can be NULL
                        if tstate.frame:
                            running_threads[tstate.thread_id] = <object>tstate.frame

                        exc_info = _PyErr_GetTopmostException(tstate)
                        if exc_info and exc_info.exc_type and exc_info.exc_traceback:
                            current_exceptions[tstate.thread_id] = (<object>exc_info.exc_type, <object>exc_info.exc_traceback)

                        tstate = PyThreadState_Next(tstate)

                    interp = PyInterpreterState_Next(interp)
            finally:
                PyThread_release_lock(lmutex)
    ELSE:
        cdef dict running_threads = <dict>_PyThread_CurrentFrames()

        # Now that we own the ref via <dict> casting, we can safely decrease the default refcount
        # so we don't leak the object
        Py_DECREF(running_threads)

    cdef dict cpu_times = thread_time(running_threads.keys())

    return tuple(
        (
            pthread_id,
            native_thread_id,
            _threading.get_thread_name(pthread_id),
            running_threads[pthread_id],
            current_exceptions.get(pthread_id),
            thread_span_links.get_active_span_from_thread_id(pthread_id) if thread_span_links else None,
            cpu_time,
        )
        for (pthread_id, native_thread_id), cpu_time in cpu_times.items()
        if pthread_id not in thread_id_ignore_list
    )



cdef stack_collect(ignore_profiler, thread_time, max_nframes, interval, wall_time, thread_span_links):

    if ignore_profiler:
        # Do not use `threading.enumerate` to not mess with locking (gevent!)
        thread_id_ignore_list = {thread_id
                                 for thread_id, thread in threading._active.items()
                                 if getattr(thread, "_ddtrace_profiling_ignore", False)}
    else:
        thread_id_ignore_list = set()

    running_threads = collect_threads(thread_id_ignore_list, thread_time, thread_span_links)

    if thread_span_links:
        # FIXME also use native thread id
        thread_span_links.clear_threads(tuple(thread[0] for thread in running_threads))

    stack_events = []
    exc_events = []

    for thread_id, thread_native_id, thread_name, frame, exception, span, cpu_time in running_threads:
        task_id, task_name = get_task(thread_id)

        # When gevent thread monkey-patching is enabled, our PeriodicCollector non-real-threads are gevent tasks
        # Therefore, they run in the main thread and their samples are collected by `collect_threads`.
        # We ignore them here:
        if task_id in thread_id_ignore_list:
            continue

        frames, nframes = _traceback.pyframe_to_frames(frame, max_nframes)

        if span is None:
            trace_id = None
            span_id = None
            trace_type = None
            trace_resource = None
        else:
            trace_id = span.trace_id
            span_id = span.span_id
            if span._local_root is None:
                trace_type = None
                trace_resource = None
            else:
                trace_type = span._local_root.span_type
                trace_resource = span._local_root.resource

        stack_events.append(
            StackSampleEvent(
                thread_id=thread_id,
                thread_native_id=thread_native_id,
                thread_name=thread_name,
                task_id=task_id,
                task_name=task_name,
                trace_id=trace_id,
                span_id=span_id,
                trace_resource=trace_resource,
                trace_type=trace_type,
                nframes=nframes, frames=frames,
                wall_time_ns=wall_time,
                cpu_time_ns=cpu_time,
                sampling_period=int(interval * 1e9),
            ),
        )

        if exception is not None:
            exc_type, exc_traceback = exception
            frames, nframes = _traceback.traceback_to_frames(exc_traceback, max_nframes)
            exc_events.append(
                StackExceptionSampleEvent(
                    thread_id=thread_id,
                    thread_name=thread_name,
                    thread_native_id=thread_native_id,
                    task_id=task_id,
                    task_name=task_name,
                    trace_id=trace_id,
                    span_id=span_id,
                    trace_resource=trace_resource,
                    trace_type=trace_type,
                    nframes=nframes,
                    frames=frames,
                    sampling_period=int(interval * 1e9),
                    exc_type=exc_type,
                ),
            )

    return stack_events, exc_events


@attr.s(slots=True, eq=False)
class _ThreadSpanLinks(object):

    # Key is a thread_id
    # Value is a weakref to latest active span
    _thread_id_to_spans = attr.ib(factory=dict, repr=False, init=False, type=typing.Dict[int, ddspan.Span])
    _lock = attr.ib(factory=nogevent.Lock, repr=False, init=False, type=nogevent.Lock)

    def link_span(
            self,
            span # type: typing.Optional[typing.Union[context.Context, ddspan.Span]]
    ):
        # type: (...) -> None
        """Link a span to its running environment.

        Track threads, tasks, etc.
        """
        # Since we're going to iterate over the set, make sure it's locked
        if isinstance(span, ddspan.Span):
            with self._lock:
                self._thread_id_to_spans[nogevent.thread_get_ident()] = weakref.ref(span)

    def clear_threads(self, existing_thread_ids):
        """Clear the stored list of threads based on the list of existing thread ids.

        If any thread that is part of this list was stored, its data will be deleted.

        :param existing_thread_ids: A set of thread ids to keep.
        """
        with self._lock:
            # Iterate over a copy of the list of keys since it's mutated during our iteration.
            for thread_id in list(self._thread_id_to_spans.keys()):
                if thread_id not in existing_thread_ids:
                    del self._thread_id_to_spans[thread_id]

    def get_active_span_from_thread_id(
            self,
            thread_id # type: int
    ):
        # type: (...) -> typing.Optional[ddspan.Span]
        """Return the latest active span for a thread.

        :param thread_id: The thread id.
        :return: A set with the active spans.
        """

        with self._lock:
            active_span_ref = self._thread_id_to_spans.get(thread_id)
            if active_span_ref is not None:
                active_span = active_span_ref()
                if active_span is not None and not active_span.finished:
                    return active_span
                return None


def _default_min_interval_time():
    if six.PY2:
        return 0.01
    return sys.getswitchinterval() * 2


@attr.s(slots=True)
class StackCollector(collector.PeriodicCollector):
    """Execution stacks collector."""
    # This need to be a real OS thread in order to catch
    _real_thread = True
    _interval = attr.ib(factory=_default_min_interval_time, init=False, repr=False)
    # This is the minimum amount of time the thread will sleep between polling interval,
    # no matter how fast the computer is.
    min_interval_time = attr.ib(factory=_default_min_interval_time, init=False)

    max_time_usage_pct = attr.ib(factory=attr_utils.from_env("DD_PROFILING_MAX_TIME_USAGE_PCT", 1, float))
    nframes = attr.ib(factory=attr_utils.from_env("DD_PROFILING_MAX_FRAMES", 64, int))
    ignore_profiler = attr.ib(factory=attr_utils.from_env("DD_PROFILING_IGNORE_PROFILER", False, formats.asbool))
    tracer = attr.ib(default=None)
    _thread_time = attr.ib(init=False, repr=False, eq=False)
    _last_wall_time = attr.ib(init=False, repr=False, eq=False)
    _thread_span_links = attr.ib(default=None, init=False, repr=False, eq=False)

    @max_time_usage_pct.validator
    def _check_max_time_usage(self, attribute, value):
        if value <= 0 or value > 100:
            raise ValueError("Max time usage percent must be greater than 0 and smaller or equal to 100")

    def _init(self):
        self._thread_time = _ThreadTime()
        self._last_wall_time = compat.monotonic_ns()
        if self.tracer is not None:
            self._thread_span_links = _ThreadSpanLinks()
            self.tracer.context_provider._on_activate(self._thread_span_links.link_span)

    def _start_service(self):
        # This is split in its own function to ease testing
        self._init()
        super(StackCollector, self)._start_service()

    def _stop_service(self):
        super(StackCollector, self)._stop_service()
        if self.tracer is not None:
            self.tracer.context_provider._deregister_on_activate(self._thread_span_links.link_span)

    def _compute_new_interval(self, used_wall_time_ns):
        interval = (used_wall_time_ns / (self.max_time_usage_pct / 100.0)) - used_wall_time_ns
        return max(interval / 1e9, self.min_interval_time)

    def collect(self):
        # Compute wall time
        now = compat.monotonic_ns()
        wall_time = now - self._last_wall_time
        self._last_wall_time = now

        all_events = stack_collect(
            self.ignore_profiler, self._thread_time, self.nframes, self.interval, wall_time, self._thread_span_links,
        )

        used_wall_time_ns = compat.monotonic_ns() - now
        self.interval = self._compute_new_interval(used_wall_time_ns)

        return all_events
