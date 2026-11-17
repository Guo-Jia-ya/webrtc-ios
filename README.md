# WebRTC iOS 客户端

局域网 WebRTC 系统的第三个端。与桌面端（`D:\Desktop\2026WebRTC\WebRTC_desk`）共用同一套服务器协议，
实现三个入口：

| 功能 | 做什么 |
|---|---|
| **加入主服务器** | 账号登录 → 看在线名单 → 呼叫 / 接听 / 加入他人房间 → 音视频通话 |
| **创建临时服务器** | iPhone 当主机，局域网内其他人用浏览器打开地址即可加入通话 |
| **加入临时服务器** | 输入对方大厅地址 + 昵称，进入大厅并通话 |

---

## 一、先看三个结论（省得踩坑）

1. **iPhone 当主机时只能前台运行。** iOS 会挂起后台进程，切到别的 App，大厅立刻断。
   桌面端没有这个限制。
2. **别人的浏览器打开你手机的地址，一定会提示"证书不受信任"。** 手机上的证书是自签的，
   任何浏览器都不认识这个 CA，只能点「高级 → 继续前往」。桌面版的临时服务器同样是自签证书。
3. **原生 App 不受"安全上下文"限制。** 主服务器是 `http://IP:3007`，浏览器在这个地址下
   拿不到摄像头（会静默失败），但原生 App 走的是系统 API，不受这条规则约束——
   这是选原生方案而不是套壳 WebView 的最大理由。

---

## 二、目录结构

```
WebRTC_ios/
├── WebRTCiOS.xcodeproj/          手写的 Xcode 工程（见"编译"一节的兜底方案）
├── project.yml                   xcodegen 用的等价工程描述（备用）
├── certs/                        自签证书母本（pem），不进 App 包
│   ├── temp-cert.pem
│   └── temp-key.pem
└── WebRTCiOS/
    ├── Info.plist                摄像头/麦克风/本地网络权限说明
    ├── App/
    │   ├── WebRTCiOSApp.swift
    │   └── RootView.swift        启动页三张卡片
    ├── Core/
    │   ├── Endpoint.swift        地址归一化（IP / IP:端口 / 带协议 / 带路径都能吃）
    │   ├── LanInfo.swift         取本机局域网 IPv4
    │   └── TrustSession.swift    自签证书信任
    ├── Net/
    │   ├── SocketIOClient.swift  手写的 socket.io v4 客户端（核心）
    │   └── MainServerAPI.swift   登录 / 注册
    ├── Model/Models.swift        名单行、来电、加入申请
    ├── Session/
    │   ├── MainServerSession.swift  主服务器：登录→大厅→二次连 8080
    │   ├── TempServerSession.swift  临时服务器：单 socket 兼顾大厅与信令
    │   └── MeshCall.swift           把 socket 事件接到 WebRTC 引擎
    ├── RTC/WebRTCEngine.swift    Mesh 引擎（每人一条 PeerConnection）
    ├── Host/
    │   ├── LocalTempServer.swift HTTPS + HTTP + WebSocket 信令服务
    │   ├── WebSocketFrame.swift  RFC 6455 帧编解码
    │   └── HostedPage.swift      发给对方浏览器的页面（含内联 WebRTC 逻辑）
    ├── UI/                       三个入口 + 通话页
    └── Resources/temp-identity.p12  主机端 TLS 身份（密码 webrtc）
```

---

## 三、编译（第一次）

1. 双击 `WebRTCiOS.xcodeproj`。
2. Xcode 会自动拉取 [stasel/WebRTC](https://github.com/stasel/WebRTC)（预编译的
   WebRTC XCFramework，**100MB 以上，首次要等几分钟**）。
   拉取失败时：`File → Packages → Reset Package Caches`，或者 `Update to Latest Package Versions`。
3. 选中 target → `Signing & Capabilities` → Team 选你自己的 Apple ID（免费账号也行，
   但真机装上的 App 7 天后失效）。
4. 真机运行时，第一次会弹「本地网络」和「摄像头/麦克风」权限，三个都要允许。
   若误点了拒绝：设置 → 隐私与安全性 → 相机/麦克风 → 打开本 App。
5. 点 Run。

> **兜底**：如果 `.xcodeproj` 打不开（这个工程文件是我手写的），
> 装个 xcodegen 重新生成一份：
> ```bash
> brew install xcodegen
> cd WebRTC_ios
> xcodegen generate
> ```
> 生成的工程与原来的等价。

**模拟器限制**：iOS 模拟器没有摄像头，通话功能在模拟器上跑不出画面（也经常连不上
PeerConnection）。名单、登录、创建服务器这些逻辑可以测，**通话必须用真机**。

---

## 四、三个功能怎么用

### 4.1 加入主服务器

1. 桌面端打开 `2026WebRTC.exe` → 「创建主服务器」。
2. iOS 填那台机器的局域网 IP（端口默认 3007，可不写）、账号密码
   （测试账号 `srtpt1` / `test123456`）。
3. 登录成功后看到在线名单：`空闲` 或 `通话中 N 人`。
4. 点「呼叫」：对方空闲 → 直接响铃；对方已在通话 → 变成**加入申请**，
   房间里每个成员都会收到弹窗，全部同意才放行（和网页版规则一致）。
5. 对方接听后，**主服务器只返回房间号和临时服务器地址**，
   App 内部会立刻再连一次 `https://<同一台机器>:8080` 建立真正的 P2P 连接。

> 为什么是两次连接：主服务器（3007）只负责"房间的账"和名单，它**不转发音视频**，
> 也不转发 SDP/ICE。真正的 Mesh 信令在临时服务器（8080）。所以大厅那台机器上
> **必须同时开着临时服务器**，否则第 5 步会提示"连不上临时服务器"。

### 4.2 创建临时服务器

1. 点「启动服务器」，端口默认 8080。
2. 页面显示地址，比如 `https://192.168.1.8:8080/`，点「复制地址」发给别人。
3. 对方在同一 Wi-Fi 下用浏览器打开 → 提示证书不安全 → 「高级 → 继续前往」→ 输昵称 → 进入。
4. 最多 4 人，画面是宫格；底部可静音、关摄像头、离开。
5. 想自己看看效果：点「在本机预览页面」，App 内会开一个内嵌浏览器加载
   `https://127.0.0.1:8080/`。

> 手机开的这个临时服务器用的是**自定义的裸 WebSocket 协议**，只服务它自己发出的那个页面。
> 也就是说：**手机开的临时服务器，只有浏览器能进**，桌面端的客户端连不进去
> （桌面端说的是 socket.io，而 Swift 里没有 socket.io 的服务端实现，原因见第六节）。

### 4.3 加入临时服务器

填地址（`192.168.1.8` 或 `192.168.1.8:8080`，带不带 `https://` 都行）+ 昵称，直接进大厅。
这里既可以加入桌面端开的临时服务器，也可以加入另一台 iPhone 开的（如果对方给你地址——
但注意对方那个用的是自定义协议，本 App 连不进去，只支持加入**桌面端**开的临时服务器）。

---

## 五、协议对照

### 5.1 主服务器（3007）

| 方向 | 事件 | 载荷 |
|---|---|---|
| HTTP | `POST /api/login` | `{id, password}` → `{status, message, token, name, id}` |
| → | `lobby-join` | `{name, userId}` |
| ← | `lobby-state` | `[{sid, userId, name, roomId, roomSize}]` |
| → | `call-user` | `{target}` |
| ← | `incoming-call` / `call-started` / `join-request` / `join-approved` | 见 `call-rooms.js` |
| → | `call-response` / `join-response` / `hang-up` | |

### 5.2 临时服务器（8080，socket.io）

| 方向 | 事件 |
|---|---|
| → | `lobby-join` / `call-user` / `call-response` / `join-response` / `mesh-join` / `hang-up` |
| ← | `lobby-state` / `incoming-call` / `call-started` / `join-request` / `joined` / `user-list` / `user-joined` / `peer-left` / `room-full` |
| 双向 | `offer` `{to, offer}` / `answer` `{to, answer}` / `ice-candidate` `{to, candidate}` |

### 5.3 手机自己开的临时服务器（裸 WebSocket，`/signal`）

| 方向 | 消息 |
|---|---|
| → | `{t:"hello", name}` |
| ← | `{t:"welcome", id, peers:[{id,name}]}` |
| ← | `{t:"peer-join", id, name}` / `{t:"peer-leave", id}` |
| 双向 | `{t:"signal", to?, from?, data:{sdp|candidate}}` |
| 双向 | `{t:"media", audio, video}` / `{t:"bye"}` |

---

## 六、原理：几个绕不开的技术点

### 6.1 为什么手写 socket.io 客户端

桌面端两套服务器都用 socket.io。它不是一个裸 WebSocket，而是套了两层：
engine.io（传输层，负责握手/心跳/升级）+ socket.io（事件层，负责 emit/on）。

Swift 生态里只有第三方客户端库，没有官方实现。而我们在 iOS 上只需要四件事：
连上、发事件、收事件、回心跳，`SocketIOClient.swift` 用 200 行覆盖：

```
① 服务端 → 0{"sid":...,"pingInterval":25000}   引擎层握手
② 客户端 → 40                                   请求进入默认命名空间
③ 服务端 → 40{"sid":"abc123"}                    这一步的 sid 才是 socket.id
④ 服务端 → 2 ，客户端 → 3                        心跳（v4 是服务端发起 ping！）
⑤ 双向   42["事件名", 载荷]                      业务事件
```

第 ④ 条最容易写错：很多老资料说"客户端定时发 ping"，那是 engine.io v3 的行为，
v4 反过来了——服务端发 `2`，客户端必须回 `3`，25 秒不回就被踢。

### 6.2 为什么不做 trickle ICE

标准 WebRTC 是把 SDP 和 ICE 候选分成多条消息发的。候选可能比 SDP 先到，
接收方还没有 `remoteDescription`，`addIceCandidate` 就会失败——现象是
"对方显示已连接，但没有画面"，而且日志里看不出明显错误，极难排查。

这里的做法是**等 ICE 收集完成再发一次完整 SDP**（收到 `.complete` 或 2.5 秒超时）。
局域网内候选收集几乎瞬间完成，代价约等于零，换来的是没有时序 bug。
别人的候选我们照样接收（网页端是 trickle 的），只是自己不发。

### 6.3 为什么手机当主机必须用 HTTPS

浏览器有一条规则：只有"安全上下文"（https 或 localhost）才允许 `getUserMedia`。
用 `http://192.168.1.8:8080` 打开页面，`navigator.mediaDevices` 直接是 undefined，
摄像头麦克风完全不可用。所以手机端必须起一个 **TLS 监听**，
用 `Resources/temp-identity.p12`（自签证书 + 私钥，密码 `webrtc`）作为服务端身份。

代价是浏览器不认这个自签 CA，一定会拦一次，用户点「继续前往」才能进。

### 6.4 为什么手机当不了 socket.io 服务器

socket.io 的服务端是一整套 Node 中间件（engine.io 的长轮询、WebSocket 升级、
命名空间、房间、ack 回调……）。Swift 里没有现成实现，自己实现它属于"重写一个库"。

所以手机端退一步：服务自己发出的那个网页，用**裸 WebSocket + 自定义 JSON 协议**。
功能上完全够（信令就是转发 SDP/ICE），只是不兼容 socket.io 的客户端。
这也是 4.2 节里"桌面端连不进手机开的服务器"的原因。

### 6.5 为什么挂断时不能关那个共用 socket

临时服务器的设计是"大厅和信令共用一个连接"。如果挂断时顺手 `socket.close()`，
人就从大厅名单里一起消失了（服务端会当作掉线）。代码里用
`MeshCall(ownsSocket:)` 区分：主服务器的视频连接是专线，可以关；
临时服务器的连接要留到大厅也退出时再关。

### 6.6 为什么主服务器要二次连接

`call-rooms.js` 里写得很清楚：主服务器"不承载音视频，也不转发 SDP/ICE，
只负责房间的账，把 roomId 和临时服务器地址交给客户端"。所以接听后必须
自己连到 8080 去开房间。漏了这一步的表现是：能接听、能进"通话页"，但永远没有画面。

---

## 七、本次对 `WebRTC_desk` 的改动

**零改动。** 一行代码都没动。

iOS 端完全是"按现有协议说话"的第三方客户端：登录用现成的 `/api/login`，
名单用现成的 `lobby-state`，呼叫/审批用现成的 `call-user`/`join-response`，
信令直接用 8080 的 `offer`/`answer`/`ice-candidate`。证书也是桌面端本来就有的自签方案。

唯一需要你在桌面端做的操作是：**同时启动主服务器（3007）和临时服务器（8080）**，
否则"加入主服务器"进不了通话（见 4.1 结尾）。

---

## 八、编译期最可能遇到的问题

这份代码是在 Windows 上写的，**没有经过 Xcode 编译验证**（这台机器没有 macOS）。
逻辑和协议我逐条对照了服务端源码，但下面这些是首次编译最可能报错的地方，按可能性排序：

1. **WebRTC 包拉不下来**：`stasel/WebRTC` 走的是 `branch = main`。若 Xcode 报
   "could not resolve package"，改成固定版本：在 Package Dependencies 里把分支换成某个
   tag（如 `120.0.0`），或在工程文件里把 `kind = branch` 改为
   `kind = upToNextMajorVersion; minimumVersion = 120.0.0;`。
2. **找不到 `RTCMTLVideoView` / `RTCPeerConnectionFactory`**：说明 WebRTC 没链接上。
   检查 target → `General → Frameworks, Libraries, and Embedded Content` 里有没有 WebRTC。
3. **签名报错**：没选 Team。模拟器运行时不需要签名，真机必须选。
4. **`sec_identity_create` 未找到**：需要 `import Security`（已加）。如果仍报错，
   说明 Network.framework 的 TLS 扩展在当前 SDK 里签名不同，可临时把
   `LocalTempServer.start()` 里的 `params` 改成 `NWParameters.tcp`（退化成 http，
   能验证信令但浏览器拿不到摄像头）。
5. **`temp-identity.p12` 没进包**：target → `Build Phases → Copy Bundle Resources` 里确认它在。
   不在就会 `loadIdentity()` 返回 nil，HTTPS 握手失败（日志里能看到我埋的那句警告）。
6. **模拟器无法通话**：正常现象，模拟器没有摄像头。用真机。
7. **Swift 6 并发检查报错**：工程默认 `SWIFT_VERSION = 5.0`，如果 Xcode 提示
   strict concurrency 相关错误，把 `SWIFT_STRICT_CONCURRENCY` 设为 `minimal`。

如果你在 Mac 上编译时报了别的错，把报错原文发我，我按行改。

---

## 九、已知限制（没做的部分）

- **大厅聊天 / 文件传输 / 语音条没有做。** 这三样网页版已经有了（`chat-ui.js`），
  原生端要重做会多出两倍的工作量，本次只做你要求的三个入口 + 通话。
- **主服务器的断线恢复（room-resume）没做。** 网络抖动重连后会回到大厅，
  而不是自动回到原来的房间。
- **只支持 IPv4 输入**，没做 IPv6 字面量解析（`[::1]` 会解析失败）。
- **手机开的服务器只支持 4 人**，和桌面端 `MAX_ROOM_SIZE` 一致，没做成可配。
- **证书是固定的自签证书**，不随设备 IP 变化重新签发，所以永远会触发浏览器的警告。
- **没有做后台保活**（iOS 也不允许），所以主机端必须一直亮着这个页面。
