

# Portal Gateway × Nginx 集成问题分析与解决记录

> 适用环境：OpenWrt / ImmortalWrt
> 目标场景：基于 nginx 的 Captive Portal / Gateway（auth_request / proxy / limit / rewrite 等）

---

## 1. 问题背景

`portal-gateway` 作为一个 **nginx-based captive portal gateway**，对 nginx 的能力有明确要求，包括但不限于：

* `http_proxy`
* `http_map`
* `http_rewrite`
* `limit_conn`
* `limit_req`
* `http_auth_request`
* `headers_more`

然而在实际部署与测试过程中，出现了如下异常现象：

* nginx 已编译并运行
* `nginx -V` 显示包含相关模块
* 但 `portal-gateway` 的 capability checker 判定 **“缺失能力”**
* 服务拒绝启动

---

## 2. 关键问题一：OpenWrt nginx 包的「虚拟包」与变体机制

### 2.1 nginx 包结构（核心认知）

OpenWrt 中 nginx 实际上是一个 **多变体体系**：

| 包名                 | 实际作用                      |
| ------------------ | ------------------------- |
| `nginx`            | **dummy / transition 包**  |
| `nginx-ssl`        | 精简 SSL 版本（按 config 剪裁模块）  |
| `nginx-all-module` | **全模块版本（推荐给 gateway 使用）** |
| `nginx-util`       | UCI / init 脚本辅助           |
| `nginx-ssl-util`   | SSL 辅助工具                  |

其中：

* `nginx` **不保证任何 HTTP 模块能力**
* `nginx-ssl` 会根据 `.config` **裁剪模块**
* `nginx-all-module` 才是 **确定性包含所有 HTTP 模块**

---

### 2.2 实际踩坑表现

即使系统中 **已手动安装** `nginx-all-module`：

```sh
opkg install nginx-all-module_*.ipk
```

在随后安装 `portal-gateway` 时：

```sh
opkg install portal-gateway_*.ipk
```

**opkg 仍可能：**

* 自动拉取 `nginx` / `nginx-ssl`
* 覆盖或并行安装一个 **模块不全的 nginx**
* 导致 capability check 失败

---

### 2.3 解决方案（已采用）

在 `portal-gateway` 的 `Makefile` 中：

```makefile
DEPENDS:= \
    +nginx-all-module \
    +nginx-util \
    +nginx-ssl-util \
    ...
```

**明确依赖 `nginx-all-module`，而不是 `nginx` / `nginx-ssl`。**

> ✅ 这是保证 gateway 行为确定性的唯一可靠方式。

---

## 3. 关键问题二：`nginx -V` 的模块判定语义

### 3.1 nginx 模块的两个世界

#### 1️⃣ **默认内建模块（HTTP core）**

例如：

* proxy
* map
* rewrite
* limit_conn
* limit_req

👉 **特点：**

* 默认启用
* 不会出现在 `--with-http_xxx`
* 只会在被禁用时出现：

  ```text
  --without-http_proxy_module
  ```

#### 2️⃣ **可选 / 第三方模块**

例如：

* `http_auth_request`
* `headers_more`

👉 **特点：**

* 只有启用才会出现在 `nginx -V`
* 必须通过 **字符串存在性** 判断

---

### 3.2 原有 checker 的问题

最初逻辑是：

```sh
grep http_proxy
```

这在 OpenWrt 上 **是错误的**，因为：

* `http_proxy` 是默认模块
* `nginx -V` 根本不会打印

---

### 3.3 修正后的判定策略（已实现）

```sh
# 默认 HTTP 模块：检查是否被 explicitly 禁用
require_http_module proxy
require_http_module map
require_http_module rewrite
require_http_module limit_conn
require_http_module limit_req

# 可选模块：检查是否存在
require_feature "http_auth_request" "http_auth_request"
require_feature "headers_more"      "headers-more"
```

👉 这与 nginx 的 **configure 语义完全一致**。

---

## 4. 关键问题三：BusyBox grep 与 GNU grep 的差异

### 4.1 实际报错

在设备上执行 checker：

```text
grep: unrecognized option: without-http_proxy_module
```

### 4.2 根因

BusyBox `grep`：

* **不会自动终止 option 解析**
* 当 pattern 以 `-` 开头时，会被当成参数

例如：

```sh
grep -q "--without-http_proxy_module"
# BusyBox 认为这是一个 option
```

---

### 4.3 正确写法（POSIX / BusyBox 安全）

```sh
grep -q -- "--without-http_proxy_module"
```

### 4.4 最终统一实现

```sh
GREP="grep -q --"

echo "$NGINX_BUILD" | $GREP "$pattern"
```

✅ 同时兼容：

* BusyBox grep
* GNU grep
* CI / 本地 Linux

---

## 5. `check-nginx.sh` 的最终职责边界

### 5.1 设计目标

* **独立**
* **可复用**
* **语义清晰**
* **不依赖 UCI / init 状态**

### 5.2 使用场景

| 场景                    | 行为                 |
| --------------------- | ------------------ |
| postinst              | 软检查 + warning      |
| init.d/portal-gateway | 硬检查，失败即拒绝启动        |
| 手工排障                  | `./check-nginx.sh` |
| CI / 自动化              | 可直接复用              |

---

## 6. 经验总结（关键结论）

### ✅ 结论 1

> **Gateway 级应用必须依赖 `nginx-all-module`，而不是 `nginx`。**

---

### ✅ 结论 2

> **不能通过“是否出现 --with-xxx”判断默认 HTTP 模块。**

---

### ✅ 结论 3

> **BusyBox ≠ GNU userland，所有脚本都必须假设最小实现。**

---

### ✅ 结论 4

> **Capability checker 是基础设施，不是临时脚本。**

---

## 7. 后续可选优化方向

* [ ] `check-nginx.sh --json`（供 CI / API 使用）
* [ ] 在 init.d 中区分「缺失模块」vs「配置错误」
* [ ] 对 nginx 版本做最小要求校验
* [ ] 输出 `nginx -V` 摘要到日志（debug 模式）

---
