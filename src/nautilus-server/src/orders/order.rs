use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tracing::info;

// ============================================
// ✅ INTENT SCOPES (must match Move contract)
// ============================================
const ORDER_INTENT_INITIATE: u8 = 0;
const ORDER_INTENT_DEPOSIT: u8 = 1;
const ORDER_INTENT_RELEASE: u8 = 2;
const ORDER_INTENT_REFUND: u8 = 3;

// ============================================
// ✅ ACTION/STATUS CONSTANTS (for BCS serialization)
// Must match Move contract for proper signature verification
// ============================================
const ACTION_INITIATE: u8 = 0;
const ACTION_DEPOSIT: u8 = 1;
const ACTION_RELEASE: u8 = 2;
const ACTION_REFUND: u8 = 3;

const STATUS_PENDING: u8 = 0;
const STATUS_ESCROWED: u8 = 1;
const STATUS_RELEASED: u8 = 2;
const STATUS_REFUNDED: u8 = 3;
const STATUS_REJECTED: u8 = 4;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderAction {
	Initiate,
	Deposit,
	Release,
	Refund,
}

impl OrderAction {
	fn to_u8(&self) -> u8 {
		match self {
			OrderAction::Initiate => ACTION_INITIATE,
			OrderAction::Deposit => ACTION_DEPOSIT,
			OrderAction::Release => ACTION_RELEASE,
			OrderAction::Refund => ACTION_REFUND,
		}
	}
	
	fn to_intent(&self) -> u8 {
		match self {
			OrderAction::Initiate => ORDER_INTENT_INITIATE,
			OrderAction::Deposit => ORDER_INTENT_DEPOSIT,
			OrderAction::Release => ORDER_INTENT_RELEASE,
			OrderAction::Refund => ORDER_INTENT_REFUND,
		}
	}
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

impl OrderStatus {
	fn to_u8(&self) -> u8 {
		match self {
			OrderStatus::Pending => STATUS_PENDING,
			OrderStatus::Escrowed => STATUS_ESCROWED,
			OrderStatus::Released => STATUS_RELEASED,
			OrderStatus::Refunded => STATUS_REFUNDED,
			OrderStatus::Rejected => STATUS_REJECTED,
		}
	}
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

/// BCS-serializable struct that matches the Move SignableOrderResponse exactly
/// This is what gets wrapped in IntentMessage for signing
#[derive(Debug, Clone, Serialize, Deserialize)]
struct BcsSignableOrderResponse {
	version: u8,
	order_id: Vec<u8>,
	action: u8,
	status: u8,
	amount: u64,
	currency: Vec<u8>,
	server_timestamp_ms: u64,
	escrow_tx_id: Option<Vec<u8>>,
	notes: Option<Vec<u8>>,
}

impl From<&SignableOrderResponse> for BcsSignableOrderResponse {
	fn from(resp: &SignableOrderResponse) -> Self {
		BcsSignableOrderResponse {
			version: resp.version,
			order_id: resp.order_id.as_bytes().to_vec(),
			action: resp.action.to_u8(),
			status: resp.status.to_u8(),
			amount: resp.amount,
			currency: resp.currency.as_bytes().to_vec(),
			server_timestamp_ms: resp.server_timestamp_ms,
			escrow_tx_id: resp.escrow_tx_id.as_ref().map(|s| s.as_bytes().to_vec()),
			notes: resp.notes.as_ref().map(|s| s.as_bytes().to_vec()),
		}
	}
}

/// IntentMessage wrapper - matches Move's IntentMessage<P> struct exactly
/// BCS serialization: intent (u8) + timestamp_ms (u64) + payload (BcsSignableOrderResponse)
#[derive(Debug, Clone, Serialize, Deserialize)]
struct IntentMessage {
	intent: u8,
	timestamp_ms: u64,
	payload: BcsSignableOrderResponse,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedOrderResponse {
	pub response: SignableOrderResponse,
	pub signature: String,          // base64(ed25519 signature over BCS(IntentMessage))
	pub public_key: String,         // base64(ed25519 public key), also emitted via health
	pub scheme: String,             // "ed25519"
}

// Import crypto from the same orders module
use super::crypto;

/// Creates the signing message that matches Move's verify_signature expectation
/// Format: BCS(IntentMessage { intent, timestamp_ms, payload })
fn signing_message(resp: &SignableOrderResponse) -> Vec<u8> {
	let bcs_payload = BcsSignableOrderResponse::from(resp);
	let intent_msg = IntentMessage {
		intent: resp.action.to_intent(),
		timestamp_ms: resp.server_timestamp_ms,
		payload: bcs_payload,
	};
	bcs::to_bytes(&intent_msg)
		.expect("BCS serialization should not fail for canonical structs")
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
