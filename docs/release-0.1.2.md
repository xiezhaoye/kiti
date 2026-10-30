# lingo 0.1.2 · 2026-10-31

## 下载

- macOS 13+，Apple Silicon（arm64）。
- [官方下载](https://kiti-dl.xiezhaoye.site/lingo-0.1.2-macos-arm64.zip) · [GitHub Release](https://github.com/xiezhaoye/lingo/releases/tag/v0.1.2)
- ZIP：1,410,492 字节（约 1.4 MB，十进制）。
- 应用包文件总大小：4,720,935 字节（约 4.7 MB，不含文件系统分配块开销）。
- SHA256：`8afb759b9ccf3c999df3ca5124e189542bac463ae9c95e24ce6b2c13874731f5`。
- 固定 Apple Development 证书签名，未公证。解压后为 lingo.app。

## 这次更新

- 正式使用 lingo 名称，保留旧版应用标识、历史记录和钥匙串兼容。
- 原生磨砂侧栏、查询区、设置左栏；macOS 26+ 浮层采用 Liquid Glass，旧系统回退标准磨砂。
- 中性灰标签，0.2 秒选中底块滑动切换，移除蓝色焦点框；主窗口左上角移除品牌图标，取词浮层左下角保留小鸟。
- 保留本地系统词典、美英音标和发音、全局快捷键、自定义翻译 API／大模型、文章／文档翻译及历史同步。
- README 与官网按“本机快查／自选翻译／原生轻量”重新整理，更新演示截图和下载链接。

## 产品截图

产品截图来自当前原生界面。文章、历史、接口地址和遮蔽的 Key 均为演示内容，不代表某个翻译模型的质量测试。

- `lingo-main.jpg`：本机词典和示例历史。
- `lingo-popover.jpg`：单词取词浮层。
- `lingo-keys.jpg`：全局快捷键。
- `lingo-sentence.jpg`：整句翻译浮层。
- `lingo-article.jpg`：文章原文与译文。
- `lingo-llm.jpg`：OpenAI 兼容接口配置。
- `lingo-api.jpg`：Google／DeepL 配置。

以上文件位于 landing/assets/。演示历史、文章和译文为虚构内容，不作为翻译质量或响应时延测试。截图设置中的 example.com、your-model 和遮蔽 Key 都是示例。

## 轻量的依据与边界

体积使用上述实际 ZIP 长度和应用包文件总大小；SwiftPM 没有第三方包依赖，应用不含 Electron 或内嵌浏览器，也没有打包大模型权重。外部翻译服务或用户自行运行的本地模型的资源占用不计入 lingo 本体。

资源数据为本机已有 lingo 进程的一次空闲采样，**不是重启 0.1.2 后的受控基准测试，也不是翻译高峰或跨机器性能保证**：

- Apple M1 Max（arm64），macOS 27.0.1。
- 主窗口打开，没有翻译或朗读任务；每秒通过 `ps -p <PID> -o %cpu=,rss=` 读取一次，共 10 次。
- CPU 读数范围：0.0%–0.0%。该值为 ps 的进程统计读数，受显示精度及系统采样方式影响，不等于绝对零消耗。
- RSS 范围：119,472–119,472 KiB（约 117 MiB）。RSS 包括驻留页面和共享映射，不等于活动监视器的所有内存指标。
- 数据仅用于解释“空闲时安静待命”。翻译、文档并发、朗读、词典加载和长历史会改变占用。
