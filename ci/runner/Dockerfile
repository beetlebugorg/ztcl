# The image of the CI jobs on our own runners (docs/dev/ci.md).
#
# Each job runs in a new container of this image, as the user ci, with
# no privileges and the uid of the runner (1000). The Zig cache is a volume at /zig-cache.
FROM ubuntu:24.04@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b

ARG ZIG_VERSION=0.17.0
ARG ZIG_SHA256_X86_64=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ARG ZIG_SHA256_AARCH64=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
ARG NODE_VERSION=22.23.5
ARG NODE_SHA256_X64=cdeb8670a0c81f51b4dc4ac61919f9b1ad917b304bf8221eb939570663d240f8
ARG NODE_SHA256_ARM64=2babb9eb5264860d540849f4b064a6fbdebcdc323657d9d382ce23d313fd5e09
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      ca-certificates curl git xz-utils file python3 python3-venv python3-pip \
      tcl8.6 tcl8.6-dev qemu-user openssl jq zstd \
 && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
      amd64) a=x86_64; h=$ZIG_SHA256_X86_64 ;; \
      arm64) a=aarch64; h=$ZIG_SHA256_AARCH64 ;; \
      *) echo "no Zig for $TARGETARCH"; exit 1 ;; \
    esac \
 && n=zig-$a-linux-$ZIG_VERSION \
 && curl -sSfL -o /tmp/zig.tar.xz "https://ziglang.org/download/$ZIG_VERSION/$n.tar.xz" \
 && echo "$h  /tmp/zig.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/zig.tar.xz -C /opt \
 && mv /opt/$n /opt/zig \
 && rm /tmp/zig.tar.xz

RUN case "$TARGETARCH" in \
      amd64) a=x64; h=$NODE_SHA256_X64 ;; \
      arm64) a=arm64; h=$NODE_SHA256_ARM64 ;; \
      *) echo "no Node.js for $TARGETARCH"; exit 1 ;; \
    esac \
 && n=node-v$NODE_VERSION-linux-$a \
 && curl -sSfL -o /tmp/node.tar.xz "https://nodejs.org/dist/v$NODE_VERSION/$n.tar.xz" \
 && echo "$h  /tmp/node.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/node.tar.xz -C /opt \
 && mv /opt/$n /opt/node \
 && rm /tmp/node.tar.xz

# The runner on the host runs as uid 1000, and the workspace of the job
# is its directory. The user ci has the same uid, so that both can write
# the workspace. The image of Ubuntu has the user ubuntu at uid 1000.
# The user ci is in no other group, so it has no access to the socket
# of Docker that the runner mounts (docs/dev/ci.md).
RUN usermod -l ci -d /home/ci -m ubuntu && groupmod -n ci ubuntu && usermod -G '' ci \
 && mkdir /zig-cache && chown ci:ci /zig-cache
ENV PATH=/opt/zig:/opt/node/bin:$PATH \
    ZIG_GLOBAL_CACHE_DIR=/zig-cache/global \
    ZIG_LOCAL_CACHE_DIR=/zig-cache/local
USER ci
WORKDIR /home/ci
