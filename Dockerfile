# syntax=docker/dockerfile:1
#
# The Open Memex vault server (`memex serve`) as a container image, published
# as ghcr.io/connordodge/memex by .github/workflows/docker.yml (Spec #189).
# Build context: the repo root, cut down by .dockerignore to Cargo.toml,
# Cargo.lock and crates/.

# Builder: the Rust version release.yml builds the macOS release with.
FROM rust:1.95.0-bookworm AS builder
# openssl-sys (hf-hub -> ureq -> native-tls) links the system OpenSSL.
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN cargo build --release --locked -p memex-mcp

# Runtime: the binary, CA certificates, time zone data and the shared
# libraries it links. No compiler, curl or Rust toolchain.
FROM debian:bookworm-slim
ARG VERSION=0.0.0
LABEL org.opencontainers.image.source="https://github.com/connordodge/open_memex" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.title="memex" \
      org.opencontainers.image.description="Open Memex vault server (memex serve)" \
      org.opencontainers.image.version="${VERSION}"
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 memex \
 && useradd --uid 1000 --gid 1000 --no-create-home --shell /usr/sbin/nologin memex \
 && mkdir /vaults \
 && chown 1000:1000 /vaults
COPY --from=builder /build/target/release/memex /usr/local/bin/memex
USER 1000:1000
EXPOSE 7878
CMD ["memex", "serve", "--root", "/vaults", "--listen", "0.0.0.0:7878"]
