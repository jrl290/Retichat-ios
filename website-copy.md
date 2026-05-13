# Retichat — Website Copy (Squarespace)

---

## HERO SECTION

**Headline:**
Messaging Without Borders

**Subheadline:**
Retichat is a fully encrypted, decentralized messenger that works over the internet, local networks, and even LoRa radio — no phone number, no email, no accounts. Just communication.

**CTA Button:**
Download on the App Store

---

## INTRO / MISSION BLOCK

**Heading:**
Private by Design. Resilient by Nature.

**Body:**
Retichat reimagines messaging from the ground up. Built on the Reticulum cryptographic networking stack and the LXMF protocol, it gives you a messenger that doesn't depend on corporate servers, cloud infrastructure, or any centralized authority. Your identity is a cryptographic keypair — nothing more. That means no sign-ups, no data harvesting, and no single point of failure.

Whether you're chatting over WiFi, cellular, or a LoRa radio mesh in the backcountry, Retichat delivers your messages securely and reliably.

---

## FEATURES GRID

### End-to-End Encrypted
Every message is encrypted with Curve25519 key exchange and Ed25519 signatures. Keys live only on your device — never on a server. Forward secrecy via automatic ratchet rotation means past messages stay private even if a key is compromised.

### No Account Required
Your identity is a cryptographic keypair generated on your device. No phone number. No email. No username. Share your address via QR code or a simple hex string — that's it.

### Works Offline & Off-Grid
Messages queue locally and deliver when a path becomes available. Propagation nodes provide store-and-forward delivery for offline recipients. Communication keeps moving even when the internet doesn't.

### Multi-Transport Networking
Connect over TCP to Reticulum transport nodes worldwide, discover local peers on your WiFi network automatically, or pair with an RNode radio for LoRa mesh networking. Use one or all simultaneously.

### Direct & Group Messaging
Send one-on-one encrypted messages or create group chats with invite, accept, and decline workflows. Attach photos and images. See real-time delivery status for every message.

### Push Notifications
Receive message notifications even when the app is in the background. Incoming messages are decrypted securely on-device through a dedicated notification extension.

---

## HOW IT WORKS

**Heading:**
A Fundamentally Different Approach

**Body:**
Traditional messengers route every message through a company's servers. Retichat doesn't. It uses the Reticulum network — a cryptography-based mesh protocol designed for resilient, decentralized communication over any medium.

1. **Generate your identity** — A keypair is created on your device. Your address is derived from your public key. No registration needed.
2. **Connect to the network** — Retichat automatically connects to Reticulum transport nodes and discovers local peers. Add LoRa radio interfaces for off-grid reach.
3. **Start messaging** — Add contacts by scanning a QR code or entering their address. Messages are encrypted end-to-end and routed through available paths.
4. **Offline? No problem.** — If a recipient is offline, messages are held by propagation nodes and delivered when they reconnect.

---

## CONNECTIVITY SECTION

**Heading:**
One App. Every Path.

| Transport | How It Works |
|-----------|-------------|
| **Internet** | Connects to 50+ public Reticulum transport nodes around the world via TCP |
| **Local Network** | Auto-discovers nearby nodes on your WiFi or LAN |
| **LoRa Radio** | Pairs with RNode hardware over Bluetooth for long-range mesh communication |
| **Propagation** | Store-and-forward delivery through distributed propagation nodes |

---

## PRIVACY SECTION

**Heading:**
Your Messages. Your Keys. Your Device.

**Body:**
Retichat was built for people who believe privacy isn't a feature — it's a right.

- **Zero knowledge** — No servers ever see your messages or metadata
- **No identifiers** — No phone number, email, or IP address tied to your identity
- **On-device crypto** — All encryption and decryption happens locally
- **Stranger filter** — Silently drop messages from unknown contacts with one toggle
- **Open protocol** — Built on Reticulum and LXMF, open protocols anyone can audit and build on

---

## CROSS-PLATFORM BLOCK

**Heading:**
Works Across Platforms

**Body:**
Retichat communicates using open protocols, making it interoperable with the broader Reticulum ecosystem. Chat with anyone running a compatible client — including Sideband, NomadNet, and custom LXMF applications — on any platform.

Available for **iOS** and **Android**.

---

## TECH SPECS (collapsible or footer-style)

- **Protocols:** Reticulum + LXMF
- **Encryption:** Curve25519 ECDH, Ed25519 signatures, AES-256, forward secrecy ratchets
- **Transports:** TCP, UDP, Local Network (Bonjour), Bluetooth (RNode), LoRa, I2P, Serial
- **Platforms:** iOS 17+, Android
- **Publisher:** New Endian
- **Identity Model:** Cryptographic keypair (no registration)
- **Message Delivery:** Direct, propagated (store-and-forward), opportunistic
- **Networking Stack:** Rust (compiled on-device)

---

## FAQ

**Do I need a phone number or email to use Retichat?**
No. Your identity is generated entirely on your device. There is no registration process.

**Can I message people who aren't using Retichat?**
Yes — Retichat uses the standard LXMF protocol, so you can communicate with anyone on a compatible client such as Sideband or NomadNet.

**Does Retichat work without the internet?**
Yes. You can communicate over local WiFi networks or LoRa radio mesh using RNode hardware, with no internet connection required.

**What happens if the person I'm messaging is offline?**
Messages are automatically routed through propagation nodes that hold them until the recipient comes back online.

**Is Retichat open source?**
Retichat is built on the open Reticulum and LXMF protocols. The networking stack is open and auditable.

**What is an RNode?**
An RNode is a LoRa radio interface that connects via Bluetooth, enabling long-range mesh communication without any internet or cellular infrastructure.

---

## FOOTER CTA

**Heading:**
Take Back Your Communication

**Body:**
No accounts. No tracking. No single point of failure. Download Retichat and start messaging on your terms.

**CTA Button:**
Download on the App Store

---

## APP STORE SHORT DESCRIPTION (for SEO / metadata)

Encrypted, decentralized messaging over internet, WiFi, and LoRa radio mesh. No phone number or account required. Built on Reticulum & LXMF.

## META / SEO

**Page Title:** Retichat — Encrypted Off-Grid Messenger
**Meta Description:** Retichat is a decentralized, end-to-end encrypted messenger that works over the internet, local networks, and LoRa radio. No account required. Available for iOS and Android.
**Keywords:** encrypted messenger, decentralized chat, off-grid messaging, mesh networking, LoRa messenger, Reticulum, LXMF, private messaging, no account messenger, RNode
