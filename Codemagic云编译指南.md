# Codemagic 云编译指南（Windows 用户专用，不用 Mac）

这份指南帮你把 `WebRTCiOS` 编译成一个能装进 iPad 的 IPA 安装包。
全程在网页上点，编译跑在 Codemagic 的云端 Mac 上，你这台 Windows 只负责下载和最后侧载。

> **为什么换到 Codemagic**：GitHub Actions 的免费 macOS 机器对刚注册的新账号有风控，会被秒取消。
> Codemagic 是专门做 App 云编译的平台，免费版每月 500 分钟 macOS 构建时间（编一次十几分钟，够用），
> **不需要信用卡**，对新账号友好。

---

## 写在最前：一个前提

你已经把代码传到了 GitHub（`https://github.com/Guo-Jia-ya/webrtc-ios`）。
但新加的 `codemagic.yaml` 配置文件还没传上去，**第 2 步要先把它 push 上去**，Codemagic 才读得到。

---

## 第 1 步：注册 Codemagic 并连接 GitHub

1. 浏览器打开 <https://codemagic.io/>，点右上角 **Sign up**。
2. 选择 **Continue with GitHub**（用 GitHub 账号登录，最省事，不用再记一套密码）。
3. 按提示授权 Codemagic 访问你的 GitHub账号 —— 选 **Only select repositories**，勾选 `webrtc-ios` 一个就够了，然后 **Install / Approve**。
4. 登录后进入 Codemagic 主界面（Applications 页面）。

---

## 第 2 步：把 codemagic.yaml 传到 GitHub（必做）

打开你的命令行窗口（Win + R → `cmd`），逐行执行：

```
cd D:\Desktop\2026WebRTC\WebRTC_ios
git add codemagic.yaml
git commit -m "add codemagic config"
git push -u origin main
```

- 如果 push 弹登录窗口，用浏览器授权一下（你之前授权过，通常不会再来）。
- 如果报 `Connection was reset`（国内连 GitHub 抽风），隔几秒重试，或连手机热点再 push。
- 看到 `main -> main` 就成功了。

> 为什么会断：国内网络到 GitHub 不稳定，多试几次就好，跟你的操作无关。

---

## 第 3 步：在 Codemagic 添加仓库

1. 在 Codemagic 的 **Applications** 页面点 **Add application**。
2. Git provider 选 **GitHub** → 若提示授权，点 **Install GitHub App** 完成授权 → 回到这里点 **Next**。
3. 在仓库列表里选 **`webrtc-ios`**。
4. 项目类型随便选（比如 **Other** / **Native iOS** 都行，因为我们会用配置文件，这一项不影响）。
5. 点 **Finish**。

---

## 第 4 步：确认 Codemagic 读到了配置文件

进入刚添加的应用后：

1. 在左侧或顶部的菜单里找到 **Configuration**（或项目设置）。
2. 如果看到 `codemagic.yaml` 里的工作流名字 **「编译 WebRTCiOS 未签名 IPA」**，说明配置读取成功 —— 这是我们要的。
3. 如果它显示的是一堆图形化选项而没有读到 yaml，先确认第 2 步 push 成功了，然后在应用页面点 **Check for configuration file / Re-sync** 刷新一下。

> 关键点：Codemagic 会读取仓库根目录的 `codemagic.yaml`。我们这个文件就放在项目根目录，位置是对的。

---

## 第 5 步：开始编译

1. 在该应用页面点 **Start new build**（开始新构建）。
2. 选择 workflow：**「编译 WebRTCiOS 未签名 IPA」**（就是 `build-unsigned-ipa`）。
3. 分支选 **`main`**，点 **Start new build** 确认。
4. 构建开始，能看到实时日志一步步往前走：
   - 安装 xcodegen
   - 重新生成工程
   - 拉取 WebRTC 库（100MB+，这步最慢，可能几分钟）
   - 编译归档
   - 打包 IPA
5. **等待 10–20 分钟**。首次构建要下载依赖，慢一点正常。

---

## 第 6 步：下载 IPA

构建结束后（无论成功失败）：

- 构建详情页下方有 **Artifacts / Build artifacts** 区域。
- 成功后下载 **`WebRTCiOS-unsigned.ipa`** —— 这就是要装进 iPad 的安装包。
- 同时下载 **`build.log`** 留着，万一要排错用。

> 如果构建**失败**（红色 Failed）：点开构建日志，找到带 `error:` 的那几行，原文复制发给我，我按行改配置文件。
> 你重 push 一次、再点一次 Start new build 就行。

---

## 第 7 步：侧载到 iPad

拿到 IPA 后，回到项目里的 **《侧载安装指南.md》**，从它的第 3 步开始照着做：

1. Windows 装好 **iTunes**（官网版，提供设备驱动）+ **Sideloadly**。
2. iPad 用 USB 连上电脑，点「信任此电脑」。
3. Sideloadly 里拖入刚下载的 `WebRTCiOS-unsigned.ipa`，填你的免费 Apple ID，点 **Start** 签名并安装。
4. iPad 上：`设置 → 通用 → VPN与设备管理` → 点你的 Apple ID → 信任。
5. **打开「开发者模式」**（iOS 16+ 必做，否则打不开）：`设置 → 隐私与安全性 → 开发者模式`。
6. 首次打开 App 时，弹的「本地网络 / 相机 / 麦克风」权限全部允许。

---

## 两个要记住的限制

- **免费 Apple ID 签名的 App 只有 7 天有效期**，到期点开闪退。重新连电脑用 Sideloadly 再点一次 Start 即可续签，数据不丢，无限次、免费。
- 这是**局域网通话 App**：iPad 要和桌面端服务器在同一个 Wi-Fi，且桌面端要**同时开主服务器 3007 和临时服务器 8080**，否则登录后接听没画面（见 README 4.1 节）。

---

## 出问题了怎么办

| 现象 | 处理 |
|---|---|
| push 报 `Connection was reset` | 隔几秒重试，或连手机热点；看到 `main -> main` 即成功 |
| Codemagic 没读到 yaml | 确认第 2 步 push 成功，点 Re-sync / Check for configuration file |
| 编译失败红色 Failed | 下载 `build.log`，把 `error:` 那几行发我 |
| 构建卡很久 | 首次拉 100MB+ 依赖，10–20 分钟内正常；超过 30 分钟可取消重来 |
| Sideloadly 认不到 iPad | 确认装了官网版 iTunes，换根数据线，重插并点「信任」 |

卡在哪一步就把那一步的截图发我，我帮你看。
