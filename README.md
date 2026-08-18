# study-area-map.skill

用 R 绘制论文研究区区位图的 Claude Code 技能。基于 ggplot2、sf、terra。

![三级区位图示例](example/taiyuan_three_level_preview.png)

中国 → 山西 → 太原三级，190 × 99 mm。国家面板把周边国家掩膜成中性灰蓝，中国境内才上分层设色，国界不靠粗线也读得出来；南海诸岛落在主框内，不另开角框。省级面板省界外罩白纱，山西是全饱和的那一块。主图用 ASTER GDEM 30 m，高程分级由 DEM 自身分位推出。两段虚线锥串起三级，端点全部解析求得。

## 做到哪一步

给的是区位图的骨架，不是成品。投影、窗口、面板对齐、地形合成、图廓件这些机械而容易出错的部分由代码固定下来；配色、留白、标注位置、要素取舍没有通用答案，取决于研究区形状、期刊版式和作者偏好，需要出图后自己打磨。

预期用法是先跑出一版能看的，再逐轮调整。可调项都是脚本里显式的单个数值：窗口边距、面板高度分配、色带与级数、图例位置、引线端点。改一个数跑一遍即可，不必改逻辑。配合 agent 一轮轮改，比一次写对更快，也更容易试出适合自己那张图的做法。

代码会当场拦下几类常见错误，而不是画出一张看着正常的错图：

- DEM 未覆盖窗口，图框边缘会留无数据白缝
- 图廓件压到图框，两条线在 8 pt 下并成一条粗断线
- 强调色与其他符号撞色，同一个红在印刷上分不出两种含义
- 色带相邻两类距离过小，分级边界读不出来

## 功能

- 多级定位面板（国家、省、研究区），各级图框等宽
- 分层设色地形底图，山影按相乘合成，分级边界和饱和度都保留
- 缩放引线，虚线锥连接相邻两级面板
- 图内图例、针形指北针、比例尺
- 投影窗口、DEM 缺值、图廓件压框、强调色撞色、色带可分辨性，均自带断言

## 安装

```bash
git clone https://github.com/keros68/study-area-map.skill.git \
  ~/.claude/skills/study-area-map
```

放在 `~/.claude/skills/` 下全部项目可用，放在项目的 `.claude/skills/` 下仅该项目可用。

## 用法

两个模块自带线宽、字号、字体注册与地图主题，加载后即可用。

```r
SK <- "~/.claude/skills/study-area-map/reference/"
source(paste0(SK, "relief_basemap.R"))
source(paste0(SK, "palettes.R"))

CRS_M <- "+proj=aea +lat_1=39.3 +lat_2=40.4 +lat_0=39.85 +lon_0=113.3 +datum=WGS84 +units=m +no_defs"

# 窗口：经纬矩形投影后是弯的四边形，取内接矩形，栅格才能铺满图框
W <- inscribed_window(c(112.0, 114.6), c(39.02, 40.80), CRS_M)

# 地形：分级边界由这份 DEM 自身的 2–98 分位推出，不沿用别处的边界
dem  <- load_dem("F:/DEM", "ASTGTMV003_.*_dem[.]tif$", CRS_M, W, fact = 3)
brk  <- elev_breaks(dem, n = 6)
cols <- pal_hypso("terrain", length(brk) - 1)
rel  <- relief_rgb(dem, brk, cols, strength = 0.42)

ggplot() +
  tidyterra::geom_spatraster_rgb(data = rel) +
  geom_sf(data = aoi, fill = NA, colour = "#C62828", linewidth = LW_DAT * 1.3) +
  north_needle(W) +
  legend_backing(W, c(0.60, 0.99), c(0.02, 0.13)) +
  elev_legend(W, cols, elev_labels(brk)) +
  coord_sf(xlim = W[c("xmin", "xmax")], ylim = W[c("ymin", "ymax")],
           expand = FALSE, crs = CRS_M) +
  theme_map_pub()
```

`load_dem()` 会打印栅格尺寸和缺值比例，缺值超过阈值即停止。窗口越出 DEM 瓦片覆盖时，图框边缘会出现无数据白缝，预览时常被比例尺盖住，所以做成断言。

多面板拼版的顺序与单幅相反：先用 `pin_panel()` 把各面板尺寸定死，再用 `gridExtra::arrangeGrob()` 按毫米拼，最后由 `box_in()` 算出引线端点。`coord_sf()` 长宽比固定，先摆面板再塞地图会在槽内留信箱边，各面板图框因此不等宽。完整流程见 `SKILL.md`。

## 示例

`example/` 下两个脚本可以照着改，各出 300 dpi 成品与 150 dpi 预览两版。

| 脚本 | 层级 | 演示重点 |
|---|---|---|
| `taiyuan_three_level.R` | 中国 → 山西 → 太原 | 掩膜、白纱、两段引线；南海走主框或角框由脚本开头一个开关控制 |
| `taiyuan_locator.R` | 山西 → 太原 | 定位面板整体去饱和的另一种处理 |

三级版，`SCS_INSET <- FALSE`，窗口取全部要素，南海落在国家主框内，三级引线齐全：

![三级区位图示例](example/taiyuan_three_level_preview.png)

三级版，`SCS_INSET <- TRUE`，主框只放陆域，南海走右下角框。角框与引线锥占同一块地方，所以这一版只保留山西到主图那一段引线，中国到山西改由红色块本身指示：

![三级角框版](example/taiyuan_three_level_inset_preview.png)

两级版：

![两级区位图示例](example/taiyuan_locator_preview.png)

两者都需要三样本地数据：覆盖 N37–N38 / E111–E113 的 ASTER 压缩瓦片、含市县两级的行政区划 shp、以及 `ggmapcn::check_geodata()` 自动下载的 GEBCO。脚本开头的路径改成你自己的即可。压缩瓦片不必解包，`vsizip_tiles()` 会读归档拼出 GDAL 虚拟路径。

## 配色

六条色带，按低地是什么来选，不按口味。

| 名称 | 低 → 高 | 适用 |
|---|---|---|
| `terrain` | 绿 → 黄 → 橙 → 红褐 | 通用 |
| `arid` | 浅灰绿 → 麦秆 → 棕褐 | 低地是荒漠，绿色会误示植被 |
| `alpine` | 深绿 → 橄榄 → 灰褐 → 浅岩色 | 高差大，顶档应读作裸岩 |
| `muted` | terrain 去饱和 | 底图要承载大量叠加符号 |
| `cvd` | 蓝绿 → 卡其 → 橙 → 褐 | 避开红绿轴 |
| `gray` | L\* 等距灰阶 | 黑白印刷 |

`cols` 处处都是普通字符向量，所以别的色带照样能用：`relief_rgb(dem, brk, viridisLite::viridis(6))`。

选色带的前提是看得见。`preview_hypso(dem)` 用同一份 DEM 把全部色带各画一遍：

![色带对照](example/hypso_preview.png)

`check_ramp(cols)` 报相邻两类在正常视觉、色盲与灰度下的最小 Lab 距离。相邻类才是读者要比的那一对，隔得远的两类看着像不要紧。6 级实测：

| 色带 | 正常 | 绿色盲 | 红色盲 | 灰度 |
|---|---|---|---|---|
| `terrain` | 17.1 | 9.2 | 4.7 | 4.7 |
| `arid` | 9.7 | 5.7 | 4.0 | 5.4 |
| `alpine` | 12.6 | 4.9 | 8.0 | 1.5 |
| `muted` | 9.1 | 5.4 | 4.9 | 2.5 |
| `cvd` | **18.1** | **19.0** | **14.5** | 8.4 |
| `gray` | 11.7 | 11.7 | 11.7 | **11.7** |

三条结论直接可用：

彩色分层设色**没有一条经得起黑白印刷**（灰度 1.5 至 8.4）。期刊要黑白就换 `gray`，不要试图把彩色色带调到灰度可读。

`cvd` 是唯一在色盲下仍保持分离的彩色色带。默认的 `terrain` 在红色盲下掉到 4.7，相邻两档基本合成一档。

级数越多越挤。`terrain` 的正常视觉距离从 5 级的 21.4 掉到 10 级的 9.4，红色盲下从 2.5 掉到 0.5。级数取 5 至 8。

阈值 10 是经验值不是标准：低于它，两档的边界在 8 pt 图例上就看不出来了。判定默认只算正常视觉与两种色盲；要黑白印刷时把 `"gray"` 加进 `require`。

## 需要自己准备的数据

仓库不含 shapefile 和栅格。边界数据各地区来源不同，图注需写明出处与版本，随技能分发会丢掉这层信息；DEM 体积大，且已有公开服务。

| 用途 | 来源 | 说明 |
|---|---|---|
| 研究区面板 30 m | ASTER GDEM v3（NASA Earthdata） | 需登录，手动下载瓦片，`load_dem()` 负责合并 |
| 研究区面板 30 m | Copernicus DEM GLO-30 | 开放，无需登录 |
| 国家级面板 | GEBCO 2024，经 `ggmapcn::check_geodata()` | 0.05°，约 24 MB，自动下载 |

GEBCO 为 0.05°，约 5 km，用于国家级面板合适，用于省级面板偏粗。省级面板重采样到 700 m 显示后，图注须写明是概化地形。研究区面板需要真实 30 m DEM。

`ggmapcn` 的 jsDelivr 镜像返回 HTTP 403，函数会自行回退到 `raw.githubusercontent.com`，等它重试即可。

## 模块

| 文件 | 内容 |
|---|---|
| `reference/relief_basemap.R` | `ensure_font()` `theme_map_pub()` `inscribed_window()` `bbox_union()` `vsizip_tiles()` `inset_aspect()` `corner_inset()` `credit_footer()` `assert_inside()` `FRAME_PAD` `fit_aspect()` `win_aspect()` `load_dem()` `locate_na()` `relief_rgb()` `north_needle()` `elev_legend()` `legend_backing()` `pin_panel()` `panel_margins()` `with_font_device()` `box_in()` `add_leaders()` |
| `reference/palettes.R` | `pal_hypso()` `elev_breaks()` `elev_labels()` `preview_hypso()` `check_ramp()` `simulate_cvd()` `to_gray()` `assert_accent_unique()` `PAL_SURROUND` `BRK_SURROUND` |

两处做法与常见写法不同。

`relief_rgb()` 先按高程分箱取色，再乘以归一到均值 1 的山影系数，直接输出 RGB 栅格。山影只改变明暗，分级边界与饱和度都保留。常见的 alpha 叠压是朝下层插值，调高埋掉地形，调低埋掉颜色。`wash` 参数把颜色朝白色插值，供需要承载大量叠加符号的底图使用。

色带可复用，分级边界不可复用。`pal_hypso(name, n)` 把命名色带插值到任意级数，`elev_breaks(d, n)` 从该 DEM 自身的分位算出整数级差，首末开区间吸收长尾。四条色带按低地性质选：`terrain` 通用，`arid` 用于低地是荒漠、绿色会误示植被的情形，`alpine` 的顶层读作裸岩，`muted` 为去饱和版。级数取 5 至 8。

## 环境

R ≥ 4.3，ggplot2 ≥ 3.5，另需 sf、terra、tidyterra、ragg、systemfonts、gridExtra。`ggmapcn` 仅在使用 GEBCO 国家级底图时需要。

已验证组合：R 4.6.1，ggplot2 4.0.3，sf 1.1.2（GDAL 3.12.1）。

## 致谢

排版取值（8 pt 正文、1 pt 结构线、数据线加重、物理尺寸导出）沿用 [rfigure.skill](https://github.com/qwlei328-maker/rfigure.skill) 的约定。本技能自带这些常量，不需要另外安装。

已有 rfigure.skill 的用户可以照旧用 `theme_qw_pub()`：本技能只在 `LW`、`TXT_GG` 等尚未定义时才赋值，不覆盖已有定义。

## 许可

MIT
