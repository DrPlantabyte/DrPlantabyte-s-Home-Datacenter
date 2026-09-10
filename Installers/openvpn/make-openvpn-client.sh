#!/usr/bin/env bash
set -euo pipefail

# Create an OpenVPN client certificate and .ovpn configuration.
#
# Usage:
#
#   sudo ./make-openvpn-client.sh laptop
#
# The resulting profile will be:
#
#   /root/openvpn-clients/laptop.ovpn
#
# Override the public hostname/IP:
#
#   VPN_SERVER=vpn.example.com \
#   ./make-openvpn-client.sh laptop

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run this script as root."
    exit 1
fi


if [[ -z "${VPN_NAME:-}" ]]; then
    echo "ERROR: VPN_NAME is not defined." >&2
    exit 1
fi

CLIENT_NAME="${1:-}"

if [[ -z "${CLIENT_NAME}" ]]; then
    echo "Usage: $0 CLIENT_NAME"
    echo
    echo "Example:"
    echo "  sudo $0 laptop"
    exit 1
fi

VPN_NAME="${VPN_NAME:-server}"
VPN_PORT="${VPN_PORT:-1194}"
VPN_PROTOCOL="${VPN_PROTOCOL:-udp}"

# Public DNS name or IP address of the OpenVPN server.
#
# You can set this explicitly:
#
#   VPN_SERVER=vpn.example.com ./make-openvpn-client.sh laptop
#
VPN_SERVER="${VPN_SERVER:-}"

EASYRSA_DIR="${EASYRSA_DIR:-/etc/easy-rsa}"
OPENVPN_DIR="/etc/openvpn"
SERVER_DIR="${OPENVPN_DIR}/server"

OUTPUT_DIR="${OUTPUT_DIR:-/root/openvpn-clients}"

PKI_DIR="${EASYRSA_DIR}/pki"

if [[ -z "${VPN_SERVER}" ]]; then
    echo
    read -r -p "Public DNS name or IP address of VPN server: " VPN_SERVER

    if [[ -z "${VPN_SERVER}" ]]; then
        echo "ERROR: VPN_SERVER cannot be empty."
        exit 1
    fi
fi

# Basic sanity check on the client name.
if [[ ! "${CLIENT_NAME}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: invalid client name."
    echo "Use only letters, numbers, '.', '_' and '-'."
    exit 1
fi

echo
echo "Creating client: ${CLIENT_NAME}"
echo "Server: ${VPN_SERVER}:${VPN_PORT}"

mkdir -p "${OUTPUT_DIR}"
chmod 0700 "${OUTPUT_DIR}"

cd "${EASYRSA_DIR}"

# ---------------------------------------------------------------------------
# Create client certificate
# ---------------------------------------------------------------------------

if [[ ! -f "${PKI_DIR}/issued/${CLIENT_NAME}.crt" ]]; then
    echo
    echo "==> Generating client certificate"

    ./easyrsa build-client-full "${CLIENT_NAME}" nopass
else
    echo
    echo "Client certificate already exists; reusing it."
fi

# ---------------------------------------------------------------------------
# Build inline client profile
# ---------------------------------------------------------------------------

OUTPUT_FILE="${OUTPUT_DIR}/${CLIENT_NAME}.ovpn"

echo
echo "==> Creating ${OUTPUT_FILE}"

cat > "${OUTPUT_FILE}" <<EOF
client

dev tun
proto ${VPN_PROTOCOL}

remote ${VPN_SERVER} ${VPN_PORT}

resolv-retry infinite
nobind

persist-key
persist-tun

remote-cert-tls server

tls-version-min 1.2

auth SHA256

data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM

verb 3

<ca>
$(cat "${PKI_DIR}/ca.crt")
</ca>

<cert>
$(cat "${PKI_DIR}/issued/${CLIENT_NAME}.crt")
</cert>

<key>
$(cat "${PKI_DIR}/private/${CLIENT_NAME}.key")
</key>

<tls-crypt>
$(cat "${PKI_DIR}/private/easyrsa-tls.key")
</tls-crypt>
EOF

chmod 0600 "${OUTPUT_FILE}"

echo
echo "============================================================"
echo "Client created"
echo "============================================================"
echo
echo "Profile:"
echo "  ${OUTPUT_FILE}"
echo
echo "Copy this file securely to the client."
echo
echo "For example:"
echo
echo "  scp ${OUTPUT_FILE} user@client:/path/"
echo
echo "IMPORTANT:"
echo "  The .ovpn file contains the client's private key."
echo "  Treat it like a password."
echo
