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

// V2 intent scopes — disjoint from V1 so a V1 signature can NEVER be
// replayed as V2 even at the byte level. Used by the hardened signing
// path that includes escrow_id / recipient / nonce / expiry_ms.
const ORDER_INTENT_V2_INITIATE: u8 = 0x10;
const ORDER_INTENT_V2_DEPOSIT: u8 = 0x11;
const ORDER_INTENT_V2_RELEASE: u8 = 0x12;
const ORDER_INTENT_V2_REFUND: u8 = 0x13;

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

    /// V2 intent scope — used by the hardened signing path. Disjoint from
    /// `to_intent()` (V1) so cross-version replay is impossible at the
    /// first signed byte.
    fn to_intent_v2(&self) -> u8 {
        match self {
            OrderAction::Initiate => ORDER_INTENT_V2_INITIATE,
            OrderAction::Deposit => ORDER_INTENT_V2_DEPOSIT,
            OrderAction::Release => ORDER_INTENT_V2_RELEASE,
            OrderAction::Refund => ORDER_INTENT_V2_REFUND,
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
    pub version: u8, // protocol version, start with 1
    pub order_id: String,
    pub customer: String,
    pub merchant: String,
    pub amount: u64,         // minor units (e.g., cents)
    pub currency: String,    // e.g., "USD"
    pub action: OrderAction, // desired action
    pub client_timestamp_ms: Option<u64>,
    pub metadata: Option<serde_json::Value>,
    /// Optional V2 hardening fields. When present, the enclave additionally
    /// produces a V2 signature alongside V1 (shadow mode).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub v2: Option<OrderV2Fields>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignableOrderResponse {
    pub version: u8, // protocol version
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
    pub signature: String,  // base64(ed25519 signature over BCS(IntentMessage))
    pub public_key: String, // base64(ed25519 public key), also emitted via health
    pub scheme: String,     // "ed25519"
    /// Base64 ed25519 signature over BCS(IntentMessageV2). Present only
    /// when the request supplied `v2` fields. Same enclave master key as V1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signature_v2: Option<String>,
    /// Echo of the V2 inputs (escrow_id / recipient / nonce / expiry_ms) so
    /// the backend can store them alongside the signature for later replay
    /// of the verification check.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub v2: Option<OrderV2Fields>,
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
    bcs::to_bytes(&intent_msg).expect("BCS serialization should not fail for canonical structs")
}

pub fn make_response(req: &OrderRequest) -> SignableOrderResponse {
    let server_ts = unix_time_ms();
    info!(
        "Processing order {} with action {:?}",
        req.order_id, req.action
    );

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
    info!(
        "Signing message of {} bytes for order {}",
        msg.len(),
        resp.order_id
    );
    let sig = crypto::sign(&msg);
    let pk_b64 = crypto::public_key_base64();
    SignedOrderResponse {
        response: resp.clone(),
        signature: B64.encode(sig),
        public_key: pk_b64,
        scheme: "ed25519".to_string(),
        signature_v2: None,
        v2: None,
    }
}

/// Sign V1 and (when V2 inputs are supplied) V2 in a single pass. Used by
/// the HTTP handler so a request that opts into V2 receives both signatures
/// in one response — the backend can then verify both independently.
pub fn sign_response_with_v2(
    resp: &SignableOrderResponse,
    v2: Option<&OrderV2Fields>,
) -> SignedOrderResponse {
    let mut signed = sign_response(resp);
    if let Some(v2_fields) = v2 {
        match sign_v2(resp, v2_fields) {
            Ok(sig_v2) => {
                signed.signature_v2 = Some(sig_v2);
                signed.v2 = Some(v2_fields.clone());
            }
            Err(e) => {
                // V2 is shadow mode — log and continue. V1 still ships, the
                // backend records `verified_v2 = false` and we investigate.
                tracing::error!(error = %e, order_id = %resp.order_id,
					"V2 signing failed; returning V1-only response");
            }
        }
    }
    signed
}

// ============================================================
// V2 — hardened signing protocol (shadow mode)
// ============================================================
//
// V2 ADDS four fields to the signed payload:
//   - escrow_id   ([u8; 32]; Sui ObjectID of the OrderEscrow<T>)
//   - recipient   ([u8; 32]; Sui address that funds release/refund to)
//   - nonce       ([u8; 16]; random per-signature, replay protection)
//   - expiry_ms   (u64; signature is invalid past this wall-clock time)
//
// Wire format MUST stay byte-identical with the TS verifier:
//   artos-backend/src/nautilus/order-bcs.ts (buildOrderSigningMessageV2)
//
// V2 uses a disjoint intent byte range (0x10..0x13) so a V1 signature can
// NEVER be replayed as V2. Phase 3 `assert_is_authorized` Move check will
// read these four fields from the signed message — they exist BECAUSE
// on-chain verification needs them.

/// V2 inputs the backend supplies alongside V1. When all four are present
/// the enclave additionally produces a V2 signature.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderV2Fields {
    /// Sui ObjectID of the OrderEscrow<T> as 64-char hex (with or without
    /// `0x` prefix) OR a 32-byte raw array (after JSON normalization).
    pub escrow_id: String,
    /// Sui address funds release/refund to (32-byte hex).
    pub recipient: String,
    /// 16-byte nonce as 32-char hex (with or without `0x` prefix).
    pub nonce: String,
    /// Hard wall-clock deadline after which the signature is invalid.
    pub expiry_ms: u64,
}

/// BCS-serializable V2 payload. Field order MUST match `SignableOrderResponseV2`
/// in `order-bcs.ts` byte-for-byte.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct BcsSignableOrderResponseV2 {
    // V1-shaped fields (kept identical layout & names)
    version: u8,
    order_id: Vec<u8>,
    action: u8,
    status: u8,
    amount: u64,
    currency: Vec<u8>,
    server_timestamp_ms: u64,
    escrow_tx_id: Option<Vec<u8>>,
    notes: Option<Vec<u8>>,
    // V2 hardening fields — fixed-size arrays serialize as raw N bytes
    // (no length prefix), matching `bcs.fixedArray(N, bcs.u8())` on the TS
    // side. Using Vec<u8> here would emit a ULEB128 prefix and break parity.
    escrow_id: [u8; 32],
    recipient: [u8; 32],
    nonce: [u8; 16],
    expiry_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct IntentMessageV2 {
    intent: u8,
    timestamp_ms: u64,
    payload: BcsSignableOrderResponseV2,
}

/// Decode a hex string (with or without `0x` prefix) into a fixed-size
/// byte array. Returns `Err` on malformed input — silent zero-padding
/// would defeat the entire `recipient` / `escrow_id` invariant.
fn parse_hex_bytes<const N: usize>(s: &str) -> Result<[u8; N], String> {
    let trimmed = s.strip_prefix("0x").unwrap_or(s);
    if trimmed.len() != N * 2 {
        return Err(format!(
            "expected {}-byte hex ({} chars), got {}",
            N,
            N * 2,
            trimmed.len()
        ));
    }
    let mut out = [0u8; N];
    for i in 0..N {
        out[i] = u8::from_str_radix(&trimmed[i * 2..i * 2 + 2], 16)
            .map_err(|e| format!("non-hex character: {}", e))?;
    }
    Ok(out)
}

/// Build the canonical V2 signing bytes:
/// `BCS(IntentMessageV2 { intent_v2, server_timestamp_ms, payload_v2 })`.
fn signing_message_v2(resp: &SignableOrderResponse, v2: &OrderV2Fields) -> Result<Vec<u8>, String> {
    let escrow_id =
        parse_hex_bytes::<32>(&v2.escrow_id).map_err(|e| format!("escrow_id: {}", e))?;
    let recipient =
        parse_hex_bytes::<32>(&v2.recipient).map_err(|e| format!("recipient: {}", e))?;
    let nonce = parse_hex_bytes::<16>(&v2.nonce).map_err(|e| format!("nonce: {}", e))?;

    let payload = BcsSignableOrderResponseV2 {
        version: resp.version,
        order_id: resp.order_id.as_bytes().to_vec(),
        action: resp.action.to_u8(),
        status: resp.status.to_u8(),
        amount: resp.amount,
        currency: resp.currency.as_bytes().to_vec(),
        server_timestamp_ms: resp.server_timestamp_ms,
        escrow_tx_id: resp.escrow_tx_id.as_ref().map(|s| s.as_bytes().to_vec()),
        notes: resp.notes.as_ref().map(|s| s.as_bytes().to_vec()),
        escrow_id,
        recipient,
        nonce,
        expiry_ms: v2.expiry_ms,
    };

    let intent_msg = IntentMessageV2 {
        intent: resp.action.to_intent_v2(),
        timestamp_ms: resp.server_timestamp_ms,
        payload,
    };

    bcs::to_bytes(&intent_msg).map_err(|e| format!("BCS serialization failed: {}", e))
}

/// Sign a V2 message. Returned base64 signature is over the canonical V2
/// bytes; backend verifies via the same enclave master public key as V1.
pub fn sign_v2(resp: &SignableOrderResponse, v2: &OrderV2Fields) -> Result<String, String> {
    let msg = signing_message_v2(resp, v2)?;
    info!(
        "Signing V2 message of {} bytes for order {}",
        msg.len(),
        resp.order_id
    );
    let sig = crypto::sign(&msg);
    Ok(B64.encode(sig))
}

fn unix_time_ms() -> u64 {
    // Available with std; enclave has /dev/rtc/time source. Replace if monotonic-only.
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
