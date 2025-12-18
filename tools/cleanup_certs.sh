#!/bin/bash
CERT_NAME="GhostType Development"

echo "Finding certificates for '$CERT_NAME'..."

# Get all SHA-1 hashes
HASHES=$(security find-certificate -c "$CERT_NAME" -a -Z | grep "SHA-1" | awk '{print $NF}')

if [ -z "$HASHES" ]; then
    echo "No certificates found."
    exit 0
fi

echo "$HASHES" | while read HASH; do
    echo "Deleting certificate with hash: $HASH"
    # Try deleting from login and System (may need sudo for System)
    security delete-certificate -Z "$HASH" ~/Library/Keychains/login.keychain-db 2>/dev/null
    sudo security delete-certificate -Z "$HASH" /Library/Keychains/System.keychain 2>/dev/null
done

echo "Cleaned up certificates."
