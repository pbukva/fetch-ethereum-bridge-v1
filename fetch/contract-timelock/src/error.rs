use crate::queue::NonceType;
use cosmwasm_std::{Addr, StdError, Uint128};

pub fn nonce_overflow_error() -> StdError {
    StdError::msg("Nonce overflow")
}

pub fn execution_height_overflow_error() -> StdError {
    StdError::msg("Execution height overflow")
}

pub fn message_not_found_error(nonce: NonceType) -> StdError {
    StdError::msg(format!("Message with nonce {nonce} not found"))
}

pub fn message_not_pending_error(nonce: NonceType) -> StdError {
    StdError::msg(format!("Message with nonce {nonce} is not pending"))
}

pub fn message_not_next_error(nonce: NonceType) -> StdError {
    StdError::msg(format!("Message with nonce {nonce} is not next to execute"))
}

pub fn message_not_mature_error(nonce: NonceType, execution_height: u64) -> StdError {
    StdError::msg(format!(
        "Message with nonce {nonce} can not be executed before block {execution_height}"
    ))
}

pub fn too_many_pending_messages_error(max_pending: u64) -> StdError {
    StdError::msg(format!(
        "Can not submit message, limit of {max_pending} pending messages reached"
    ))
}

pub fn message_already_submitted_error(nonce: NonceType) -> StdError {
    StdError::msg(format!(
        "Message with the same id is already pending or executed under nonce {nonce}"
    ))
}

pub fn not_relayer_error(relayer: &Addr) -> StdError {
    StdError::msg(format!("{relayer} does not have the bridge's relayer role"))
}

pub fn bridge_paused_error(paused_since_block: u64) -> StdError {
    StdError::msg(format!(
        "Bridge relayer API is paused since block {paused_since_block}"
    ))
}

pub fn relay_eon_error(relay_eon: u64, bridge_relay_eon: u64) -> StdError {
    StdError::msg(format!(
        "Relay eon {relay_eon} is not the bridge's relay eon {bridge_relay_eon}"
    ))
}

pub fn reverse_allowance_exceeded_error(allowance: Uint128) -> StdError {
    StdError::msg(format!(
        "Amount exceeds the bridge's reverse aggregated allowance {allowance}"
    ))
}

pub fn supply_exceeded_error(supply: Uint128) -> StdError {
    StdError::msg(format!("Amount exceeds the bridge's supply {supply}"))
}

pub fn invalid_swap_id_error(id: u64) -> StdError {
    StdError::msg(format!("Swap id {id} does not exist on the bridge"))
}

pub fn already_refunded_error(id: u64) -> StdError {
    StdError::msg(format!("Swap id {id} is already refunded on the bridge"))
}
