# portal-feed Profiles

This directory contains **configuration fragments** (defconfig files)
for integrating `portal-feed` into an existing OpenWrt / ImmortalWrt
build configuration.

⚠️ These profiles are **NOT full `.config` files** and must **NOT**
be copied directly over an existing `.config`.

They are intended to be **merged** into an existing build configuration.

---

## portal-gateway.defconfig

`portal-gateway.defconfig` provides a **minimal, production-ready
configuration fragment** required to build and run the
nginx-based Portal Gateway.

It enables:

- `portal-gateway` package
- nginx (SSL-enabled)
- Required nginx HTTP modules
- Required runtime utilities (iptables, ipset, curl, etc.)

The fragment only contains options **strictly required by portal-gateway**
and does not alter unrelated system, target, or driver settings.

---

## Correct Usage (Recommended)

To merge the profile into an existing build configuration, use the
OpenWrt-provided `kconfig.pl` helper:

```sh
scripts/kconfig.pl 'm+' .config portal-feed/profiles/portal-gateway.defconfig > .config.new
mv .config.new .config
make defconfig
````

This approach:

* Preserves all existing configuration options
* Enables or updates only the options defined in the profile
* Is safe for multi-feature and long-lived firmware trees
* Is suitable for CI and automated builds

---

## Incorrect Usage (Do NOT do this)

❌ **Do not overwrite your existing configuration:**

```sh
cp portal-feed/profiles/portal-gateway.defconfig .config
make defconfig
```

This will discard all previously selected options and is unsafe
for real-world firmware builds.

---

## Design Rationale

Profiles in `portal-feed` follow the **config fragment** model:

* They declare *capabilities required by the feed*
* They do not attempt to define a complete system configuration
* They can be composed with other fragments (Wi-Fi, VPN, routing, etc.)

This design ensures:

* Clean separation of concerns
* Minimal coupling with the base firmware
* Predictable long-term maintenance

---

## Advanced Usage (Multiple Fragments)

Multiple configuration fragments can be merged together:

```sh
scripts/kconfig.pl 'm+' .config \
    base.defconfig \
    wifi.defconfig \
    portal-feed/profiles/portal-gateway.defconfig \
    > .config.new

mv .config.new .config
make defconfig
```

This model is recommended for CI pipelines and multi-profile products.

---

## Notes

* Always run `make defconfig` after merging fragments
* Verify nginx capabilities using:

  ```sh
  nginx -V
  ```
* Runtime validation is additionally enforced by:

  * `postinst` (installation-time warnings)
  * `/etc/init.d/portal-gateway` (startup-time hard checks)

---

## Summary

> **Profiles are capability fragments, not system configurations.**

They are designed to be merged, composed, and reused across builds
without overriding existing firmware choices.