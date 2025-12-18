
# 在 OpenWrt 中安全修改 `nginx.init` 的方法

## —— 支持 Native `nginx.conf` 且不被 `feeds update` 覆盖

---

## 一、问题背景

在 OpenWrt / ImmortalWrt 中，`nginx` 默认行为通常是：

* 通过 **UCI**（`/etc/config/nginx`）生成配置
* 启动时由 `/etc/init.d/nginx` 控制配置路径
* 不直接使用原生的 `/etc/nginx/nginx.conf`

但在以下场景中，这种模式并不适用：

* Captive Portal / Portal Gateway
* `auth_request`
* header 注入 / 动态生成配置
* 高度自定义的 stream / http 混合配置

因此需要：

> **让 nginx 支持使用原生 `/etc/nginx/nginx.conf`（native mode）
> 并在需要时绕过 UCI 控制。**

---

## 二、直接修改 `feeds/packages/net/nginx/files/nginx.init` 的问题

最直观的做法是直接改：

```text
feeds/packages/net/nginx/files/nginx.init
```

但这会带来一个**确定性问题**：

> ❌ 一旦执行 `scripts/feeds update packages`
> ❌ 修改一定会被覆盖
> ❌ 且无任何提示

因此：

> **直接修改官方 feed 中的 nginx.init 不是可维护方案**

---

## 三、为什么不能用 `patches/*.patch` 解决？

很多人会尝试写一个 patch，例如：

```diff
--- a/files/nginx.init
+++ b/files/nginx.init
```

但这会失败，原因是 **OpenWrt patch 机制的作用范围**：

### OpenWrt patch 机制只作用于：

* upstream 源码（解压到 `build_dir` 的 tarball）
* 不包含 `files/`、`init.d` 等 packaging 层内容

而 `files/nginx.init` 属于：

> **OpenWrt 包装层（packaging layer），不是源码层**

因此：

* ❌ patch 无法应用
* ❌ 即使强行 apply，也不可维护
* ❌ 不符合 OpenWrt 设计

---

## 四、正确的整体思路（核心原则）

> **凡是修改 OpenWrt packaging 层的行为：**
>
> * 不要 patch 官方 feed
> * 不要手改 upstream feed
> * 应该在 *自己的 feed* 中 fork / override package

这也是 OpenWrt vendor / 产品线的标准做法。

---

## 五、推荐方案：在自有 feed 中 fork nginx package

### 方案目标

* 修改 `nginx.init`
* 永久生效
* 不受 `feeds update` 影响
* 符合 OpenWrt 机制
* 可长期维护

---

### 5.1 创建自有 nginx package（fork）

假设你的自有 feed 为 `portal`：

```bash
mkdir -p feeds/portal/packages/nginx
cp -a feeds/packages/net/nginx/* feeds/portal/packages/nginx/
```

此时目录结构类似：

```text
feeds/portal/packages/nginx/
├── Makefile
├── files/
│   └── nginx.init
├── patches/
└── ...
```

---

### 5.2 修改 fork 后的 `nginx.init`

编辑：

```bash
feeds/portal/packages/nginx/files/nginx.init
```

引入 **Native Config 支持逻辑**（示例）：

```sh
USE_NATIVE_CONF="${USE_NATIVE_CONF:-0}"

start_service() {
    if [ "$USE_NATIVE_CONF" = "1" ]; then
        echo "[nginx] starting with native nginx.conf"
        nginx -c /etc/nginx/nginx.conf
        return
    fi

    # 默认 OpenWrt / UCI 行为
    uci_apply nginx
    nginx -c /var/etc/nginx.conf
}
```

> 实际实现可根据你项目需要调整
> 关键是：**native 与 UCI 行为清晰分支**

---

### 5.3 修改 Makefile（两种模式，选一种）

#### 模式 A（推荐）：作为独立 nginx 变体

```makefile
PKG_NAME:=nginx-portal
PROVIDES:=nginx
CONFLICTS:=nginx
```

效果：

* 系统中只能安装一个 nginx
* 依赖 `nginx` 的包仍然满足
* portal-gateway 可明确依赖 `nginx-portal`

---

#### 模式 B（vendor 常用）：同名覆盖官方 nginx

保持：

```makefile
PKG_NAME:=nginx
```

并确保 `feeds.conf.default` 中顺序：

```text
src-git packages https://git.openwrt.org/feed/packages.git
src-git portal   https://your/portal-feed.git
```

OpenWrt 会优先使用 `portal` feed 中的 nginx。

---

## 六、为什么这种方式不会被 `feeds update` 覆盖？

因为：

* `feeds update packages` 只更新 **官方 feed**
* 不会触碰你的：

  ```text
  feeds/portal/
  ```
* fork 的 nginx 完全由你维护

这是 **vendor / SDK / 产品固件** 的标准模式。

---

## 七、portal-gateway 与 nginx 的职责边界（设计说明）

在合理设计中：

### nginx（平台能力）

* 是否支持 native nginx.conf
* init 行为
* 编译模块（stream / ssl / http）

### portal-gateway（业务能力）

* 检测 nginx 能力（`check-nginx.sh`）
* 声明依赖
* 生成 / 管理 nginx.conf
* 不直接修改 nginx 本体

你当前的设计已经符合这个边界。

---

## 八、验证修改是否生效

### 8.1 构建期验证

```bash
make package/nginx/{clean,compile} V=s
```

确认 install 阶段包含：

```text
install -m0755 ./files/nginx.init ... /etc/init.d/nginx
```

---

### 8.2 运行期验证

```bash
USE_NATIVE_CONF=1 /etc/init.d/nginx restart
```

确认：

* nginx 使用 `/etc/nginx/nginx.conf`
* UCI 不再覆盖配置
* portal-gateway 行为符合预期

---

## 九、总结（一句话）

> **修改 `nginx.init` 是 packaging 层行为，
> 正确方式不是 patch，而是 fork / override nginx package。**

这样做的结果是：

* 不怕 feeds update
* 行为可控
* 架构清晰
* 符合 OpenWrt 生态

---