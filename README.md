---

# portal-feed

An independent OpenWrt / ImmortalWrt feed providing an **nginx-based Captive Portal Gateway** with OS-aware connectivity probe handling, secure header injection, and external signer-based authentication.

---

## Overview

**portal-feed** is a standalone feed designed to keep all **Captive Portal** and **nginx customizations** fully decoupled from the ImmortalWrt / OpenWrt base tree.

It delivers a production-grade **Portal Gateway** that sits between the dataplane (firewall) and the Portal Server, handling:

* OS connectivity probes (Android / HarmonyOS / iOS / Windows)
* Trusted context propagation (MAC / SSID / AP / Radio)
* Secure authentication via `nginx auth_request`
* Clean separation of responsibilities across system layers

The feed can be versioned, maintained, and upgraded independently.

---

## Key Features

### 1. nginx-based Portal Gateway

* Uses **native nginx configuration** (no UCI dependency)
* Supports `auth_request` for external authentication
* Clean gateway role: no business logic in nginx

---

### 2. OS Connectivity Probe Handling

Built-in support for OS-specific connectivity checks:

| Platform     | Request                | Expected Response    |
| ------------ | ---------------------- | -------------------- |
| Android      | `/generate_204`        | `204 No Content`     |
| HarmonyOS    | `/generate_204`        | `204 No Content`     |
| iOS / iPadOS | `/hotspot-detect.html` | `200 Success`        |
| Windows      | `/ncsi.txt`            | `200 Microsoft NCSI` |

> **Design principle:**
> Do not identify the operating system — identify the *behavior*.

This avoids fragile User-Agent matching and ensures long-term compatibility.

---

### 3. Trusted Header Injection

The Portal Gateway enforces a strict trust boundary:

* All client-supplied `X-Portal-*` headers are **cleared**
* Trusted headers are **re-injected** by the gateway

Injected context includes:

* Client IP
* MAC address
* SSID
* AP ID
* Radio ID
* Timestamp
* Nonce
* HMAC signature (from signer)

This prevents header spoofing and enforces a clean control plane.

---

### 4. External Signer Authentication

Authentication is delegated to an external **signer service** via:

```text
nginx auth_request → signer → decision
```

The signer:

* Verifies context and policy
* Computes HMAC / token signatures
* Returns both HTTP status and semantic headers

This design allows the signer to be implemented in:

* Shell
* Go
* C / C++
* Rust

without changing nginx configuration.

---

### 5. Clear Separation of Responsibilities

| Component              | Responsibility                             |
| ---------------------- | ------------------------------------------ |
| Firewall / Dataplane   | Traffic redirection, MAC / SSID context    |
| Portal Gateway (nginx) | Header sanitization, auth_request, routing |
| Signer                 | Authentication & signature generation      |
| Portal Server          | User interaction & business logic          |

---

## Repository Structure

```text
portal-feed/
├── packages/
│   └── portal-gateway/
│       ├── Makefile
│       ├── README.md
│       └── files/
│           ├── etc/
│           │   ├── config/
│           │   │   └── portal
│           │   ├── init.d/
│           │   │   └── portal-gateway
│           │   └── nginx/
│           │       ├── nginx.conf
│           │       └── conf.d/portal/
│           │           ├── portal-gateway.conf
│           │           ├── portal-auth.conf
│           │           ├── portal-headers.conf
│           │           ├── portal-os.conf
│           │           ├── upstream-portal.conf
│           │           └── upstream-signer.conf
│           └── usr/
│               └── libexec/portal/
│                   ├── portal-fw.sh
│                   ├── portal-agent.sh
│                   ├── portal-context.sh
│                   └── portal-runtime-init.sh
└── README.md
```

---

## Installation

### 1. Add the feed

Edit `feeds.conf` in your ImmortalWrt / OpenWrt build tree:

```text
src-git portal https://github.com/Ass-Sniper/portal-feed.git
```

---

### 2. Update and install the feed

```bash
./scripts/feeds update portal
./scripts/feeds install portal-gateway
```

---

### 3. Enable the package

```bash
make menuconfig
```

```text
Network  --->
  <*> portal-gateway
```

---

## Runtime Components

The package installs:

* nginx configuration for the Portal Gateway
* init scripts for lifecycle management
* dataplane helper scripts (`portal-fw.sh`)
* runtime context initialization scripts

The Portal Gateway runs on a dedicated port (default: **8081**) and is accessed via firewall redirection rules.

---

## Design Philosophy

* **Protocol correctness over heuristics**
* **Behavior-based OS detection**
* **Strict trust boundaries**
* **No business logic in nginx**
* **Independent lifecycle from base firmware**

This design is suitable for:

* Enterprise Wi-Fi
* Campus networks
* Router-based captive portals
* Long-term maintained products

---

## Versioning Strategy

Recommended version tags:

```text
v0.1.0  Initial gateway & probe handling
v0.2.0  auth_request + signer integration
v0.3.0  OS probe hardening
v1.0.0  Stable production release
```

---

## License

MIT

---

## Contributing

Contributions are welcome via pull requests.

Please keep all Portal-related logic inside this feed and avoid modifying the base ImmortalWrt tree directly.

---

## Status

**Active development**

---
