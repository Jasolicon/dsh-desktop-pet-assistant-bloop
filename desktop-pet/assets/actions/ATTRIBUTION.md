# 动作素材来源

本目录的透明 WebM 动作来自桌面宠物社区素材链：

- 素材源：https://github.com/PC2005-cloud/dsh-pet
- 整理/移植参考：https://github.com/MerZlin/dsh-pet-indesktop
- 角色 OC「溟月」出自画师 **上善无形**，素材由社区成员整理制作。

**授权口径以更保守的说明为准**：`dsh-pet-indesktop` 的第三方声明写明这类角色素材
按 **CC BY-NC-SA 类条款**发布，**仅限个人非商业使用**，使用须保留署名与来源，
不得用于商业/盈利场景。上游仓库的代码是 MIT，但“代码 MIT”不等于“角色动画素材
可以商用”；大肥鱼仓库把它写成 MIT 与本声明冲突，因此这里不采用“MIT 可商用”的口径。

泡泡本身是 PolyForm Noncommercial（非商业）项目，使用这些素材符合非商业用途；
如果以后要商用，必须替换成有明确商业授权的角色/动作素材。

这里只选了 22 段作为泡泡的可配置动作库；原始帧率、颜色和 alpha 未改动。
素材按 `idle/`、`click/`、`drag/`、`thinking/`、`speaking/`、`greeting/`、
`event/`、`meal/`、`holiday/` 分类；新增文件后可在设置里点「刷新素材」。
动作的触发、权重、时间段 / 饭点 / 节日规则由 `desktop-pet/src/rhythm.mjs` 和用户设置决定。

如果你替换成自己的素材，直接把 WebM / GIF / PNG 放进本目录（或设置里的
`actionDir`），再在「设置 → 生活节奏与动作」里改文件即可。
