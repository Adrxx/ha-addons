#!/usr/bin/env bashio
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# NordVPN Meshnet add-on for Home Assistant OS
#
# Runs nordvpnd directly (no systemd) and brings up Meshnet only. It never
# calls `nordvpn connect`, so Home Assistant's own traffic keeps going out over
# the LAN as normal. That matters: routing HA through a VPN server would break
# local discovery of Govee/LIFX/Matter devices.
#
# Command ordering below is not arbitrary -- it was derived by running the
# 5.2.0 CLI. Two constraints in particular:
#   * `set killswitch off` fails once the firewall is disabled
#     ("Firewall must be enabled to use 'Kill Switch'"), so it must come first.
#   * `set autoconnect off` fails before login ("You're not logged in"),
#     so it must come after.
# ---------------------------------------------------------------------------
set -o errexit -o nounset -o pipefail

readonly SOCKET="/run/nordvpn/nordvpnd.sock"
readonly STATE_DIR="/data/nordvpn"
declare DAEMON_PID=0

# The nordvpn CLI aborts with "[Fatal] cannot get user home dir" when HOME is
# unset, which is exactly the case under s6-overlay's service environment.
# A plain `docker run` sets HOME, so this only shows up once the add-on runs
# for real -- as a daemon that never becomes ready.
export HOME="${HOME:-/root}"
[[ -d "${HOME}" ]] || mkdir -p "${HOME}"

# --- options ---------------------------------------------------------------
# Read /data/options.json directly rather than via bashio::config, which
# proxies through the Supervisor API. This keeps the add-on free of a runtime
# Supervisor dependency and lets it be exercised in a plain container.
#
# Note the explicit has()/!= null form: jq's `//` operator treats `false` as
# empty, so `.key // $default` would silently turn every `false` option into
# its default.
readonly OPTIONS_FILE="/data/options.json"

opt() {
    local key="${1}" default="${2:-}"
    if [[ ! -f "${OPTIONS_FILE}" ]]; then
        printf '%s' "${default}"
        return 0
    fi
    jq --raw-output --arg d "${default}" \
        "if has(\"${key}\") and .${key} != null then .${key} else \$d end" \
        "${OPTIONS_FILE}" 2>/dev/null || printf '%s' "${default}"
}

opt_bool() {
    [[ "$(opt "${1}" "${2:-false}")" == "true" ]]
}

LOG_LEVEL="$(opt log_level info)"
readonly LOG_LEVEL
bashio::log.level "${LOG_LEVEL}"

# nordvpnd is extremely chatty -- it logs the full libtelio feature struct on
# every start. Pass it through unfiltered only when the user actually asked for
# debug, otherwise keep warnings and errors and drop the rest.
daemon_log() {
    if [[ "${LOG_LEVEL}" == "debug" || "${LOG_LEVEL}" == "trace" ]]; then
        cat
        return 0
    fi
    # Dropped below: routine chatter, the daemon's full HTTP request/response
    # dumps, and a handful of warnings that are unavoidable artefacts of running
    # in a container (no dbus, no systemd, no /etc/machine-id, no sysctl write
    # access). They are benign and would otherwise bury real errors.
    grep -vE \
        -e '\[Info\]|\[Debug\]|TELIO\(' \
        -e '^(Request|Response|Error): ' \
        -e 'failed to set buffer size for HTTP/3' \
        -e 'machine_id\.go|host_name_dbus_src\.go|norduser monitor' \
        -e '\[moose\] Discarding unsupported type' \
        -e 'executable file not found in .PATH' \
        || true
}

# --- helpers ---------------------------------------------------------------

# Run a nordvpn CLI command, logging failures rather than aborting. Several of
# these are idempotent and report "already set to ...", which is not an error.
nord() {
    local output
    if output=$(nordvpn "$@" 2>&1); then
        bashio::log.debug "nordvpn $*: $(echo "${output}" | tr '\n' ' ')"
        return 0
    fi
    bashio::log.warning "nordvpn $* failed: $(echo "${output}" | tr '\n' ' ')"
    return 1
}

cleanup() {
    trap - TERM INT EXIT
    if [[ "${DAEMON_PID}" -ne 0 ]] && kill -0 "${DAEMON_PID}" 2>/dev/null; then
        bashio::log.info "Stopping nordvpnd (pid ${DAEMON_PID})..."
        kill -TERM "${DAEMON_PID}" 2>/dev/null || true
        wait "${DAEMON_PID}" 2>/dev/null || true
    fi
}
trap cleanup TERM INT EXIT

# List this device's Meshnet peers by Nord hostname. Nord hostnames look like
# <username>-<mountain>.nord and the username half may itself contain a dot
# (e.g. secret.raccoon-andes.nord), so dots must be part of the match.
peer_hostnames() {
    nordvpn meshnet peer list 2>/dev/null \
        | grep -oE '[A-Za-z0-9][A-Za-z0-9._-]*\.nord' \
        | sort -u
}

# --- configuration ---------------------------------------------------------

TOKEN=$(opt token)
NICKNAME=$(opt nickname homeassistant)
CHECK_INTERVAL=$(opt check_interval 300)

if bashio::var.is_empty "${TOKEN}"; then
    bashio::exit.nok \
        "No NordVPN token set. Generate one at https://my.nordaccount.com -> \
NordVPN -> Manual setup -> Generate new token, then paste it into this \
add-on's Configuration tab."
fi

# --- persistent state ------------------------------------------------------
# /var/lib/nordvpn holds the login session, the Meshnet identity and settings.
# The add-on container is recreated on every update, so keep it on /data.
# Seed from the image on first run so the bundled server data survives.
if [[ ! -d "${STATE_DIR}" ]]; then
    bashio::log.info "First run: seeding persistent state in ${STATE_DIR}"
    cp -a /var/lib/nordvpn "${STATE_DIR}"
fi
rm -rf /var/lib/nordvpn
ln -sfn "${STATE_DIR}" /var/lib/nordvpn

install -d -m 0750 /run/nordvpn

# --- start the daemon ------------------------------------------------------

bashio::log.info "Starting nordvpnd..."
# Process substitution rather than a pipe, so $! is nordvpnd itself.
/usr/sbin/nordvpnd > >(daemon_log) 2>&1 &
DAEMON_PID=$!

bashio::log.info "Waiting for the daemon to accept commands..."
for _ in $(seq 1 60); do
    if [[ -S "${SOCKET}" ]] && nordvpn status >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${DAEMON_PID}" 2>/dev/null; then
        bashio::exit.nok "nordvpnd exited during startup. See the log above."
    fi
    sleep 1
done

if ! nordvpn status >/dev/null 2>&1; then
    bashio::exit.nok "nordvpnd did not become ready within 60s."
fi
bashio::log.info "Daemon is up."

# --- safety rails (pre-login) ----------------------------------------------
# This add-on is Meshnet-only by design. These settings keep the daemon from
# ever taking over the host's routing or firewall.

# Also resolves the first-run "User Consent: undefined" state, which otherwise
# leaves the client waiting on an interactive prompt nobody can answer.
nord set analytics off || true

# Must precede `firewall off` -- see the header note.
nord set killswitch off || true

if opt_bool nordvpn_firewall; then
    bashio::log.warning \
        "NordVPN's firewall is ENABLED. Because this add-on runs in the host \
network namespace, it writes iptables rules that Home Assistant OS also manages."
    nord set firewall on || true
else
    # Default. Keeps NordVPN out of the host's netfilter tables entirely.
    nord set firewall off || true
fi

# ARP Ignore defaults to on and is a host-wide behaviour change. It exists to
# avoid exposing a VPN interface via ARP; we never bring a VPN up, so turn it
# off rather than alter how the Pi answers ARP on the LAN.
nord set arp-ignore off || true

# Meshnet requires NordLynx, and post-quantum encryption is explicitly
# incompatible with Meshnet -- if it is ever on, Meshnet will not come up.
nord set technology nordlynx || true
nord set post-quantum off || true

# --- authenticate ----------------------------------------------------------

if nordvpn account >/dev/null 2>&1; then
    bashio::log.info "Already logged in; reusing the stored session."
else
    bashio::log.info "Logging in with the configured access token..."
    # Bounded: an invalid token makes the client retry for minutes before
    # giving up, which looks like a hang rather than a bad credential.
    if ! timeout 90 nordvpn login --token "${TOKEN}" >/dev/null 2>&1; then
        bashio::exit.nok \
            "Login failed or timed out. Check that this is a NordVPN *access \
token* (not your account password) and that it has not been revoked."
    fi
    bashio::log.info "Login succeeded."
fi

# Only settable once logged in -- see the header note.
nord set autoconnect off || true

# --- meshnet ---------------------------------------------------------------

bashio::log.info "Enabling Meshnet..."
if ! nord set meshnet on; then
    bashio::exit.nok "Could not enable Meshnet."
fi

if ! bashio::var.is_empty "${NICKNAME}"; then
    # A nickname already taken by another device is rejected; not fatal, the
    # device simply keeps its generated <name>.nord hostname.
    nord meshnet set nickname "${NICKNAME}" || true
fi

# Meshnet permissions. Remote access is granted by default, but set it
# explicitly so the add-on's behaviour does not depend on account-side state.
if opt_bool allow_incoming; then
    bashio::log.info "Granting your own devices remote access to this node..."
else
    bashio::log.warning \
        "allow_incoming is false -- peers will see this node but cannot open \
port 8123 on it."
fi

while read -r peer; do
    [[ -z "${peer}" ]] && continue

    if opt_bool allow_incoming; then
        nord meshnet peer incoming allow "${peer}" || true
    else
        nord meshnet peer incoming deny "${peer}" || true
    fi

    # Local network access only functions in tandem with traffic routing, so
    # granting one without the other would do nothing.
    if opt_bool allow_lan_access; then
        nord meshnet peer routing allow "${peer}" || true
        nord meshnet peer local allow "${peer}" || true
    fi

    if opt_bool allow_fileshare; then
        nord meshnet peer fileshare allow "${peer}" || true
    else
        nord meshnet peer fileshare deny "${peer}" || true
    fi
done < <(peer_hostnames)

if opt_bool allow_lan_access; then
    bashio::log.warning \
        "allow_lan_access is ON: peers routing through this node can reach \
every device on your LAN, including the routers."
fi

# --- report ----------------------------------------------------------------

MESH_IP=$(ip -4 -brief addr show dev nordlynx 2>/dev/null \
    | awk '{print $3}' | cut -d/ -f1 || true)

bashio::log.info "-------------------------------------------------------"
if [[ -n "${MESH_IP}" ]]; then
    bashio::log.info "Meshnet is up. Reach Home Assistant from any peer at:"
    bashio::log.info "    http://${MESH_IP}:8123"
else
    bashio::log.info "Meshnet is up."
fi
if [[ -n "${NICKNAME}" ]]; then
    bashio::log.info "    http://${NICKNAME}.nord:8123"
fi
bashio::log.info "-------------------------------------------------------"

bashio::log.info "Meshnet peers:"
nordvpn meshnet peer list 2>&1 | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    bashio::log.info "  ${line}"
done

# --- supervise -------------------------------------------------------------
# Home Assistant OS gives no signal when something quietly stops working, so
# check in periodically and say so loudly in the log if Meshnet drops.
while true; do
    sleep "${CHECK_INTERVAL}" &
    wait $! || true

    if ! kill -0 "${DAEMON_PID}" 2>/dev/null; then
        bashio::exit.nok "nordvpnd has died. Restarting the add-on."
    fi

    if ! nordvpn meshnet peer list >/dev/null 2>&1; then
        bashio::log.warning "Meshnet stopped responding; trying to re-enable..."
        nord set meshnet on || true
    else
        bashio::log.debug "Meshnet healthy."
    fi
done
