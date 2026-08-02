ARG BUILD_FROM
FROM ${BUILD_FROM}

# Pinned deliberately. NordVPN's apt repo keeps several versions; floating to
# "latest" would mean an add-on rebuild could silently change the client.
ARG NORDVPN_VERSION=5.2.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# nordvpn's postinst wants a uid-1000 login user (it calls `id -un 1000` and
# then `id -u` on the result). HA base images have no such user, which makes
# postinst exit non-zero and fails the whole apt transaction. Create one first.
# It is never used to run anything -- the daemon runs as root.
RUN set -eux; \
    if ! getent passwd 1000 >/dev/null; then \
        useradd --uid 1000 --create-home --shell /usr/sbin/nologin nordvpnsetup; \
    fi; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        iptables \
        libidn2-0 \
        libnl-genl-3-200 \
        libsqlite3-0 \
        nginx-light \
        procps \
        xsltproc \
        zlib1g; \
    \
    curl -fsSL https://repo.nordvpn.com/gpg/nordvpn_public.asc \
        -o /usr/share/keyrings/nordvpn.asc; \
    echo "deb [signed-by=/usr/share/keyrings/nordvpn.asc] https://repo.nordvpn.com/deb/nordvpn/debian stable main" \
        > /etc/apt/sources.list.d/nordvpn.list; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends "nordvpn=${NORDVPN_VERSION}"; \
    \
    nordvpn --version; \
    test -f /usr/lib/nordvpn/libtelio.so; \
    \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY run.sh /
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
