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

# Copy only nautilus-server
COPY src/nautilus-server ./src/nautilus-server

# Build the binary
RUN cargo build --release --features=orders --manifest-path=src/nautilus-server/Cargo.toml

# Runtime stage - minimal image
FROM debian:bullseye-slim

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl1.1 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy binary from builder
COPY --from=builder /app/target/release/nautilus-server /app/nautilus-server

# Railway provides PORT dynamically - don't set it here
ENV RUST_LOG=info

# Don't EXPOSE or set PORT - Railway handles this

# Run the server (reads PORT from Railway environment)
CMD ["/app/nautilus-server"]