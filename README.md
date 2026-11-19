# i短剧 (iDuanJu)

> **本项目完全免费、开源，禁止任何形式的付费分发 / 售卖。**
> 本项目以 **GPL-3.0** 协议发布：任何使用、修改、衍生本项目代码的作品，都必须同样以 GPL-3.0 开源并公开完整源代码。
> 如果你是花钱买到本 App 或本代码的，你被骗了，请举报卖家。

## 下载

请前往 [Releases 页面](https://github.com/my-name-is-alan/iDuanJu/releases) 下载。

## 播放内核（AetherEngine）

- 默认使用 **AetherEngine 7.62.0**（LGPL-3.0，附 App Store / DRM 例外条款），以 SwiftPM 静态链接、未修改。
- 它带的 **FFmpeg（LGPL-2.1，未启用 GPL / version3 组件）** 及 libzvbi、dav1d、zimg 以**动态框架**形式放在
  `STV.app/Frameworks/AetherLib*.framework`，没有并入主程序，可以替换 / 重新链接。各组件许可全文见
  `STV/Resources/Licenses/` 和 App 内「开源许可」，详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 免责声明

- 本项目仅供个人学习、研究 iOS / Swift / 网络协议使用，**不提供、不存储、不分发**任何视频、图片或漫画内容。
- 所有内容版权归原站点和权利人所有。使用时请遵守各站点的服务条款及你所在地的法律法规，由此产生的一切后果由使用者自行承担。
- 项目中对第三方接口的适配仅用于互通性研究，与相关平台无任何关联。如有权利人认为侵权，请提 issue 联系处理。

## 许可证

[GPL-3.0](LICENSE)。第三方组件及其许可见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

**禁止付费分发**：本项目是免费软件，作者不授权任何人以收费方式出售、分发本 App 或其代码。任何衍生作品都必须以 GPL-3.0 公开源代码。

---

## iOS 16 移植分支说明（ios16）

本分支基于上游 main（v1.5 b14）做的 iOS 16 移植，非官方版本：

- 按 i短剧 作者的指引移除了 AetherEngine 播放内核（iOS 18+ 专用），仅保留 AVPlayer 系统播放内核；
- 整个 UI 层从 `@Observable`（iOS 17+）迁移到 `ObservableObject`/`@Published`，`onChange` 等视图 API 改回 iOS 16 写法；
- 竖滑翻页改为 UIScrollView 分页实现（iOS 16 没有 `scrollTargetBehavior(.paging)`）；
- 部署目标 18.0 → 16.0，构建号 b15。