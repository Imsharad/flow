#!/bin/bash
# GhostType Development Signing Setup
# Creates a self-signed certificate for stable code signing during development

set -e

CERT_NAME="GhostType Development"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[SETUP]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if certificate already exists
print_status "Checking for existing development certificate..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    print_status "Certificate '$CERT_NAME' already exists!"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    echo ""
    print_status "You can use it for signing."
    exit 0
fi

print_status "Creating self-signed certificate for development..."

# Create temporary directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

# Create OpenSSL configuration
cat > "$TEMP_DIR/cert.conf" << 'EOFCONF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = GhostType Development
O = GhostType Development
OU = Development
C = US

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
EOFCONF

# Generate certificate and private key
print_status "Generating RSA key pair and certificate..."
openssl req -new -newkey rsa:2048 -x509 -days 3650 \
    -nodes \
    -out "$TEMP_DIR/cert.crt" \
    -keyout "$TEMP_DIR/key.pem" \
    -config "$TEMP_DIR/cert.conf" \
    -extensions v3_req

# Create PKCS#12 bundle with password
TEMP_PASSWORD="temp_$(date +%s)"
print_status "Creating PKCS#12 bundle..."
openssl pkcs12 -export \
    -out "$TEMP_DIR/cert.p12" \
    -inkey "$TEMP_DIR/key.pem" \
    -in "$TEMP_DIR/cert.crt" \
    -name "$CERT_NAME" \
    -passout "pass:$TEMP_PASSWORD"

# Import into keychain
print_status "Importing certificate into keychain..."
print_warning "You may need to enter your login password to unlock the keychain."

security import "$TEMP_DIR/cert.p12" \
    -f pkcs12 \
    -k ~/Library/Keychains/login.keychain-db \
    -P "$TEMP_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/productbuild \
    -T /usr/bin/security

# Mark the private key as accessible to codesign without prompting
print_status "Configuring keychain access..."
security set-key-partition-list \
    -S apple-tool:,apple: \
    -k "" \
    ~/Library/Keychains/login.keychain-db \
    2>/dev/null || {
        print_warning "Could not set key partition list (you may be prompted for keychain password during signing)"
    }

# Trust the certificate for code signing
print_status "Setting trust policy for code signing..."

# Create a temporary trust settings plist
cat > "$TEMP_DIR/trust.plist" << 'EOFTRUST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>trustSettings</key>
    <dict>
        <key>1.2.840.113635.100.1.3</key>
        <dict>
            <key>kSecTrustSettingsResult</key>
            <integer>1</integer>
        </dict>
    </dict>
</dict>
</plist>
EOFTRUST

# Try to set trust settings (may require user password)
sudo security add-trusted-cert -d \
    -r trustRoot \
    -p codeSign \
    -k /Library/Keychains/System.keychain \
    "$TEMP_DIR/cert.crt" 2>/dev/null || {
        print_warning "Could not add to system trust. You may need to manually trust the certificate."
        print_warning "Open Keychain Access, find '$CERT_NAME', and set it to 'Always Trust' for Code Signing."
    }

# Verify installation
print_status "Verifying certificate installation..."
sleep 1  # Give keychain time to update

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    print_status "✅ Certificate installed successfully!"
    echo ""
    echo "======================================"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    echo "======================================"
    echo ""
    print_status "Setup complete! You can now run ./build.sh to build with stable signing."
else
    print_warning "Certificate imported but not yet fully trusted for code signing."
    print_warning "To complete setup manually:"
    echo ""
    echo "1. Open Keychain Access"
    echo "2. Find '$CERT_NAME' in the login keychain"
    echo "3. Right-click → Get Info"
    echo "4. Expand 'Trust' section"
    echo "5. Set 'Code Signing' to 'Always Trust'"
    echo "6. Close the window (you'll need to enter your password)"
    echo ""
    echo "Then verify with:"
    echo "  security find-identity -v -p codesigning"
fi

echo ""
print_status "Next steps:"
echo "  1. Run: ./build.sh --clean"
echo "  2. Remove old GhostType entries from System Settings → Privacy → Accessibility"
echo "  3. Run: open GhostType.app"
echo "  4. Grant Accessibility permission when prompted"
echo "  5. Permissions will now persist across rebuilds!"
