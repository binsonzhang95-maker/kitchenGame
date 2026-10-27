# G11 素材增量导入

来源：`/Users/kari/Documents/动物餐厅游戏素材/G11_云端重绘_v2_20261027/G11_cloud_art_v2`，以其 `README_先读我.md` 和 `FINAL_VALIDATION.json` 为准。未导入 `sources/`、`reference_assets/`、`previews/`、`qa/` 或 `requirements/`。

## 实际导入与校验

- 导入 PNG：267（侧向动作 205、正面 chat 25、餐桌道具 7、大厅道具 30）。
- 来源 `FINAL_VALIDATION.json`：267/267、`status: PASS`；逐文件 SHA-256 已在导入前核对，并在落地后再次逐文件比对，结果 267/267 一致。
- 所有落地 PNG 已用 Pillow 实测为 RGBA 且 alpha 只含 0/255；实测为 45 张横向图集、165 个动物动作帧和 20 张 eat 手部前景。`tests/test_g11_assets.gd` 的官方 Godot 4.5.1 运行结果为 1297 assertions、0 failures，并检查所有运行时路径、帧数与逐帧 pivot 契约。
- 可重复命令：`python3 tools/import_g11_assets.py --check`。这是只读的落地验证：必须存在全部 267 个预期 PNG，且每个均与来源 `FINAL_VALIDATION.json` 的 SHA-256 一致、为 RGBA、alpha 只含 0/255；12 个生成/合并后的元数据文件也必须与要求的合并结果完全一致。任一 PNG 缺失会以 `missing landed target PNG: <path>` 非零退出。导入器遇到已存在但 SHA-256 不同的 PNG，或同名增量元数据内容不同，会拒绝而不会覆盖。

## 元数据合并契约

- `assets/actions/<species>/animation.json` 保留原有顶层字段和 `actions.eat`、`actions.complain`、`actions.happy`，只加入规范化的 `actions.chat`（4 帧、128×128 横向图集、`frame_rects`、`front_down`）。chat 保持早先的 rect 形状，不借此次侧向迁移改写旧合并数据。
- 来源侧向 JSON 的动作容器分别为 `actions`、`animations`、`clips`，不能直接作为统一 renderer 契约；已规范化为 `assets/side/<species>/g11_animation.json`，schema 为 `g11.side_animation.v1`。每个动作的每个 `frame_rects[index].pivot` 是 renderer 的权威 pivot，`per_frame_pivot[index]` 是同一值的便利镜像；它逐帧保留来源的 `frames[].pivot`（猫/狗/熊猫/卡皮巴拉）或 `per_frame_pivot`（仓鼠），包含站立 `[64,120]` 与坐下 `[64,110]` 的过渡，不能只读取动作级 `pivot`。其 `actions` 均提供 8 个右向动作、逐帧文件、128px 横向 rect 与时长；需要朝左时 renderer 对角色、前景手部和锚点一起水平镜像，不能反转帧序。
- `assets/props/anchors.json` 是键级增量合并，原 `table/chair/dish/tray` 不变。
- `restaurant_art/props.json` 的既有 `props` 字典保留；batch1 的 14 项直接并入，batch2 外层 `assets` 的 16 项已归一并入同一 `props` 字典。batch2 的变体别名和说明保留在 `g11_variant_aliases`、`g11_notes`，不覆盖既有字段。

## 覆盖范围

当前实际可用的五个物种：`cat`、`dog`、`panda`、`capybara`、`hamster`。

未到货的 P1/其余 12 个物种：`raccoon`、`red_panda`、`squirrel`、`hedgehog`、`otter`、`koala`、`deer`、`sheep`、`pig`、`penguin`、`duck`、`frog`。
