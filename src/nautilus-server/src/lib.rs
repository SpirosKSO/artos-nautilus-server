// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::Json;
use fastcrypto::ed25519::Ed25519KeyPair;
use serde_json::json;
use std::fmt;

// Only include orders module (directly in src/, not in apps/)
#[cfg(feature = "orders")]
pub mod orders {
    pub mod crypto;
    pub mod order;
    
    pub use order::{
        OrderAction, OrderRequest, OrderStatus, 
        SignableOrderResponse, SignedOrderResponse,
        make_response, sign_response,
    };
    pub use crypto::{ensure_initialized, public_key_base64, sign};
}

pub mod common;

/// App state, at minimum needs to maintain the ephemeral keypair.  
pub struct AppState {
    /// Ephemeral keypair on boot
    pub eph_kp: Ed25519KeyPair,
    /// API key (not used in orders mode, but kept for compatibility)
    pub api_key: String,
}

/// Implement IntoResponse for EnclaveError.
impl IntoResponse for EnclaveError {
    fn into_response(self) -> Response {
        let (status, error_message) = match self {
            EnclaveError::GenericError(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
        };
        
        let body = Json(json!({
            "error": error_message,
        }));
        
        (status, body).into_response()
    }
}

/// Enclave errors enum.
#[derive(Debug)]
pub enum EnclaveError {
    GenericError(String),
}

impl fmt::Display for EnclaveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EnclaveError::GenericError(msg) => write!(f, "Enclave error: {}", msg),
        }
    }
}

impl std::error::Error for EnclaveError {}