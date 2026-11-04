//! The bridge's checks of relayer messages, recreated on its queried state, so that submitting
//! fails for a message the bridge would reject. Other pending messages are not taken into account.

use crate::error::{
    already_refunded_error, bridge_paused_error, invalid_swap_id_error, not_relayer_error,
    relay_eon_error, reverse_allowance_exceeded_error, supply_exceeded_error,
};
use crate::queue::BridgeMessagePayload;
use cosmwasm_schema::cw_serde;
use cosmwasm_std::storage_keys::to_length_prefixed;
use cosmwasm_std::{Addr, QuerierWrapper, StdResult, Uint128};
use serde::{Deserialize, Serialize};

pub const RELAYER_ROLE: &str = "RELAYER_ROLE";

// Namespace of the bridge's refunded swap ids, it has no query for them
const REFUNDS_KEY: &[u8] = b"refunds";

#[cw_serde]
pub enum BridgeQueryMsg {
    HasRole { role: String, address: Addr },
    FullState {},
}

#[cw_serde]
pub struct RoleResponse {
    pub has_role: bool,
}

/// The fields of the bridge's `State` its checks use.
/// Not `cw_serde`, which would reject the other fields.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct BridgeState {
    pub supply: Uint128,
    pub next_swap_id: u64,
    pub relay_eon: u64,
    pub reverse_aggregated_allowance: Uint128,
    pub paused_since_block_relayer_api: u64,
}

/// Storage key of the bridge's `refunds_have`.
pub fn refunds_key(id: u64) -> Vec<u8> {
    let mut key = to_length_prefixed(REFUNDS_KEY);
    key.extend_from_slice(&id.to_be_bytes());
    key
}

/// Checks that the bridge would accept `payload` from `relayer` executed at `execution_height`.
pub fn verify_bridge_accepts(
    querier: &QuerierWrapper,
    bridge: &Addr,
    relayer: &Addr,
    payload: &BridgeMessagePayload,
    execution_height: u64,
) -> StdResult<()> {
    only_relayer(querier, bridge, relayer)?;
    let state: BridgeState = querier.query_wasm_smart(bridge, &BridgeQueryMsg::FullState {})?;
    verify_not_paused_relayer_api(execution_height, &state)?;

    match payload {
        BridgeMessagePayload::ReverseSwap {
            amount, relay_eon, ..
        } => verify_relayed_amount(*amount, *relay_eon, &state),
        BridgeMessagePayload::Refund {
            id,
            amount,
            relay_eon,
            ..
        }
        | BridgeMessagePayload::RefundInFull {
            id,
            amount,
            relay_eon,
            ..
        } => {
            verify_relayed_amount(*amount, *relay_eon, &state)?;
            verify_refund_swap_id(querier, bridge, *id, &state)
        }
        BridgeMessagePayload::NewRelayEon {} => Ok(()),
    }
}

fn only_relayer(querier: &QuerierWrapper, bridge: &Addr, relayer: &Addr) -> StdResult<()> {
    let msg = BridgeQueryMsg::HasRole {
        role: RELAYER_ROLE.to_string(),
        address: relayer.clone(),
    };
    let response: RoleResponse = querier.query_wasm_smart(bridge, &msg)?;
    if !response.has_role {
        return Err(not_relayer_error(relayer));
    }
    Ok(())
}

fn verify_not_paused_relayer_api(height: u64, state: &BridgeState) -> StdResult<()> {
    if height >= state.paused_since_block_relayer_api {
        return Err(bridge_paused_error(state.paused_since_block_relayer_api));
    }
    Ok(())
}

/// Checks shared by reverse swaps and refunds.
fn verify_relayed_amount(amount: Uint128, relay_eon: u64, state: &BridgeState) -> StdResult<()> {
    if relay_eon != state.relay_eon {
        return Err(relay_eon_error(relay_eon, state.relay_eon));
    }
    if amount > state.reverse_aggregated_allowance {
        return Err(reverse_allowance_exceeded_error(
            state.reverse_aggregated_allowance,
        ));
    }
    if amount > state.supply {
        return Err(supply_exceeded_error(state.supply));
    }
    Ok(())
}

fn verify_refund_swap_id(
    querier: &QuerierWrapper,
    bridge: &Addr,
    id: u64,
    state: &BridgeState,
) -> StdResult<()> {
    if id >= state.next_swap_id {
        return Err(invalid_swap_id_error(id));
    }
    if querier.query_wasm_raw(bridge, refunds_key(id))?.is_some() {
        return Err(already_refunded_error(id));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refunds_key_matches_bridge() {
        // Length-prefixed namespace followed by the big-endian swap id
        let mut expected = vec![0, 7];
        expected.extend_from_slice(b"refunds");
        expected.extend_from_slice(&[0, 0, 0, 0, 0, 0, 1, 2]);
        assert_eq!(refunds_key(0x0102), expected);
    }
}
