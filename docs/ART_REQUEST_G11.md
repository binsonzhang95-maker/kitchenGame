# 美术需求 G11：结伴用餐 + 大厅丰富化

用途：交给美术（GPT imagegen 流程）出图。出图后由 pi 接入游戏（见 `docs/GROUP_DINING_PLAN.md`）。
日期：2026-10-27

## 0. 通用规则（全部资源都要遵守）

- **风格**
  - 和现有资源完全一致：暖色木质、奶油色墙、柔和描边的像素风。
  - 参考 `restaurant_art/restaurant_open_background.png`（餐厅背景）、`assets/base/*/walk.png`（动物）、`assets/props/table.png`（桌子）。
- **格式**
  - PNG RGBA，透明背景，二值透明（alpha 只能是 0 或 255，不要半透明边）。
  - 例外：第 3.6 节的光影叠加层可以半透明。
- **不能有的东西**
  - 不能有 RGB8：iOS WebKit 不显示 RGB8 贴图。
  - 不能带文字、Logo、UI。
  - 不能出现不属于该资源的角色或道具。
- **尺寸**
  - 按下面写的像素出图，用最近邻缩放，不要抗锯齿缩放。
  - 动物帧统一 128×128。
  - 视角为 3/4 俯视正面，和现有资源一致。
- **动物锚点**
  - 坐姿统一 `pivot = [64, 110]`，即座位接触点，和 `assets/seating/*/animation.json` 一样。
  - 站立和行走为 `[64, 120]`。
- **一致性**
  - 同一物种在所有动作里的头宽、配色、服装都要一致，帧和帧之间不能跳形状。
  - 头宽约 80px，参考各物种 `animation.json` 的 `approx_head_width`。
- **每个动画目录的交付物**（照现有 `assets/actions/<species>/` 的格式）：
  - `<action>.png`：横向图集，每帧 128×128。
  - `frames/<action>_NN.png`：单帧图。
  - `animation.json`：包含 frame_size、frame_count、duration_ms、loop、pivot、每帧 bounds。
  - `notes.txt`：说明生成方式和已知瑕疵。
  - `validation.json`：尺寸、alpha 和 pivot 的自检结果。
  - 需要手压在桌面上的动作，额外提供 `hands_foreground/<action>_NN.png`（同一 128×128 画布，只保留压在桌面上方的手或爪），做法同现有 eat。
- **镜像**
  - 侧面动作只画**朝右**（面向右边的桌子），朝左由游戏水平镜像。
  - 所以朝右的图不能有不对称、镜像后会穿帮的元素，比如文字、单侧口袋图案。

物种（17 种顾客）：
cat, dog, panda, raccoon, red_panda, squirrel, hedgehog, otter, capybara, koala, deer, sheep, pig, hamster, penguin, duck, frog

店员（3 种，本次只需第 2.3 节）：bear, rabbit, fox

## 1. 为什么要这些

现在每张桌子只有一把正面椅子，所有坐姿都是正面朝前，所以一桌只能坐一只，看起来像一个人吃食堂。

目标是客人 1–3 只结伴来：一只坐桌子后面（正面，用现有素材），另外两只坐桌子左右两侧（侧面，**需要新画**），围着桌子吃饭、聊天。

## 2. 结伴用餐所需资源

### 2.1 顾客侧面坐姿动作（每个物种都要，朝右）

目录：`assets/side/<species>/`

| 动作 | 文件 | 帧数 | 时长 ms（建议） | 播放 | 说明 |
|---|---|---|---|---|---|
| 坐下 | `sit_down.png` | 4 | 180,220,220,300 | 单次 | 从侧身站立转向座位，弯膝，坐稳。最后一帧 = 坐姿待机 |
| 坐姿待机 | `seated_idle.png` | 2 | 600,600 | 循环 | 轻微呼吸起伏，1–2px |
| 吃 | `eat.png` | 4 | 260,220,360,260 | 循环 | 侧身对着桌面用勺吃。要提供 `hands_foreground` |
| 喝 | `drink.png` | 4 | 240,220,420,280 | 单次 | 杯子画在图里（baked-in），规则同 `assets/drinks/cat/animation.json` |
| 开心 | `happy.png` | 4 | 200,200,240,240 | 单次 | 坐着开心晃动或举爪 |
| 不满 | `complain.png` | 4 | 220,180,260,220 | 单次 | 坐着鼓脸或跺脚，幅度小 |
| 聊天 | `chat.png` | 4 | 220,220,220,220 | 循环 | 侧身张嘴说话、点头，表现在和同桌聊天 |
| 起身 | `stand_up.png` | 3 | 200,200,220 | 单次 | 坐下的反向，最后一帧接 walk 的 right 行 |

- 每个物种 8 个动作，共 31 帧。17 个物种合计 136 张图集。
- 侧面坐姿的身体中心 x≈64；桌子在右侧，手向右伸。
- 坐姿的最低点（屁股和椅面接触点）落在 pivot y=110。

### 2.2 顾客正面"聊天"动作（每个物种都要）

目录：`assets/actions/<species>/` 新增 `chat.png`，4 帧，循环，正面朝下，pivot `[64,110]`。

用于坐在桌子后面的那只和两侧的同伴聊天：头稍微左右转、张嘴。

### 2.3 店员侧面上菜 / 收拾（bear, rabbit, fox）

- 现在的上菜（placement）和收拾（cleanup）动作只有朝左。
- 新增**朝右**版本也可以直接镜像，**不需要画**。
- 只需在 notes 里确认镜像后托盘、手不穿帮；如果会穿帮，补画 `assets/cleanup/<staff>/place_right.png` 等对应文件。

### 2.4 桌椅

目录：`assets/props/`

| 文件 | 尺寸 | 说明 |
|---|---|---|
| `chair_side.png` | 56×80 | 侧面椅子，椅背在左、坐的人朝右，与 `chair.png` 同风格。锚点在底部中心。朝左用镜像 |
| `table_family.png` + `table_family_top.png` + `table_family_front.png` | 200×110 | 加宽的家庭桌，用于包厢和大厅中排。top/front 的拆分方式同 `table_top.png`/`table_front.png`，同一画布、同原点，在 anchors.json 里写 `top_front_split_y` |
| `dish_group.png` | 56×28 | 2–3 人份的大盘或拼盘，放家庭桌中央 |
| `cup_side.png` | 32×32 | 侧面座位桌边的杯子（可以和 cup.png 相同风格） |
| `bench_queue.png` | 160×64 | 门口排队用的长椅（空的） |

请把以上资源的 anchor、footprint（地面占地矩形）写进 `assets/props/anchors.json`，格式照现有 table/chair。

## 3. 大厅丰富化资源

目录：`restaurant_art/props/`。说明写进 `restaurant_art/props.json`，包括尺寸、底部中心锚点和地面占地 footprint；挂墙的写 `wall: true`，没有地面占地。

优先级：P0 = 这一批必须有，P1 = 有更好。

### 3.1 后墙（柜台两侧现在只有壁灯，空）

| P | 文件 | 尺寸 | 说明 |
|---|---|---|---|
| P0 | `menu_board.png` | 160×120 | 木框黑板菜单，**用图形代替文字**，画几样菜的小图标（汤碗、蘑菇、蛋糕、饮料） |
| P0 | `wall_frames.png` | 3 张，各 64×64（`wall_frame_1..3.png`） | 挂画：水果静物、小山风景、小动物合影剪影 |
| P0 | `wall_shelf.png` | 128×64 | 墙上置物架，摆碗、罐子、小盆栽 |
| P1 | `wall_clock.png` | 48×48 | 圆形挂钟（指针单独做成 `wall_clock_hand.png`，16×16，便于转动） |
| P1 | `bunting.png` | 256×32 | 彩旗串，可横向平铺（两端无缝） |

### 3.2 天花板吊灯（挂在大厅桌子上方）

| P | 文件 | 尺寸 | 说明 |
|---|---|---|---|
| P0 | `pendant_lamp.png` | 32×96 | 吊线 + 灯罩，线可以向上延伸（顶部 8px 可纵向平铺） |
| P1 | `pendant_glow.png` | 96×48 | 灯下桌面的暖光斑，**允许半透明**（例外），叠加用 |

### 3.3 地面

| P | 文件 | 尺寸 | 说明 |
|---|---|---|---|
| P0 | `rug_large.png` | 256×160 | 大地毯，放在大厅桌群下，暖红或墨绿，带边纹 |
| P0 | `rug_runner.png` | 64×64 | 走道长地毯，四方连续可平铺，从入口铺到柜台 |
| P0 | `doormat.png` | 128×40 | 入口地垫 |

### 3.4 入口区

| P | 文件 | 尺寸 | 说明 |
|---|---|---|---|
| P0 | `host_stand.png` | 64×96 | 迎宾台，台上有小铃铛 |
| P0 | `coat_rack.png` | 40×112 | 衣帽架，挂一顶帽子、一条围巾 |
| P1 | `umbrella_stand.png` | 32×56 | 伞架 |
| P1 | `shop_sign.png` | 220×60 | 门头招牌，**纯图形**（叶子、锅、小熊头），不带文字 |

### 3.5 大厅中间和角落

| P | 文件 | 尺寸 | 说明 |
|---|---|---|---|
| P0 | `plant_big.png` | 64×128 | 大型落地绿植（龟背竹或琴叶榕），放角落 |
| P0 | `service_station.png` | 96×96 | 餐具水站：水壶、杯子、餐具筒 |
| P1 | `aquarium.png` | 128×96，4 帧动画（512×96） | 小鱼缸，鱼游动、水泡，放在包厢和大厅之间 |
| P1 | `dessert_case.png` | 128×96 | 甜品展示柜，玻璃里有蛋糕、布丁 |

### 3.6 吧台区

| P | 文件 | 尺寸 | 说明 |
|---|---|---|---|
| P0 | `bar_counter.png` | 256×112 | 吧台柜台，台面上有果汁机、杯子。放在右侧吧台区靠墙 |
| P1 | `drink_shelf.png` | 128×80 | 墙上饮料架，挂墙 |

### 3.7 包厢

| P | 文件 | 尺寸 | 说明 |
|---|---|---|---|
| P1 | `room_scroll.png` | 40×80 | 包厢墙上的挂轴或小画 |
| P1 | `table_lamp.png` | 24×40 | 包厢桌上的小台灯 |

### 3.8 让店里"活"起来的小动画

| P | 文件 | 尺寸 | 说明 |
|---|---|---|---|
| P1 | `shop_cat_sleep.png` | 4 帧 64×48（256×48） | 店猫在窗台睡觉，尾巴轻摆。注意别和顾客 cat 撞色太像 |
| P1 | `sunbeam.png` | 160×240，**允许半透明** | 从窗户斜射的光束叠加层 |
| P1 | `steam.png` | 4 帧 24×32（96×32） | 桌上菜冒的热气，循环 |

## 4. 交付和验收

- 按上面的目录和文件名放进 kitchenGame 仓库（或打包发来）。不要改动、覆盖现有资源。
- 每个目录附 `validation.json`，内容包括：每个 PNG 都是 RGBA、尺寸正确、alpha 只有 0 和 255（3.2 和 3.8 中标明的除外）、动物帧 pivot 位置一致。
- 先交 **5 个物种**（cat, dog, panda, capybara, hamster）的 2.1 + 2.2，再加 2.4 和 3 里的全部 P0。游戏先接入验证效果，确认没问题再补其余 12 个物种和 P1。
- 估算总量：
  - 动物：17 物种 × 9 张图集（2.1 的 8 张 + 2.2 的 1 张），共约 153 张，约 600 帧；
  - 道具：P0 15 件，P1 12 件。
