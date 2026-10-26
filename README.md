# 小森食堂（Kitchen Game）

离线 Godot 餐厅经营与做菜小游戏。大厅、包厢和吧台共 20 桌；17 种顾客会轮换入店，兔子和狐狸负责服务，熊是餐厅主理人。

用 Godot 4.5.1 导入根目录的 `project.godot` 后按 F5 运行，或执行：

```sh
godot --path .
```

## 菜单与做菜

默认新菜单为南瓜玉米汤、香煎蘑菇、芝士烤吐司和冰拿铁；经典菜单保留土豆胡萝卜汤、番茄炒蛋、芝士烤吐司和冰拿铁。切换菜单只影响之后入座的顾客，已经入座的订单不变。

- 土豆胡萝卜汤：加水、切菜、入锅、加热、等待、盛出。
- 番茄炒蛋：切番茄、入炒锅、加热、等待、翻炒。
- 芝士烤吐司：入烤箱、等待、取出。
- 冰拿铁：依次加入咖啡、牛奶、冰块并搅拌。
- 南瓜玉米汤：加水、切菜、入锅、加热、等待、盛出。
- 香煎蘑菇：选蘑菇、入炒锅、加热、等待、翻面。

旧汤仍使用 `pour_water`、`chop` 和 `stir` 动画；新汤有独立的水龙头水流。烤箱和冰拿铁由程序状态驱动动画，并非纯静态图。盘子已绘制在行走角色帧中，仍保留通用样式；放菜和桌上菜显示对应成品图。

操作：点客人进厨房，`P` 暂停，`Esc` 会优先关闭模拟面板再退出厨房，`S` 保存。存档使用 Model V4、Session V1，并兼容旧菜；音乐与音效可独立开关和调音量，音效设置仅在本次运行有效。

## 本地玩具模拟

这是桌面本地模拟，不是 BLE、网络或真机连接。以以下命令启动后，进入厨房按 F3 可打开模拟窗：

```sh
godot --path . -- --toy-simulator
```

模拟窗只发送卡片、物理控件和完整面板快照的语义事件；它不会直接做菜。连接后需明确提交快照以对齐。模拟 adapter 的 authority token、epoch 和序号不写入存档；Model 的业务字段 `cooking_session_token` 仍会保存，二者不是同一概念。

中英文设置已实装；德语、法语、韩语和日语只保留未来语言栏位，配音尚未提供。

## 真机联动

Web 导出使用 `index.html?input=device` 进入正常可玩模式，由宿主 app 调用 `window.YggraDevice.setLink("lan"|"cloud"|"offline")` 并通过 `window.YggraDevice.push(jsonArrayText)` 批量注入玩具 payload。设备模式优先于 `autoplay`；游戏会经 `window.YggraHost.postMessage` 回报 `link:aligning`、`link:connected` 和 `link:lost`。完整协议和 NFC/面板映射见 [`docs/device_link_api.md`](docs/device_link_api.md)。

桌面本地模拟仍使用 `--toy-simulator`，不受真机模式影响。

## 测试

使用官方 Godot 4.5.1 可运行 CSV 本地化、独立真实窗口的模拟器，以及厨房集成测试：

```sh
godot --headless --path . -s tests/test_localization.gd
godot --path . -s tests/test_toy_view.gd
godot --path . -s tests/test_toy_integration.gd
godot --headless --path . -s tests/test_device_event_mapper.gd
godot --headless --path . -s tests/test_device_replay.gd
```

视觉证据保留在 `verification/` 白名单中，包括 `p0_toy_cn.png` 与 `p0_toy_en.png`。

## 素材来源

素材清单见 `assets/p0_sources.json`；字体遵循 [SIL Open Font License 1.1](https://openfontlicense.org/open-font-license-official-text/)。
