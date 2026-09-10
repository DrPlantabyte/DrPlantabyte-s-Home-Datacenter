#!/usr/bin/env bash
set -euo pipefail

THIS_DIR="$(dirname "$0")"

# OpenVPN server installation/configuration for Ubuntu 26.04 LTS.
#
# This script:
#   - installs OpenVPN, Easy-RSA, UFW and supporting packages
#   - enables IPv4 forwarding
#   - creates an Easy-RSA PKI
#   - creates a server certificate
#   - creates a tls-crypt key
#   - creates an OpenVPN server configuration
#   - configures NAT/firewall rules
#   - enables the OpenVPN systemd service
#
# Run as root.
#
# Defaults can be overridden with environment variables, e.g.:
#
#   VPN_NETWORK=10.8.0.0/24 \
#   VPN_PORT=1194 \
#   VPN_SERVER_NAME=vpn.example.com \
#   ./install-openvpn-server.sh

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run this script as root."
    exit 1
fi

if [[ -z "${VPN_NETWORK:-}" ||
      -z "${VPN_PORT:-}" ||
      -z "${VPN_SERVER_NAME:-}" ]]; then
    echo "ERROR: VPN_NETWORK, VPN_PORT, and VPN_SERVER_NAME must all be defined." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

VPN_NAME="${VPN_NAME:-server}"
VPN_PORT="${VPN_PORT:-1194}"
VPN_PROTOCOL="${VPN_PROTOCOL:-udp}"

VPN_NETWORK="${VPN_NETWORK:-10.8.0.0/24}"
VPN_NETMASK="${VPN_NETMASK:-255.255.255.0}"

VPN_DNS1="${VPN_DNS1:-1.1.1.1}"
VPN_DNS2="${VPN_DNS2:-1.0.0.1}"

EASYRSA_DIR="${EASYRSA_DIR:-/etc/easy-rsa}"
OPENVPN_DIR="/etc/openvpn"
SERVER_DIR="${OPENVPN_DIR}/server"
PKI_DIR="${EASYRSA_DIR}/pki"

SERVER_CONFIG="${SERVER_DIR}/${VPN_NAME}.conf"

# ---------------------------------------------------------------------------
# Detect external interface
# ---------------------------------------------------------------------------

DEFAULT_IFACE="$(
    ip -4 route show default |
        awk '{print $5; exit}'
)"

if [[ -z "${DEFAULT_IFACE}" ]]; then
    echo "ERROR: could not determine default network interface."
    exit 1
fi

echo "Default network interface: ${DEFAULT_IFACE}"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

echo
echo "==> Installing packages"

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openvpn \
    easy-rsa \
    ufw \
    iptables \
    openssl

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

echo
echo "==> Creating directories"

install -d -m 0755 "${SERVER_DIR}"
install -d -m 0700 "${EASYRSA_DIR}"

# ---------------------------------------------------------------------------
# Easy-RSA setup
# ---------------------------------------------------------------------------

echo
echo "==> Setting up Easy-RSA"

if [[ ! -x "${EASYRSA_DIR}/easyrsa" ]]; then
    cp -a /usr/share/easy-rsa/. "${EASYRSA_DIR}/"
    chmod +x "${EASYRSA_DIR}/easyrsa"
fi

cd "${EASYRSA_DIR}"

if [[ ! -d "${PKI_DIR}" ]]; then
    echo "Creating PKI..."
    ./easyrsa init-pki
fi

# ---------------------------------------------------------------------------
# CA
# ---------------------------------------------------------------------------

if [[ ! -f "${PKI_DIR}/ca.crt" ]]; then
    echo
    echo "==> Creating Certificate Authority"
    echo
    echo "You will be prompted for a CA password."
    echo "KEEP THIS PASSWORD SAFE."
    echo

    ./easyrsa build-ca
fi

# ---------------------------------------------------------------------------
# Server certificate
# ---------------------------------------------------------------------------

if [[ ! -f "${PKI_DIR}/issued/${VPN_NAME}.crt" ]]; then
    echo
    echo "==> Creating server certificate"

    ./easyrsa build-server-full "${VPN_NAME}" nopass
fi

# ---------------------------------------------------------------------------
# Diffie-Hellman parameters
# ---------------------------------------------------------------------------

if [[ ! -f "${PKI_DIR}/dh.pem" ]]; then
    echo
    echo "==> Generating Diffie-Hellman parameters"
    echo "This can take a while."

    ./easyrsa gen-dh
fi

# ---------------------------------------------------------------------------
# CRL
# ---------------------------------------------------------------------------

if [[ ! -f "${PKI_DIR}/crl.pem" ]]; then
    echo
    echo "==> Creating certificate revocation list"

    ./easyrsa gen-crl

    chmod 0644 "${PKI_DIR}/crl.pem"
fi

# ---------------------------------------------------------------------------
# TLS crypt key
# ---------------------------------------------------------------------------

if [[ ! -f "${PKI_DIR}/private/easyrsa-tls.key" ]]; then
    echo
    echo "==> Creating TLS crypt key"

    ./easyrsa gen-tls-crypt-key
fi

# ---------------------------------------------------------------------------
# Copy server credentials
# ---------------------------------------------------------------------------

echo
echo "==> Installing server credentials"

install -m 0644 \
    "${PKI_DIR}/ca.crt" \
    "${SERVER_DIR}/ca.crt"

install -m 0644 \
    "${PKI_DIR}/issued/${VPN_NAME}.crt" \
    "${SERVER_DIR}/${VPN_NAME}.crt"

install -m 0600 \
    "${PKI_DIR}/private/${VPN_NAME}.key" \
    "${SERVER_DIR}/${VPN_NAME}.key"

install -m 0600 \
    "${PKI_DIR}/private/easyrsa-tls.key" \
    "${SERVER_DIR}/ta.key"

install -m 0644 \
    "${PKI_DIR}/dh.pem" \
    "${SERVER_DIR}/dh.pem"

install -m 0644 \
    "${PKI_DIR}/crl.pem" \
    "${SERVER_DIR}/crl.pem"

# ---------------------------------------------------------------------------
# OpenVPN server configuration
# ---------------------------------------------------------------------------

echo
echo "==> Creating OpenVPN configuration"
cat > "${SERVER_CONFIG}" <<EOF
# OpenVPN server configuration
#
# Generated by install-openvpn-server.sh

port ${VPN_PORT}
proto ${VPN_PROTOCOL}

dev tun

# PKI
ca ${SERVER_DIR}/ca.crt
cert ${SERVER_DIR}/${VPN_NAME}.crt
key ${SERVER_DIR}/${VPN_NAME}.key

dh ${SERVER_DIR}/dh.pem
crl-verify ${SERVER_DIR}/crl.pem

# Protect the TLS control channel
tls-crypt ${SERVER_DIR}/ta.key

# VPN network
server ${VPN_NETWORK%/*} ${VPN_NETMASK}

# Maintain client addresses across reconnects
ifconfig-pool-persist ${SERVER_DIR}/ipp.txt

# Modern TLS settings
tls-version-min 1.2

# Data channel cipher negotiation
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM

# Authentication
auth SHA256

# Keep connections alive
keepalive 10 120

# Notify clients when server is shutting down
explicit-exit-notify 1

# Don't daemonize/log to a separate file.
# systemd/journald handles logging.

# Drop privileges after initialization
user nobody
group nogroup

# Security
persist-key
persist-tun

# Reduce privileges further where supported
topology subnet

# Push Internet routing to clients
push "redirect-gateway def1 bypass-dhcp"

# DNS servers
push "dhcp-option DNS ${VPN_DNS1}"
push "dhcp-option DNS ${VPN_DNS2}"

# Allow VPN clients to communicate with each other.
# Remove this if client-to-client communication is not desired.
client-to-client

# Status information
status ${SERVER_DIR}/status.log

# Connection logging
verb 3
EOF

chmod 0600 "${SERVER_CONFIG}"

# ---------------------------------------------------------------------------
# Enable IPv4 forwarding
# ---------------------------------------------------------------------------

echo
echo "==> Enabling IPv4 forwarding"

cat > /etc/sysctl.d/99-openvpn-forwarding.conf <<EOF
net.ipv4.ip_forward = 1
EOF

sysctl --system

# ---------------------------------------------------------------------------
# UFW configuration
# ---------------------------------------------------------------------------

echo
echo "==> Configuring UFW"

# Make sure SSH isn't accidentally blocked.
ufw allow OpenSSH

# OpenVPN
ufw allow "${VPN_PORT}/${VPN_PROTOCOL}"

# Determine VPN network without CIDR suffix.
VPN_SUBNET="${VPN_NETWORK%/*}"

# Add NAT rules to UFW's before-rules.
UFW_BEFORE="/etc/ufw/before.rules"

if ! grep -q "# BEGIN OPENVPN NAT" "${UFW_BEFORE}"; then
    cp "${UFW_BEFORE}" "${UFW_BEFORE}.openvpn-backup"

    cat >> "${UFW_BEFORE}" <<EOF

# BEGIN OPENVPN NAT
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${VPN_NETWORK} -o ${DEFAULT_IFACE} -j MASQUERADE
COMMIT
# END OPENVPN NAT
EOF
fi

# Enable forwarding through UFW.
UFW_DEFAULT="/etc/default/ufw"

sed -i \
    's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' \
    "${UFW_DEFAULT}"

# Reload/enable UFW.
ufw --force enable

# ---------------------------------------------------------------------------
# Enable systemd service
# ---------------------------------------------------------------------------

echo
echo "==> Enabling OpenVPN systemd service"

systemctl daemon-reload

systemctl enable "openvpn-server@${VPN_NAME}.service"

systemctl restart "openvpn-server@${VPN_NAME}.service"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo
echo "==> OpenVPN status"

systemctl --no-pager --full status \
    "openvpn-server@${VPN_NAME}.service"

echo
echo "============================================================"
echo "OpenVPN installation complete"
echo "============================================================"
echo
echo "Server configuration:"
echo "  ${SERVER_CONFIG}"
echo
echo "VPN network:"
echo "  ${VPN_NETWORK}"
echo
echo "VPN port:"
echo "  ${VPN_PORT}/${VPN_PROTOCOL}"
echo
echo "Network interface:"
echo "  ${DEFAULT_IFACE}"
echo
echo "Service:"
echo "  openvpn-server@${VPN_NAME}.service"
echo
echo "Useful commands:"
echo
echo "  systemctl status openvpn-server@${VPN_NAME}"
echo "  journalctl -u openvpn-server@${VPN_NAME}"
echo "  systemctl restart openvpn-server@${VPN_NAME}"
echo
echo "Easy-RSA PKI:"
echo "  ${EASYRSA_DIR}"
echo
echo "IMPORTANT:"
echo "  Back up ${EASYRSA_DIR}/pki"
echo "  The CA private key is:"
echo "    ${EASYRSA_DIR}/pki/private/ca.key"
echo


