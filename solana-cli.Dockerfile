FROM docker.io/solanalabs/solana:stable
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*
CMD ["/usr/bin/tail","-f","/dev/null"]
