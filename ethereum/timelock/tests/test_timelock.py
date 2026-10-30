#!/usr/bin/env python3

"""Functional tests of the TimeLock contract.

Mirror of the CosmWasm `fetch/contract-timelock` test-suite (`queue_tests.rs`, `tests.rs`),
executed against the Ape `test` (eth-tester / py-evm) local provider.
"""

import pytest
from ape import accounts, chain, project, reverts
from eth_utils import keccak

# --------------------------------------------------------------------------------------
# ----     CONSTANTS     ----------------------------------------------------------------
# --------------------------------------------------------------------------------------

REVERSE_SWAP_LOCK_DELAY = 10
REFUND_LOCK_DELAY = 20
N_MAX_PENDING_MESSAGES = 5

MAX_UINT64 = 2**64 - 1
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"

ADMIN_ROLE = b"\x00" * 32  # DEFAULT_ADMIN_ROLE == 0
SUBMIT_ROLE = keccak(text="SUBMIT_ROLE")
EXECUTE_ROLE = keccak(text="EXECUTE_ROLE")
CANCEL_ROLE = keccak(text="CANCEL_ROLE")

TX_HASH = b"\x11" * 32

# Message kinds (mirror of ITimeLock.MsgKind)
KIND_REVERSE_SWAP = 0
KIND_REFUND = 1
KIND_REFUND_IN_FULL = 2
KIND_NEW_RELAY_EON = 3

# Execution states (mirror of ITimeLock.ExecutionState)
STATE_PENDING = 0
STATE_EXECUTED = 1
STATE_CANCELLED = 2
STATE_FAILED = 3


# --------------------------------------------------------------------------------------
# ----     FIXTURES     -----------------------------------------------------------------
# --------------------------------------------------------------------------------------

@pytest.fixture(scope="module")
def owner():
    return accounts.test_accounts[0]


@pytest.fixture(scope="module")
def submitter():
    return accounts.test_accounts[1]


@pytest.fixture(scope="module")
def executor():
    return accounts.test_accounts[2]


@pytest.fixture(scope="module")
def canceller():
    return accounts.test_accounts[3]


@pytest.fixture(scope="module")
def nobody():
    return accounts.test_accounts[4]


@pytest.fixture()
def bridge_mock(owner):
    return owner.deploy(project.BridgeRelayerMock)


@pytest.fixture()
def timelock(owner, bridge_mock, submitter, executor, canceller):
    contract = owner.deploy(
        project.TimeLock,
        bridge_mock.address,
        REVERSE_SWAP_LOCK_DELAY,
        REFUND_LOCK_DELAY,
        N_MAX_PENDING_MESSAGES,
        owner.address,
    )
    contract.grantRole(SUBMIT_ROLE, submitter.address, sender=owner)
    contract.grantRole(EXECUTE_ROLE, executor.address, sender=owner)
    contract.grantRole(CANCEL_ROLE, canceller.address, sender=owner)
    return contract


# --------------------------------------------------------------------------------------
# ----     HELPERS     -----------------------------------------------------------------
# --------------------------------------------------------------------------------------

def travel(blocks: int):
    """Advance the chain height by `blocks` (mines empty blocks)."""
    chain.mine(blocks)


def submit_reverse_swap(tl, submitter, rid=1, to=None, sender_str="fetch1origin",
                       tx_hash=TX_HASH, amount=100, relay_eon=0):
    to = to or submitter.address
    return tl.submitReverseSwap(
        rid, to, sender_str, tx_hash, amount, relay_eon, sender=submitter
    )


def submit_refund(tl, submitter, id=1, to=None, amount=100, relay_eon=0):
    to = to or submitter.address
    return tl.submitRefund(id, to, amount, relay_eon, sender=submitter)


def submit_refund_in_full(tl, submitter, id=1, to=None, amount=100, relay_eon=0):
    to = to or submitter.address
    return tl.submitRefundInFull(id, to, amount, relay_eon, sender=submitter)


def assert_message(actual, kind, state, execution_block, relay_eon, id, amount, to,
                   sender, tx_hash):
    assert actual["kind"] == kind
    assert actual["state"] == state
    assert actual["executionBlock"] == execution_block
    assert actual["relayEon"] == relay_eon
    assert actual["id"] == id
    assert actual["amount"] == amount
    assert actual["to"] == to
    assert actual["sender"] == sender
    assert actual["originTxHash"] == tx_hash


def pending_of(tl, start_after=0, limit=50):
    return [(v["nonce"], v["message"]) for v in tl.getPendingMessages(start_after, limit)]


def event_of(tx, name: str):
    """First log of the given event name emitted in `tx` (ape 0.8: `tx.events` is a list)."""
    matches = [log for log in tx.events if log.event_name == name]
    assert matches, f"event {name} not emitted in {tx.txn_hash}"
    return matches[0].event_arguments


# --------------------------------------------------------------------------------------
# ----     INITIALIZATION     -----------------------------------------------------------
# --------------------------------------------------------------------------------------

class TestInitialization:

    def test_initial_state(self, timelock, owner, bridge_mock):
        assert timelock.bridge() == bridge_mock.address
        assert timelock.reverseSwapLockDelay() == REVERSE_SWAP_LOCK_DELAY
        assert timelock.refundLockDelay() == REFUND_LOCK_DELAY
        assert timelock.nMaxPendingMessages() == N_MAX_PENDING_MESSAGES
        assert timelock.nextSubmitNonce() == 0
        assert timelock.nextExecuteNonce() == 0
        assert timelock.nPendingMessages() == 0
        assert timelock.pausedSinceBlock() == MAX_UINT64  # not paused
        assert timelock.hasRole(ADMIN_ROLE, owner.address)

    def test_reverts_on_invalid_input(self, owner, bridge_mock):
        with reverts():
            owner.deploy(
                project.TimeLock, ZERO_ADDRESS,
                10, 20, 5, owner.address,
            )
        with reverts():
            owner.deploy(
                project.TimeLock, bridge_mock.address,
                0, 20, 5, owner.address,
            )
        with reverts():
            owner.deploy(
                project.TimeLock, bridge_mock.address,
                10, 0, 5, owner.address,
            )
        with reverts():
            owner.deploy(
                project.TimeLock, bridge_mock.address,
                10, 20, 0, owner.address,
            )
        with reverts():
            owner.deploy(
                project.TimeLock, bridge_mock.address,
                10, 20, 5, ZERO_ADDRESS,
            )


# --------------------------------------------------------------------------------------
# ----     SUBMISSIONS     --------------------------------------------------------------
# --------------------------------------------------------------------------------------

class TestSubmit:

    def test_reverse_swap(self, timelock, submitter):
        tx = submit_reverse_swap(timelock, submitter)
        assert timelock.nextSubmitNonce() == 1
        assert timelock.nPendingMessages() == 1
        assert timelock.nextExecuteNonce() == 0
        assert timelock.reverseSwapIdToNonce(1) == 1  # nonce 0 stored as 0 + 1

        assert_message(
            timelock.getMessage(0),
            kind=KIND_REVERSE_SWAP, state=STATE_PENDING,
            execution_block=tx.block_number + REVERSE_SWAP_LOCK_DELAY,
            relay_eon=0, id=1, amount=100, to=submitter.address,
            sender="fetch1origin", tx_hash=TX_HASH,
        )

        evt = event_of(tx, "MessageSubmitted")
        assert evt["nonce"] == 0
        assert evt["kind"] == KIND_REVERSE_SWAP
        assert evt["id"] == 1

    def test_refund(self, timelock, submitter):
        tx = submit_refund(timelock, submitter)
        assert_message(
            timelock.getMessage(0),
            kind=KIND_REFUND, state=STATE_PENDING,
            execution_block=tx.block_number + REFUND_LOCK_DELAY,
            relay_eon=0, id=1, amount=100, to=submitter.address,
            sender="", tx_hash=b"\x00" * 32,
        )
        assert timelock.refundSwapIdToNonce(1) == 1  # nonce 0 stored as 0 + 1

    def test_refund_in_full(self, timelock, submitter):
        submit_refund_in_full(timelock, submitter)
        assert timelock.getMessage(0)["kind"] == KIND_REFUND_IN_FULL
        assert timelock.refundSwapIdToNonce(1) == 1

    def test_max_pending_messages(self, timelock, submitter):
        for i in range(N_MAX_PENDING_MESSAGES):
            submit_reverse_swap(timelock, submitter, rid=i + 1)

        with reverts(timelock.TooManyPendingMessages):
            submit_reverse_swap(timelock, submitter, rid=99)

    def test_duplicate_index_rejected_while_pending(self, timelock, submitter, executor):
        submit_reverse_swap(timelock, submitter, rid=7)  # nonce 0

        with reverts(timelock.MessageAlreadySubmitted):
            submit_reverse_swap(timelock, submitter, rid=7)

        # still rejected after the message got Executed (mirror of the CosmWasm `push`:
        # resubmission is blocked while the last message is Pending OR Executed)
        travel(REVERSE_SWAP_LOCK_DELAY + 1)
        timelock.execute(0, sender=executor)
        assert timelock.getMessage(0)["state"] == STATE_EXECUTED
        with reverts(timelock.MessageAlreadySubmitted):
            submit_reverse_swap(timelock, submitter, rid=7)

    def test_duplicate_index_rejected_after_failed_execution(self, timelock, submitter,
                                                             executor, bridge_mock, owner):
        submit_reverse_swap(timelock, submitter, rid=7)
        bridge_mock.setShouldRevert(True, sender=owner)
        travel(REVERSE_SWAP_LOCK_DELAY + 1)
        timelock.execute(0, sender=executor)  # fails on the bridge, but the tx succeeds

        # the message is Failed, so the index can be resubmitted (same as CosmWasm)
        bridge_mock.setShouldRevert(False, sender=owner)
        submit_reverse_swap(timelock, submitter, rid=7)

    def test_duplicate_refund_index_shares_space_with_refund_in_full(self, timelock, submitter):
        submit_refund(timelock, submitter, id=3)  # nonce 1

        with reverts(timelock.MessageAlreadySubmitted):
            submit_refund_in_full(timelock, submitter, id=3)  # shares the id space

    def test_submit_is_submit_role_only(self, timelock, nobody):
        with reverts():
            submit_reverse_swap(timelock, nobody)


# --------------------------------------------------------------------------------------
# ----     EXECUTION FLOW     -----------------------------------------------------------
# --------------------------------------------------------------------------------------

class TestExecute:

    def test_execute_success(self, timelock, submitter, executor, bridge_mock):
        submit_reverse_swap(timelock, submitter)

        # premature execution reverts (not mature)
        with reverts(timelock.MessageNotMature):
            timelock.execute(0, sender=executor)

        travel(REVERSE_SWAP_LOCK_DELAY + 1)

        tx = timelock.execute(0, sender=executor)
        assert bridge_mock.nReverseSwaps() == 1
        assert bridge_mock.reverseSwapCalls(0)["rid"] == 1
        assert timelock.getMessage(0)["state"] == STATE_EXECUTED
        assert timelock.nPendingMessages() == 0
        assert timelock.nextExecuteNonce() == 1
        assert event_of(tx, "MessageExecuted")["nonce"] == 0

    def test_execute_refund(self, timelock, submitter, executor, bridge_mock):
        submit_refund(timelock, submitter, id=5, amount=777)
        travel(REFUND_LOCK_DELAY + 1)
        timelock.execute(0, sender=executor)

        assert bridge_mock.nRefunds() == 1
        call = bridge_mock.refundCalls(0)
        assert call["id"] == 5
        assert call["amount"] == 777
        assert call["inFull"] is False

    def test_execute_refund_in_full(self, timelock, submitter, executor, bridge_mock):
        submit_refund_in_full(timelock, submitter, id=6, amount=888)
        travel(REFUND_LOCK_DELAY + 1)
        timelock.execute(0, sender=executor)

        assert bridge_mock.nRefunds() == 1
        call = bridge_mock.refundCalls(0)
        assert call["inFull"] is True

    def test_execute_reverts_on_wrong_nonce(self, timelock, submitter, executor):
        submit_reverse_swap(timelock, submitter)
        with reverts(timelock.MessageNotNext):
            timelock.execute(1, sender=executor)

    def test_execute_failure_marks_failed(self, timelock, submitter, executor, bridge_mock, owner):
        submit_reverse_swap(timelock, submitter)
        bridge_mock.setShouldRevert(True, sender=owner)
        travel(REVERSE_SWAP_LOCK_DELAY + 1)

        tx = timelock.execute(0, sender=executor)

        # the tx SUCCEEDED even though the bridge call failed
        assert timelock.getMessage(0)["state"] == STATE_FAILED
        assert timelock.nPendingMessages() == 0
        assert timelock.getMessage(0)["state"] == STATE_FAILED

        evt = event_of(tx, "MessageFailed")
        assert evt["nonce"] == 0
        assert len(evt["reason"]) > 0

    def test_execute_after_cancel_moves_pointer(self, timelock, submitter, executor, canceller):
        submit_reverse_swap(timelock, submitter)  # nonce 0
        submit_refund(timelock, submitter)        # nonce 1

        timelock.cancel(0, sender=canceller)
        travel(REFUND_LOCK_DELAY + 1)

        # nonce 1 is next in order now
        timelock.execute(1, sender=executor)
        assert timelock.getMessage(1)["state"] == STATE_EXECUTED


# --------------------------------------------------------------------------------------
# ----     CANCELLATION     -------------------------------------------------------------
# --------------------------------------------------------------------------------------

class TestCancel:

    def test_cancel_skips_message(self, timelock, submitter, executor, canceller, bridge_mock):
        submit_reverse_swap(timelock, submitter)  # nonce 0
        submit_refund(timelock, submitter)        # nonce 1

        timelock.cancel(0, sender=canceller)
        assert timelock.getMessage(0)["state"] == STATE_CANCELLED
        assert timelock.nPendingMessages() == 1
        assert timelock.nextExecuteNonce() == 1  # skipped to the refund

        travel(REFUND_LOCK_DELAY + 1)
        timelock.execute(1, sender=executor)
        assert bridge_mock.nRefunds() == 1

    def test_cancel_reverts_on_not_pending(self, timelock, submitter, canceller):
        submit_reverse_swap(timelock, submitter)
        timelock.cancel(0, sender=canceller)
        with reverts(timelock.MessageNotPending):
            timelock.cancel(0, sender=canceller)

    def test_cancel_is_cancel_role_only(self, timelock, nobody):
        with reverts():
            timelock.cancel(0, sender=nobody)


# --------------------------------------------------------------------------------------
# ----     NEW RELAY EON     ------------------------------------------------------------
# --------------------------------------------------------------------------------------

class TestNewRelayEon:

    def test_new_relay_eon(self, timelock, submitter, bridge_mock):
        submit_reverse_swap(timelock, submitter)  # nonce 0 - will be cancelled
        timelock.newRelayEon(sender=submitter)

        assert timelock.getMessage(0)["state"] == STATE_CANCELLED
        assert timelock.getMessage(1)["state"] == STATE_EXECUTED
        assert timelock.nPendingMessages() == 0
        assert bridge_mock.nNewRelayEons() == 1
        assert bridge_mock.relayEon() == 0  # MAX_UINT64 + 1 overflows to 0
        assert timelock.nextExecuteNonce() == 2
        assert timelock.nextSubmitNonce() == 2

    def test_new_relay_eon_bypasses_pending_limit(self, timelock, submitter, bridge_mock):
        for i in range(N_MAX_PENDING_MESSAGES):
            submit_reverse_swap(timelock, submitter, rid=i + 1)

        # even with a full queue, newRelayEon goes through (cancels all first)
        timelock.newRelayEon(sender=submitter)
        assert timelock.nPendingMessages() == 0
        assert bridge_mock.nNewRelayEons() == 1

    def test_new_relay_eon_is_submit_role_only(self, timelock, nobody):
        with reverts():
            timelock.newRelayEon(sender=nobody)


# --------------------------------------------------------------------------------------
# ----     PAUSING     ------------------------------------------------------------------
# --------------------------------------------------------------------------------------

class TestPausing:

    def test_pause_resume(self, timelock, owner, submitter, executor):
        timelock.pauseSince(0, sender=owner)  # paused immediately

        with reverts(timelock.ContractIsPaused):
            submit_reverse_swap(timelock, submitter)
        with reverts(timelock.ContractIsPaused):
            timelock.execute(1, sender=executor)

        timelock.resume(sender=owner)
        submit_reverse_swap(timelock, submitter)  # works again
        assert timelock.nPendingMessages() == 1

    def test_pause_since_future_block(self, timelock, owner, submitter):
        since = chain.blocks.head.number + 100
        timelock.pauseSince(since, sender=owner)
        assert timelock.pausedSinceBlock() == since

        submit_reverse_swap(timelock, submitter)  # not yet paused
        travel(101)
        with reverts(timelock.ContractIsPaused):
            submit_reverse_swap(timelock, submitter)

    def test_pause_resume_admin_only(self, timelock, nobody):
        with reverts():
            timelock.pauseSince(0, sender=nobody)
        with reverts():
            timelock.resume(sender=nobody)


# --------------------------------------------------------------------------------------
# ----     ADMIN STATE UPDATES     ------------------------------------------------------
# --------------------------------------------------------------------------------------

class TestUpdateState:

    def test_partial_update_keeps_zeroed_fields(self, timelock, owner, bridge_mock):
        timelock.updateState(ZERO_ADDRESS, 15, 0, 0, sender=owner)
        assert timelock.reverseSwapLockDelay() == 15
        assert timelock.refundLockDelay() == REFUND_LOCK_DELAY  # kept
        assert timelock.nMaxPendingMessages() == N_MAX_PENDING_MESSAGES  # kept
        assert timelock.bridge() == bridge_mock.address  # kept

    def test_full_update(self, timelock, owner, bridge_mock):
        timelock.updateState(bridge_mock.address, 1, 2, 3, sender=owner)
        assert timelock.reverseSwapLockDelay() == 1
        assert timelock.refundLockDelay() == 2
        assert timelock.nMaxPendingMessages() == 3

    def test_update_state_is_admin_only(self, timelock, nobody):
        with reverts():
            timelock.updateState(ZERO_ADDRESS, 15, 0, 0, sender=nobody)


# --------------------------------------------------------------------------------------
# ----     ACCESS CONTROL     ----------------------------------------------------------
# --------------------------------------------------------------------------------------

class TestAccessControl:

    def test_submit_is_submit_role_only(self, timelock, nobody):
        with reverts():
            timelock.submitRefund(1, nobody.address, 1, 0, sender=nobody)

    def test_execute_is_execute_role_only(self, timelock, nobody):
        with reverts():
            timelock.execute(1, sender=nobody)

    def test_cancel_is_cancel_role_only(self, timelock, nobody):
        with reverts():
            timelock.cancel(1, sender=nobody)

    def test_admin_methods_admin_role_only(self, timelock, nobody):
        with reverts():
            timelock.updateState(ZERO_ADDRESS, 0, 0, 0, sender=nobody)


# --------------------------------------------------------------------------------------
# ----     QUERIES     -----------------------------------------------------------------
# --------------------------------------------------------------------------------------

class TestQueries:

    def test_get_pending_messages(self, timelock, submitter, canceller):
        for i in range(3):
            submit_reverse_swap(timelock, submitter, rid=i + 1)

        assert len(pending_of(timelock)) == 3
        assert [n for n, _ in pending_of(timelock)] == [0, 1, 2]
        assert [n for n, _ in pending_of(timelock, start_after=0, limit=10)] == [0, 1, 2]
        assert [n for n, _ in pending_of(timelock, start_after=1, limit=10)] == [2]

        timelock.cancel(1, sender=canceller)
        assert [n for n, _ in pending_of(timelock)] == [0, 2]

    def test_get_last_reverse_swap_message(self, timelock, submitter):
        view = timelock.getLastReverseSwapMessage(42)
        assert view["nonce"] == 0  # nothing submitted

        submit_reverse_swap(timelock, submitter, rid=42)
        view = timelock.getLastReverseSwapMessage(42)
        assert view["nonce"] == 0  # first submitted message has nonce 0
        assert view["message"]["id"] == 42

    def test_get_last_refund_message(self, timelock, submitter):
        view = timelock.getLastRefundMessage(42)
        assert view["nonce"] == 0

        submit_refund(timelock, submitter, id=42)
        view = timelock.getLastRefundMessage(42)
        assert view["nonce"] == 0  # first submitted message has nonce 0
        assert view["message"]["id"] == 42
