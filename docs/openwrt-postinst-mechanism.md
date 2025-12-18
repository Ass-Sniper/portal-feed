---

# OpenWrt Package `postinst` 机制详解

## —— 以 portal-gateway 为例的排错与原理说明

---

## 一、问题背景

在为 `portal-gateway` 包添加 `postinst` 脚本时，遇到如下现象：

* `Makefile` 中已定义 `Package/portal-gateway/postinst`
* 编译流程 **无报错**
* `ipk` 能正常生成
* 但解包后发现：

  * `usr/lib/opkg/info/portal-gateway.postinst` **不存在**
  * 或存在但内容为空
* 安装到设备后，`postinst` 逻辑未执行

---

## 二、关键结论（先给结论）

> **OpenWrt 并不是“没执行 postinst”，而是 postinst 内容根本没有被注入进 ipk。**

根因是：

> **`Package/<name>/postinst` 中的 `<name>` 必须与 package 名称完全一致（一字不差），否则变量不会被展开，最终生成的是一个空 postinst。**

这是一个 **非常典型、但非常隐蔽** 的 OpenWrt 打包机制坑。

---

## 三、OpenWrt 中 postinst 的真实生成流程

### 1️⃣ Makefile 中的定义阶段

在 package 的 `Makefile` 中，允许定义：

```makefile
define Package/<pkg-name>/postinst
#!/bin/sh
echo "hello postinst"
endef
```

这里的 `<pkg-name>` **不是随便写的字符串**，而是必须：

* 与 `define Package/<pkg-name>` 中的名字完全一致
* 与最终 ipk 的包名一致

例如：

```makefile
define Package/portal-gateway
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Portal Gateway
endef
```

那么 postinst **只能写成**：

```makefile
define Package/portal-gateway/postinst
...
endef
```

---

### 2️⃣ 变量展开机制（核心原理）

OpenWrt 在内部会将上面的定义转化为变量：

```
define Package/portal-gateway/postinst
        ↓
V_Package_portal_gateway_postinst
```

注意这里的规则：

* `-` 会被转换成 `_`
* 名字必须 **完全匹配**
* 否则变量值为空

---

### 3️⃣ 打包阶段的关键动作（来自 build log）

在 build log 中，可以看到这一行：

```sh
echo "$V_Package_portal_gateway_postinst" > postinst-pkg
```

这一步的含义是：

* 如果变量 `V_Package_portal_gateway_postinst` 有值
  → `postinst-pkg` 写入你定义的脚本内容
* 如果变量为空
  → `postinst-pkg` 是一个 **空文件**

随后：

* OpenWrt 会将 `postinst-pkg`
* 与默认 `postinst` 包装逻辑合并
* 最终生成 `CONTROL/postinst`
* 再由 `ipkg-build` 打进 ipk

👉 **所以：变量名不匹配 = postinst 内容直接丢失**

---

## 四、为什么 build 不报错？

这是 OpenWrt 设计上的一个特点（也是坑点）：

* `Package/<name>/postinst` 是 **可选项**
* 即使变量不存在，构建系统也不会报错
* 最终只会生成一个“空逻辑”的 postinst

这就导致：

> **编译全绿，但运行行为不符合预期**

---

## 五、portal-gateway 的正确 postinst 示例

下面是一个 **正确、完整、可复用** 的 `postinst` 定义示例：

```makefile
define Package/portal-gateway/postinst
#!/bin/sh

# During image build or sysupgrade, skip runtime actions
[ -n "$$IPKG_INSTROOT" ] && exit 0

echo "[portal-gateway] postinst start"

CHECKER="/usr/libexec/portal/check-nginx.sh"

if [ -x "$CHECKER" ]; then
    if ! QUIET=1 "$CHECKER"; then
        echo "[portal-gateway] WARNING: nginx capability check failed"
        echo "[portal-gateway] Portal Gateway may not function correctly"
        echo "[portal-gateway] See logread for details"
    fi
else
    echo "[portal-gateway] NOTE: nginx checker not found: $CHECKER"
fi

if [ -x /etc/init.d/portal-gateway ]; then
    /etc/init.d/portal-gateway enable
    /etc/init.d/portal-gateway restart || true
fi

echo "[portal-gateway] postinst done"
exit 0
endef
```

---

## 六、如何快速验证 postinst 是否真正生效

### ✅ 方法一：直接看 postinst-pkg（最快）

```bash
cat \
build_dir/target-aarch64_cortex-a53_musl/portal-gateway-*/ \
ipkg-aarch64_cortex-a53/portal-gateway/CONTROL/postinst-pkg
```

* 如果是空文件 → 名字没对齐
* 如果有脚本内容 → Makefile 定义已生效

---

### ✅ 方法二：检查最终 ipk 内容

```bash
ar p portal-gateway_*.ipk data.tar.gz | tar -tz | grep postinst
```

期望结果：

```text
./usr/lib/opkg/info/portal-gateway.postinst
```

---

## 七、常见错误清单（Checklist）

以下任意一条都会导致 postinst 丢失：

* ❌ `define Package/portal/postinst`（名字不一致）
* ❌ `define Package/portal_gateway/postinst`（用 `_`）
* ❌ `define Package/Portal-gateway/postinst`（大小写不一致）
* ❌ package 重命名后忘记同步 postinst 名字

---

## 八、设计层面的理解（为什么 OpenWrt 这么做）

OpenWrt 的 package 机制遵循几个原则：

1. **Makefile 是唯一可信来源**

   * 不允许通过 `files/usr/lib/opkg/info` 注入脚本
2. **安装脚本是元数据，不是文件系统内容**

   * postinst / prerm 属于 CONTROL 信息
3. **构建系统高度自动化**

   * 名字即 key
   * key 不匹配 = 没有这个功能

这也是为什么 OpenWrt 的 feed 能长期保持一致性，但初学者很容易踩坑。

---

## 九、一句话总结

> **OpenWrt 的 postinst 不是“写了就有”，而是“名字对了才算写了”。**

你这次遇到的问题，本质上是：

* 已经理解了机制
* 只差一个字符级别的对齐

而一旦理解这一点，后续再写：

* postinst
* prerm
* preinst
* conffiles

都会非常稳。

---

后续补充：

* `postinst / prerm / preinst` 的职责边界图
* sysupgrade / image build / opkg install 三种路径对比
* 一个 **自动校验 package 名与 postinst 是否匹配的脚本**

