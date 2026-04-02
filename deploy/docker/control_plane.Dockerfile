FROM rust:1.88-slim-bookworm AS builder
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
COPY crates/shared/Cargo.toml crates/shared/Cargo.toml
COPY crates/control_plane/Cargo.toml crates/control_plane/Cargo.toml
COPY crates/sensor_agent/Cargo.toml crates/sensor_agent/Cargo.toml

RUN mkdir -p crates/shared/src crates/control_plane/src crates/sensor_agent/src \
 && touch crates/shared/src/lib.rs \
 && touch crates/control_plane/src/main.rs \
 && touch crates/sensor_agent/src/main.rs

RUN cargo fetch --locked

COPY crates crates
COPY deploy/sql deploy/sql

RUN cargo build -p control_plane --release --locked

FROM debian:bookworm-slim AS runtime
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid 10001 --create-home --home-dir /home/app app

COPY --from=builder /app/target/release/control_plane /usr/local/bin/control_plane
COPY --from=builder /app/target/release/hash_password /usr/local/bin/hash_password
COPY --from=builder /app/deploy/sql /app/deploy/sql

RUN chown -R app:app /app /home/app \
 && chown app:app /usr/local/bin/control_plane /usr/local/bin/hash_password

EXPOSE 8080

ENV RUST_LOG=info
ENV BIND_ADDR=0.0.0.0:8080
ENV MIGRATIONS_DIR=/app/deploy/sql

USER app:app

CMD ["/usr/local/bin/control_plane"]