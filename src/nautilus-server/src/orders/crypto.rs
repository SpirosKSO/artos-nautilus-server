use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use once_cell::sync::OnceCell;
use tracing::info;

static SIGNING_KEY: OnceCell<SigningKey> = OnceCell::new();

pub fn ensure_initialized() -> Result<(), &'static str> {
    SIGNING_KEY.get_or_try_init(|| {
        info!("🔧 Generating new signing key...");
        let mut seed = [0u8; 32];
        getrandom::getrandom(&mut seed).map_err(|_| "rng_unavailable")?;
        let sk = SigningKey::from_bytes(&seed);
        info!("✅ Signing key generated successfully");
        Ok::<SigningKey, &'static str>(sk)
    })?;
    Ok(())
}

pub fn public_key_base64() -> String {
    let sk = SIGNING_KEY.get().expect("crypto::ensure_initialized must be called first");
    let vk = sk.verifying_key();
    B64.encode(vk.to_bytes())
}

pub fn sign(message: &[u8]) -> [u8; 64] {
    let sk = SIGNING_KEY.get().expect("crypto::ensure_initialized must be called first");
    let sig = sk.sign(message);
    info!("🔏 Signed {} byte message", message.len());
    sig.to_bytes()
}
