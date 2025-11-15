use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tracing::info;

const DOMAIN_TAG: &[u8] = b"nautilus/order/v1";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderAction {
	Initiate,
	Deposit,
	Release,
	Refund,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderStatus {
	Pending,
	Escrowed,
	Released,
	Refunded,
	Rejected,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderRequest {
	pub version: u8,                // protocol version, start with 1
	pub order_id: String,
	pub customer: String,
	pub merchant: String,
	pub amount: u64,                // minor units (e.g., cents)
	pub currency: String,           // e.g., "USD"
	pub action: OrderAction,        // desired action
	pub client_timestamp_ms: Option<u64>,
	pub metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignableOrderResponse {
	pub version: u8,                // protocol version
	pub order_id: String,
	pub action: OrderAction,
	pub status: OrderStatus,
	pub amount: u64,
	pub currency: String,
	pub server_timestamp_ms: u64,
	pub escrow_tx_id: Option<String>, // on-chain tx id or reference, if any
	pub notes: Option<String>,        // reason for rejection or info
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedOrderResponse {
	pub response: SignableOrderResponse,
	pub signature: String,          // base64(ed25519 signature over DOMAIN_TAG || BCS(response))
	pub public_key: String,         // base64(ed25519 public key), also emitted via health
	pub scheme: String,             // "ed25519"
}

// Import crypto from the same orders module
use super::crypto;

fn signing_message(resp: &SignableOrderResponse) -> Vec<u8> {
	let mut m = Vec::with_capacity(DOMAIN_TAG.len() + 256);
	m.extend_from_slice(DOMAIN_TAG);
	m.extend(
		bcs::to_bytes(resp)
			.expect("BCS serialization should not fail for canonical structs"),
	);
	m
}

pub fn make_response(req: &OrderRequest) -> SignableOrderResponse {
	let server_ts = unix_time_ms();
	info!("Processing order {} with action {:?}", req.order_id, req.action);

	// Minimal, conservative mapping for now. We’ll enrich with real escrow logic later.
	let (status, notes) = match req.action {
		OrderAction::Initiate => (OrderStatus::Pending, None),
		OrderAction::Deposit => (OrderStatus::Escrowed, None),
		OrderAction::Release => (OrderStatus::Released, None),
		OrderAction::Refund => (OrderStatus::Refunded, None),
	};

	info!("Order {} status: {:?}", req.order_id, status);

	SignableOrderResponse {
		version: req.version,
		order_id: req.order_id.clone(),
		action: req.action.clone(),
		status,
		amount: req.amount,
		currency: req.currency.clone(),
		server_timestamp_ms: server_ts,
		escrow_tx_id: None,
		notes,
	}
}

pub fn sign_response(resp: &SignableOrderResponse) -> SignedOrderResponse {
	let msg = signing_message(resp);
	info!("Signing message of {} bytes for order {}", msg.len(), resp.order_id);
	let sig = crypto::sign(&msg);
	let pk_b64 = crypto::public_key_base64();
	SignedOrderResponse {
		response: resp.clone(),
		signature: B64.encode(sig),
		public_key: pk_b64,
		scheme: "ed25519".to_string(),
	}
}

fn unix_time_ms() -> u64 {
	// Available with std; enclave has /dev/rtc/time source. Replace if monotonic-only.
	use std::time::{SystemTime, UNIX_EPOCH};
	SystemTime::now()
		.duration_since(UNIX_EPOCH)
		.map(|d| d.as_millis() as u64)
		.unwrap_or(0)
}
