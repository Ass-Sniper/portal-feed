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

## Nginx Build Requirements

The Portal Gateway relies on a **non-minimal nginx build** with specific HTTP modules enabled.
These modules are required for correct runtime behavior and **are not optional**.

### Required nginx Package

The following nginx packages **must be selected**:

```text
nginx-ssl
nginx-util
nginx-ssl-util
```

Minimal nginx variants are **not supported**.

---

### Required nginx HTTP Modules

When building nginx via `make menuconfig`, ensure the following modules are enabled:

```text
CONFIG_NGINX_HTTP_AUTH_REQUEST=y
CONFIG_NGINX_HTTP_PROXY=y
CONFIG_NGINX_HTTP_MAP=y
CONFIG_NGINX_HTTP_REWRITE=y
CONFIG_NGINX_HEADERS_MORE=y
CONFIG_NGINX_HTTP_LIMIT_CONN=y
CONFIG_NGINX_HTTP_LIMIT_REQ=y
```

These modules are required for:

| Module                     | Purpose                                 |
| -------------------------- | --------------------------------------- |
| `http_auth_request`        | External signer-based authentication    |
| `http_proxy`               | Proxying traffic to Portal Server       |
| `http_map`                 | OS / behavior classification            |
| `http_rewrite`             | Probe handling and control flow         |
| `headers_more`             | Trusted header sanitization & injection |
| `limit_conn` / `limit_req` | Basic abuse protection                  |

---

### Regular Expression Support

The Portal Gateway uses `map` and regular expressions extensively.

Ensure the following libraries are enabled:

```text
CONFIG_NGINX_PCRE=y
CONFIG_PACKAGE_libpcre=y
```

---

### Validation Checklist

After building and installing the firmware, verify:

```sh
nginx -V
```

The output should include:

```text
--with-http_auth_request_module
--with-http_map_module
--with-http_proxy_module
```

Missing modules will result in nginx configuration errors or silent runtime failures.

---

### Design Note

This feed intentionally **does not force nginx Kconfig options**.

The responsibility of selecting the correct nginx feature set remains with the firmware build configuration, ensuring:

* No hidden side effects
* No unexpected global configuration changes
* Full compatibility with existing nginx-based deployments

---

### Common Misconfiguration

❌ Using `nginx-minimal`

❌ Missing `headers_more` module

❌ Missing `http_auth_request`

❌ Building nginx without PCRE support


All of the above will cause the Portal Gateway to fail.

---

## Nginx Capability Checks

Portal Gateway performs nginx capability validation at multiple stages to prevent misconfiguration.

### Shared Checker Script

All nginx capability checks are implemented in a shared script:

```text
/usr/libexec/portal/check-nginx.sh
```

This script verifies:

* nginx binary existence
* Required HTTP modules:

  * `http_auth_request`
  * `http_proxy`
  * `http_map`
  * `headers_more`
  * `http_rewrite`
  * `limit_conn`
  * `limit_req`

---

### Installation-Time Checks (postinst)

During package installation:

* The checker is executed in **warning-only mode**
* Installation is **never aborted**
* Missing capabilities are logged and printed

Purpose:

* Allow users to install portal-gateway before rebuilding nginx
* Provide early diagnostics without disrupting the system

---

### Startup-Time Checks (init.d)

Before starting the portal-gateway service:

* The checker is executed in **strict mode**
* Service startup is refused if requirements are not met
* The system remains unaffected

Purpose:

* Prevent undefined or partially functional runtime behavior

---

### Design Rationale

This layered validation model ensures:

* Clear diagnostics at installation time
* Hard safety gates at service startup
* Single source of truth for nginx capability requirements

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
