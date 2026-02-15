FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates curl bc qrencode zbar-tools \
    libv4l-0 v4l-utils \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

# Default: keep container alive (idle) and use docker exec for scripts
CMD ["sleep", "infinity"]
