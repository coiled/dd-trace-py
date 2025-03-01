import threading
import uuid

import pytest
from six.moves import _thread

from ddtrace.profiling import recorder
from ddtrace.profiling.collector import threading as collector_threading

from . import test_collector


def test_repr():
    test_collector._test_repr(
        collector_threading.LockCollector,
        "LockCollector(status=<ServiceStatus.STOPPED: 'stopped'>, "
        "recorder=Recorder(default_max_events=32768, max_events={}), capture_pct=2.0, nframes=64, tracer=None)",
    )


def test_wrapper():
    r = recorder.Recorder()
    collector = collector_threading.LockCollector(r)
    with collector:

        class Foobar(object):
            lock_class = threading.Lock

            def __init__(self):
                lock = self.lock_class()
                assert lock.acquire()
                lock.release()

        # Try to access the attribute
        lock = Foobar.lock_class()
        assert lock.acquire()
        lock.release()

        # Try this way too
        Foobar()


def test_patch():
    r = recorder.Recorder()
    lock = threading.Lock
    collector = collector_threading.LockCollector(r)
    collector.start()
    assert lock == collector.original
    # wrapt makes this true
    assert lock == threading.Lock
    collector.stop()
    assert lock == threading.Lock
    assert collector.original == threading.Lock


def test_lock_acquire_events():
    r = recorder.Recorder()
    with collector_threading.LockCollector(r, capture_pct=100):
        lock = threading.Lock()
        lock.acquire()
    assert len(r.events[collector_threading.LockAcquireEvent]) == 1
    assert len(r.events[collector_threading.LockReleaseEvent]) == 0
    event = r.events[collector_threading.LockAcquireEvent][0]
    assert event.lock_name == "test_threading.py:59"
    assert event.thread_id == _thread.get_ident()
    assert event.wait_time_ns > 0
    # It's called through pytest so I'm sure it's gonna be that long, right?
    assert len(event.frames) > 3
    assert event.nframes > 3
    assert event.frames[0] == (__file__, 60, "test_lock_acquire_events")
    assert event.sampling_pct == 100


def test_lock_events_tracer(tracer):
    resource = str(uuid.uuid4())
    span_type = str(uuid.uuid4())
    r = recorder.Recorder()
    with collector_threading.LockCollector(r, tracer=tracer, capture_pct=100):
        lock = threading.Lock()
        lock.acquire()
        with tracer.trace("test", resource=resource, span_type=span_type) as t:
            lock2 = threading.Lock()
            lock2.acquire()
            lock.release()
            trace_id = t.trace_id
            span_id = t.span_id
        lock2.release()
    events = r.reset()
    # The tracer might use locks, so we need to look into every event to assert we got ours
    for event_type in (collector_threading.LockAcquireEvent, collector_threading.LockReleaseEvent):
        assert {"test_threading.py:79", "test_threading.py:82"}.issubset({e.lock_name for e in events[event_type]})
        for event in events[event_type]:
            if event.name == "test_threading.py:79":
                assert event.trace_id is None
                assert event.span_id is None
                assert event.trace_resource is None
                assert event.trace_type is None
            elif event.name == "test_threading.py:82":
                assert event.trace_id == trace_id
                assert event.span_id == span_id
                assert event.trace_resource == t.resource
                assert event.trace_type == t.span_type


def test_lock_release_events():
    r = recorder.Recorder()
    with collector_threading.LockCollector(r, capture_pct=100):
        lock = threading.Lock()
        lock.acquire()
        lock.release()
    assert len(r.events[collector_threading.LockAcquireEvent]) == 1
    assert len(r.events[collector_threading.LockReleaseEvent]) == 1
    event = r.events[collector_threading.LockReleaseEvent][0]
    assert event.lock_name == "test_threading.py:108"
    assert event.thread_id == _thread.get_ident()
    assert event.locked_for_ns >= 0.1
    # It's called through pytest so I'm sure it's gonna be that long, right?
    assert len(event.frames) > 3
    assert event.nframes > 3
    assert event.frames[0] == (__file__, 110, "test_lock_release_events")
    assert event.sampling_pct == 100


@pytest.mark.benchmark(
    group="threading-lock-create",
)
def test_lock_create_speed_patched(benchmark):
    r = recorder.Recorder()
    with collector_threading.LockCollector(r):
        benchmark(threading.Lock)


@pytest.mark.benchmark(
    group="threading-lock-create",
)
def test_lock_create_speed(benchmark):
    benchmark(threading.Lock)


def _lock_acquire_release(lock):
    lock.acquire()
    lock.release()


@pytest.mark.benchmark(
    group="threading-lock-acquire-release",
)
@pytest.mark.parametrize(
    "pct",
    range(5, 61, 5),
)
def test_lock_acquire_release_speed_patched(benchmark, pct):
    r = recorder.Recorder()
    with collector_threading.LockCollector(r, capture_pct=pct):
        benchmark(_lock_acquire_release, threading.Lock())


@pytest.mark.benchmark(
    group="threading-lock-acquire-release",
)
def test_lock_acquire_release_speed(benchmark):
    benchmark(_lock_acquire_release, threading.Lock())
