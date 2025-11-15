# Multi-stage build for minimal production image
FROM rust:1.87-bullseye AS builder

WORKDIR /app

# Install dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy workspace configuration
COPY Cargo.toml ./

# Copy only nautilus-server (not the broken workspace members)
COPY src/nautilus-server ./src/nautilus-server

# Build the binary
# The workspace puts the binary in target/release/, not in src/nautilus-server/target/release/
RUN cargo build --release --features=orders --manifest-path=src/nautilus-server/Cargo.toml

# Runtime stage - minimal image
FROM debian:bullseye-slim

WORKDIR /app

# Install runtime dependencies INCLUDING curl for health checks
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl1.1 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy binary from builder - CORRECT PATH for workspace build
COPY --from=builder /app/target/release/nautilus-server /app/nautilus-server

# Railway provides PORT env var, default to 3100
ENV PORT=3100
ENV RUST_LOG=info

EXPOSE 3100

# Health check (curl is now available)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health_check || exit 1

# Run the server
CMD ["/app/nautilus-server"]