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
readonly RP_FILTER_PATH="/proc/sys/net/ipv4/conf/all/rp_filter"
declare DAEMON_PID=0
declare RP_FILTER_ORIGINAL=""

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

# Mirror the daemon's state directory out to /data so the login session and
# Meshnet identity survive add-on restarts and updates.
save_state() {
    if [[ -d /var/lib/nordvpn ]] && [[ -d "${STATE_DIR}" ]]; then
        cp -a /var/lib/nordvpn/. "${STATE_DIR}/" 2>/dev/null || true
    fi
}

# Enabling Meshnet fails outright unless net.ipv4.conf.all.rp_filter is 2:
#   setting mesh: setting routing rules: setting rp filter:
#   sysctl: permission denied on key "net.ipv4.conf.all.rp_filter"
# /proc/sys is mounted read-only in add-on containers, so remount it. Because
# this add-on runs in the host network namespace, that sysctl belongs to the
# host -- so remember the previous value and put it back on the way out.
prepare_rp_filter() {
    RP_FILTER_ORIGINAL=$(cat "${RP_FILTER_PATH}" 2>/dev/null || echo "")

    if [[ "${RP_FILTER_ORIGINAL}" == "2" ]]; then
        bashio::log.info "rp_filter is already 2; leaving /proc/sys alone."
        RP_FILTER_ORIGINAL=""
        return 0
    fi

    if mount -o remount,rw /proc/sys 2>/dev/null; then
        bashio::log.info \
            "Remounted /proc/sys read-write so the client can set \
net.ipv4.conf.all.rp_filter=2 (was ${RP_FILTER_ORIGINAL:-unknown}). This is a \
host-wide setting and is restored when the add-on stops."
    else
        bashio::log.warning \
            "Could not remount /proc/sys read-write. Meshnet will fail to \
start unless net.ipv4.conf.all.rp_filter is already 2."
    fi
}

restore_rp_filter() {
    if [[ -n "${RP_FILTER_ORIGINAL}" ]]; then
        echo "${RP_FILTER_ORIGINAL}" > "${RP_FILTER_PATH}" 2>/dev/null || true
    fi
}

# For commands that are expected to be no-ops on a warm start. The CLI reports
# "already allowed" / "already denied" as a failure, and reports this device
# itself as an unknown peer; none of those are worth a warning, and ten of them
# per start refill the small add-on log buffer that the startup banner needs.
nord_idempotent() {
    local output
    if output=$(nordvpn "$@" 2>&1); then
        return 0
    fi
    if [[ "${output}" == *"already"* ]] || [[ "${output}" == *"is unknown"* ]]; then
        bashio::log.debug "nordvpn $*: $(echo "${output}" | tr '\n' ' ')"
        return 0
    fi
    bashio::log.warning "nordvpn $* failed: $(echo "${output}" | tr '\n' ' ')"
    return 1
}

cleanup() {
    trap - TERM INT EXIT
    save_state
    restore_rp_filter
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
# The add-on container is recreated on every update, so mirror it to /data.
#
# IMPORTANT: /var/lib/nordvpn must remain a REAL directory. Making it a symlink
# to /data (the obvious way to persist it) makes the client's analytics store
# fail to open with "moose: sqlite connect error", and `nordvpn login` then
# never completes -- it hangs until killed, with no error of its own. Verified
# by A/B test: 1 sqlite error with the symlink, 0 without. So copy state in at
# startup and mirror it back out, rather than redirecting the directory.
install -d -m 0750 "${STATE_DIR}"
if [[ -n "$(ls -A "${STATE_DIR}" 2>/dev/null || true)" ]]; then
    bashio::log.info "Restoring saved NordVPN state from ${STATE_DIR}"
    cp -a "${STATE_DIR}/." /var/lib/nordvpn/ 2>/dev/null || true
fi

install -d -m 0750 /run/nordvpn

# --- start the daemon ------------------------------------------------------

# Must happen BEFORE the daemon starts. Once a session has been established,
# the restored config already has Meshnet enabled, so nordvpnd tries to bring
# it up immediately on startup -- and fails on rp_filter if we have not
# prepared /proc/sys yet.
prepare_rp_filter

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
    # On a cold start the daemon is still fetching its remote config and
    # server list, and login can block behind that. Retry with backoff rather
    # than failing on a single attempt.
    login_ok=false
    for attempt in 1 2 3; do
        bashio::log.info "Logging in with the configured access token (attempt ${attempt}/3)..."

        # Capture the output. Never discard it: the client's own message is the
        # only thing that distinguishes a bad token from a network problem.
        # Redact anything token-shaped before it reaches the log.
        set +o errexit
        login_out=$(timeout 60 nordvpn login --token "${TOKEN}" 2>&1)
        login_rc=$?
        set -o errexit
        login_out=$(printf '%s' "${login_out}" | sed -E 's/[a-fA-F0-9]{32,}/<redacted>/g' | tr '\n' ' ')

        if [[ ${login_rc} -eq 0 ]]; then
            login_ok=true
            break
        fi

        if [[ ${login_rc} -eq 124 ]]; then
            bashio::log.warning "Attempt ${attempt}: timed out after 60s with no reply."
        else
            bashio::log.warning "Attempt ${attempt}: exit ${login_rc}: ${login_out:-<no output>}"
        fi

        # A rejected credential is not worth retrying.
        if [[ "${login_out}" == *"not valid"* ]] || [[ "${login_out}" == *"invalid"* ]] \
            || [[ "${login_out}" == *"expired"* ]] || [[ "${login_out}" == *"denied"* ]]; then
            bashio::exit.nok \
                "The token was rejected: ${login_out} -- generate a fresh access \
token at my.nordaccount.com and update this add-on's configuration."
        fi

        # Written as a full if, not `[[ ]] && sleep`: under `set -e` a trailing
        # short-circuit that evaluates false is a well-known way to kill a loop.
        if [[ ${attempt} -lt 3 ]]; then
            sleep $((attempt * 15))
        fi
    done

    if [[ "${login_ok}" != true ]]; then
        bashio::exit.nok \
            "Could not log in after 3 attempts. See the attempt messages above \
for the client's own explanation."
    fi
    bashio::log.info "Login succeeded."
fi

# Only settable once logged in -- see the header note.
nord set autoconnect off || true

# --- meshnet ---------------------------------------------------------------

bashio::log.info "Enabling Meshnet..."
mesh_out=$(nordvpn set meshnet on 2>&1 || true)
if [[ "${mesh_out}" == *"already enabled"* ]]; then
    bashio::log.debug "Meshnet was already enabled in the restored config."
fi

# Trust the interface, not the CLI: "already enabled" only means the setting is
# stored, and the daemon may have failed to actually bring the link up.
if ! ip link show nordlynx >/dev/null 2>&1; then
    bashio::log.warning \
        "Meshnet is configured but the nordlynx interface is missing; \
toggling it to force a fresh setup..."
    nord set meshnet off || true
    sleep 2
    nord set meshnet on || true
    sleep 3
fi

if ! ip link show nordlynx >/dev/null 2>&1; then
    bashio::exit.nok \
        "Meshnet did not come up: no nordlynx interface. If the log mentions \
rp_filter, the add-on could not make /proc/sys writable -- check that \
SYS_ADMIN is listed under 'privileged' and apparmor is false in config.yaml."
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
        nord_idempotent meshnet peer incoming allow "${peer}" || true
    else
        nord_idempotent meshnet peer incoming deny "${peer}" || true
    fi

    # Local network access only functions in tandem with traffic routing, so
    # granting one without the other would do nothing.
    if opt_bool allow_lan_access; then
        nord_idempotent meshnet peer routing allow "${peer}" || true
        nord_idempotent meshnet peer local allow "${peer}" || true
    fi

    if opt_bool allow_fileshare; then
        nord_idempotent meshnet peer fileshare allow "${peer}" || true
    else
        nord_idempotent meshnet peer fileshare deny "${peer}" || true
    fi
done < <(peer_hostnames)

if opt_bool allow_lan_access; then
    bashio::log.warning \
        "allow_lan_access is ON: peers routing through this node can reach \
every device on your LAN, including the routers."
fi

# --- report ----------------------------------------------------------------

PEER_LIST=$(nordvpn meshnet peer list 2>/dev/null || true)

# Read the identity back rather than assuming the nickname we asked for stuck:
# a name already taken by another device is rejected, and advertising a URL
# that does not resolve is worse than not advertising one.
SELF_HOST=$(printf '%s\n' "${PEER_LIST}" \
    | awk '/This device:/{f=1} f&&/Hostname:/{print $2; exit}')
SELF_NICK=$(printf '%s\n' "${PEER_LIST}" \
    | awk '/This device:/{f=1} f&&/Nickname:/{print $2; exit}')
MESH_IP=$(ip -4 -brief addr show dev nordlynx 2>/dev/null \
    | awk '{print $3}' | cut -d/ -f1 || true)

bashio::log.info "-------------------------------------------------------"
bashio::log.info "Meshnet is up. Reach Home Assistant from any peer at:"
if [[ -n "${MESH_IP}" ]]; then
    bashio::log.info "    http://${MESH_IP}:8123"
fi
if [[ -n "${SELF_HOST}" ]]; then
    bashio::log.info "    http://${SELF_HOST}:8123"
fi
if [[ -n "${SELF_NICK}" ]] && [[ "${SELF_NICK}" != "-" ]]; then
    bashio::log.info "    http://${SELF_NICK}.nord:8123"
elif ! bashio::var.is_empty "${NICKNAME}"; then
    bashio::log.warning \
        "The nickname '${NICKNAME}' did not apply -- it is probably already \
taken by another device on this account. Use the hostname above instead."
fi
bashio::log.info "-------------------------------------------------------"

# One line per peer. The raw `peer list` output runs to ~40 lines per device
# and overruns the add-on log buffer, pushing these startup messages -- the
# ones you actually need when something is wrong -- straight out of it.
bashio::log.info "Meshnet peers:"
printf '%s\n' "${PEER_LIST}" \
    | awk '/Hostname:/ { h=$2 } /^[[:space:]]*Status:/ { printf "  %-34s %s\n", h, $2 }' \
    | while IFS= read -r l; do
        bashio::log.info "${l}"
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

    # Mirror state out periodically too, so an ungraceful kill loses at most
    # one interval rather than the whole session.
    save_state
done
