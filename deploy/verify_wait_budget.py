"""Standalone check of the timeout-budget logic in _waitForPeerRowId.

The Dart change cannot be exercised locally (pub get is blocked), so this
mirrors the algorithm and asserts the properties that matter:

  1. the total wait never exceeds the caller's budget, even when each
     request consumes its full timeout
  2. a request that hangs is abandoned instead of blocking forever
  3. a peer that shows up mid-wait is still found

Run: python deploy/verify_wait_budget.py
"""
import time

PEER_WAIT_INTERVAL = 5.0      # seconds
HTTP_TIMEOUT = 20.0           # seconds


def wait_for_peer(find_row_id, timeout):
    """Mirror of StoreSyncService._waitForPeerRowId.

    find_row_id(remaining_slice) -> row_id or None; may take up to
    `slice` seconds to return (simulating a hanging request).
    """
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        slice_ = remaining if remaining < HTTP_TIMEOUT else HTTP_TIMEOUT
        row_id = find_row_id(slice_)
        if row_id is not None and row_id > 0:
            return row_id
        left = deadline - time.monotonic()
        if left <= 0:
            return None
        time.sleep(left if left < PEER_WAIT_INTERVAL else PEER_WAIT_INTERVAL)


def test_budget_respected_with_hanging_requests():
    """Every request hangs for its full slice; total must stay within budget."""
    budget = 30.0
    calls = []

    def hanging(slice_):
        calls.append(slice_)
        time.sleep(slice_)
        return None

    start = time.monotonic()
    row_id = wait_for_peer(hanging, budget)
    elapsed = time.monotonic() - start

    assert row_id is None, 'should give up'
    assert elapsed <= budget + 1.0, f'overran budget: {elapsed:.1f}s > {budget}s'
    print(f'[OK] hanging requests: waited {elapsed:.1f}s within {budget}s budget '
          f'({len(calls)} attempts)')


def test_budget_respected_with_slow_but_finite_requests():
    """Requests take 3s each and always miss; total must stay within budget."""
    budget = 30.0

    def slow(slice_):
        time.sleep(min(3.0, slice_))
        return None

    start = time.monotonic()
    row_id = wait_for_peer(slow, budget)
    elapsed = time.monotonic() - start

    assert row_id is None
    assert elapsed <= budget + 1.0, f'overran budget: {elapsed:.1f}s'
    print(f'[OK] slow requests: waited {elapsed:.1f}s within {budget}s budget')


def test_finds_peer_midway():
    """A peer that appears on the third attempt must still be found."""
    state = {'n': 0}

    def eventually(slice_):
        state['n'] += 1
        if state['n'] >= 3:
            return 42
        return None

    row_id = wait_for_peer(eventually, 30.0)
    assert row_id == 42, f'expected 42, got {row_id}'
    print(f'[OK] peer found on attempt {state["n"]}')


def test_first_attempt_hit():
    state = {'n': 0}

    def immediate(slice_):
        state['n'] += 1
        return 7

    row_id = wait_for_peer(immediate, 30.0)
    assert row_id == 7
    assert state['n'] == 1, 'should not poll again once found'
    print('[OK] peer found on first attempt, no extra polling')


def test_zero_budget_returns_immediately():
    def should_not_run(slice_):
        raise AssertionError('must not make a request with an exhausted budget')

    row_id = wait_for_peer(should_not_run, 0.0)
    assert row_id is None
    print('[OK] zero budget returns immediately without any request')


if __name__ == '__main__':
    test_budget_respected_with_hanging_requests()
    test_budget_respected_with_slow_but_finite_requests()
    test_finds_peer_midway()
    test_first_attempt_hit()
    test_zero_budget_returns_immediately()
    print('\nall wait-budget checks passed')
