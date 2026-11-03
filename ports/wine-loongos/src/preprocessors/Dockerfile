FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends mono-runtime && rm -rf /var/lib/apt/lists/*
ENV MONO_ENV_OPTIONS=--interpreter
WORKDIR /work
