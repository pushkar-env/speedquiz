# Certificates

## AppleRootCA-G3.cer

Required to authenticate **App Store Server Notifications V2**.

That endpoint (`POST /api/v1/billing/webhooks/apple`) is public and Apple sends
no shared secret — it signs the notification body instead. The signature is the
only thing distinguishing a real "this user subscribed" event from one an
attacker POSTs, and verifying it means checking the JWS `x5c` chain terminates
at Apple's actual root. Without a pinned copy of that root, anyone can mint a
self-signed CA whose subject reads "Apple Root CA - G3" and the chain would
still appear to validate.

Fetch it once:

```bash
curl -o backend/certs/AppleRootCA-G3.cer https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
```

The file is DER-encoded; `APPLE_ROOT_CA_PATH` points at it (default
`certs/AppleRootCA-G3.cer`, resolved relative to `backend/`). To inject it as a
secret instead of a file, put the PEM or base64 DER in `APPLE_ROOT_CA_PEM`,
which takes precedence.

A production boot with Apple IAP configured and no root CA available **fails
with a startup error** rather than serving an endpoint it cannot authenticate.

Certificates are not committed — this directory is git-ignored apart from this
README.
