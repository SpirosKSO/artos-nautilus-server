// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use anyhow::Result;
use axum::{routing::{get, post}, Json, Router};
use fastcrypto::{ed25519::Ed25519KeyPair, traits::KeyPair};
use nautilus_server::common::{get_attestation, health_check};
use nautilus_server::AppState;
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};
use tracing::info;

#[cfg(not(feature = "orders"))]
use nautilus_server::app::process_data;

#[cfg(feature = "orders")]
use nautilus_server::orders;

#[tokio::main]
async fn main() -> Result<()> {
    // ✅ Production-ready structured logging
    #[cfg(debug_assertions)]
    {
        // Development: human-readable logs
        tracing_subscriber::fmt()
            .with_target(false)
            .compact()
            .init();
    }
    
    #[cfg(not(debug_assertions))]
    {
        // Production: JSON logs for Railway/monitoring tools
        use tracing_subscriber::fmt::format::FmtSpan;
        tracing_subscriber::fmt()
            .with_span_events(FmtSpan::CLOSE)
            .json()
            .init();
    }

    info!("🚀 Starting Nautilus Server...");

    let eph_kp = Ed25519KeyPair::generate(&mut rand::thread_rng());

    // In orders mode, don't require API_KEY at runtime.
    #[cfg(feature = "orders")]
    let api_key = String::new();
    
    // Otherwise require API_KEY to be set.
    #[cfg(not(feature = "orders"))]
    let api_key = std::env::var("API_KEY").expect("API_KEY must be set");

    let state = Arc::new(AppState { eph_kp, api_key });

    // Initialize signing key early. In production, replace with KMS-sealed key init.
    #[cfg(feature = "orders")]
    {
        info!("🔐 Initializing enclave signing key...");
        orders::crypto::ensure_initialized().expect("failed to initialize enclave signing key");
        info!("✅ Enclave signing key initialized successfully");
        info!(public_key = %orders::crypto::public_key_base64(), "Ed25519 public key");
    }

    // Define your own restricted CORS policy here if needed.
    let cors = CorsLayer::new()
        .allow_methods(Any)
        .allow_headers(Any)
        .allow_origin(Any);

    #[cfg(not(feature = "orders"))]
    let app = Router::new()
        .route("/", get(ping))
        .route("/get_attestation", get(get_attestation))
        .route("/process_data", post(process_data))
        .route("/health_check", get(health_check))
        .with_state(state)
        .layer(cors);

    #[cfg(feature = "orders")]
    let app = Router::new()
        .route("/", get(ping))
        .route("/get_attestation", get(get_attestation))
        .route("/health_check", get(health_check))
        .route("/orders/process", post(process_order_http))  
        .route("/orders/health", get(orders_health))
        .with_state(state)
        .layer(cors);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3100").await?;  
    info!(addr = %listener.local_addr().unwrap(), "Server listening");
    info!("📋 Routes registered:");
    info!("  GET  /");
    info!("  GET  /get_attestation");
    info!("  GET  /health_check");
    info!("  POST /orders/process");
    info!("  GET  /orders/health");
    info!("🎯 Server ready to accept requests!");
    
    axum::serve(listener, app.into_make_service())
        .await
        .map_err(|e| anyhow::anyhow!("Server error: {}", e))
}

async fn ping() -> &'static str {
    info!("📍 Ping endpoint called");
    "Pong!"
}

// HTTP handlers for orders feature
#[cfg(feature = "orders")]
async fn process_order_http(Json(req): Json<orders::OrderRequest>) -> Json<orders::SignedOrderResponse> {
    info!(
        order_id = %req.order_id,
        action = ?req.action,
        amount = req.amount,
        currency = %req.currency,
        "Processing order request"
    );
    let resp = orders::make_response(&req);
    info!(order_id = %resp.order_id, status = ?resp.status, "Generated response");
    let signed = orders::sign_response(&resp);
    info!(order_id = %signed.response.order_id, public_key = %signed.public_key, "Signed response");
    Json(signed)
}

#[cfg(feature = "orders")]
async fn orders_health() -> Json<serde_json::Value> {
    let pk_b64 = orders::crypto::public_key_base64();
    info!(public_key = %pk_b64, "Health check");
    Json(serde_json::json!({
        "status": "ok",
        "ed25519_pubkey_b64": pk_b64
    }))
}