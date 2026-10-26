# 真机联动 Web API

Web 导出通过 URL 参数和一个全局 JavaScript 对象接收真实玩具事件。游戏只负责映射和校验输入；局域网、云端长轮询、鉴权和重连由宿主 app 负责。

## 启用

使用：

```text
index.html?input=device&level=…
```

`input=device` 只在 Web 导出中生效。它进入正常可玩模式并在厨房中启用设备桥；若 URL 同时带有 `autoplay`，设备模式优先，不启动自动演示。不带该参数时行为不变，桌面 `--toy-simulator` 仍可使用。

## app → 游戏

宿主在页面加载后调用：

```js
window.YggraDevice.setLink("lan");
window.YggraDevice.push(JSON.stringify([payload1, payload2]));
window.YggraDevice.setLink("offline");
```

### `YggraDevice.push(text)`

- `text` 必须是 JSON 数组字符串；单次最多 64 个 payload，超出时整批拒绝，宿主应拆批后重试。
- JS 入口只处理事件，不构造或返回逐事件结果记录，避免无用的大数组分配。
- 数组元素是玩具上报的原始 payload，即包含 `event_type` 的对象，不是 manager 外层的事件记录。
- 支持的 `event_type`：`nfc.scan`、`io.panel`、`door.state`；其他类型忽略。
- 每个映射结果由游戏补齐 adapter envelope，再交给 `KitchenInputAdapter`。只有 adapter 返回 action candidate 时才提交给当前 `CookingSession`。

### `YggraDevice.setLink(state)`

`state` 只能是：

- `"lan"`：局域网链路可用；adapter 进入 `aligning`。
- `"cloud"`：云端兜底链路可用；行为同上。
- `"offline"`：adapter 断开，清空设备映射器的 NFC、面板和边沿记忆；之后即使取消并重新进入厨房，设备模式仍保持 `simulator/disconnected` authority 和暂停 hold，不回退到屏幕输入。

连接或重连后，必须推送一个完整且 `linked: true` 的 `io.panel` payload。它会生成 `panel_snapshot`，adapter 接受后才进入 `connected`。

## 游戏 → app

游戏沿用已有的宿主接口：

```js
window.YggraHost?.postMessage(message)
```

设备消息为：

- `link:aligning`：收到 `lan`/`cloud`，或已连接的设备进入新的厨房 session，正在等待首个完整面板快照。
- `link:connected`：首个快照已被 adapter 接受。
- `link:lost`：收到 `offline`。

游戏不会下发灶台灯命令；玩具灯直接跟随实体旋钮。

## 映射规则

### NFC

天线区域：

| 天线 | zone |
|---|---|
| U16 | `stove` |
| U17 | `cutting_board` |
| U19 | `washing_machine` |
| U20 | `oven` |

UID 先按 `device_card_map.gd` 映射为中文标签名，再映射为 adapter 卡片 id。表由 `tests/fixtures/nfc_tag_map.json` 生成并由测试校验。

- 普通标签出现时生成 `{type:"card", category, zone}`。
- `pot`/`pan` 在灶台出现时生成 `{type:"vessel", kind, present:true}`。
- 锅具替换按“有效锅具”生成一个有序转换：先移除旧锅，再加入新锅；旧 UID 随后的去抖移除不再生成事件，因此不会清空已在灶上的替换锅具。
- 最后一个有效锅具离开灶台时生成 `present:false`。
- 未知 UID 每次连续存在期间最多生成一次 `read_failed`。
- 首次读到即算出现；同一区域连续 3 次 `nfc.scan` 未读到才算移除。1–2 次掉读不会重新触发出现事件。

### I/O 面板

- `knobs.stove` → `stove`
- `knobs.oven` → `oven_level`
- 档位 `0..3` → `off / small / medium / high`
- `faucet_on` → `faucet.open`
- `button_states.coffee/milk/ice` 的上升沿 → `drink_button`
- `doors != 0` → 烤箱门打开

每次链路首次出现完整的 `linked:true` 面板帧时生成 `panel_snapshot`，其中 vessel 取当前 U16 NFC 锅具状态；之后只生成变化。`linked:false` 不生成事件，并使下一个完整 linked 帧重新生成快照。

### 门磁

`door.state` 的 `doors == 0` 生成关闭事件，非零生成打开事件。
