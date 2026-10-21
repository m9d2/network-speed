# NetSpeedStatus

状态栏上下行网速 tweak，支持 RootHide 环境。默认把小号、两行网速放在时间后面，适配 iPhone 15 Pro 灵动岛左侧空间。

## RootHide 安装

从 Sileo 或 Zebra 添加软件源：

```text
https://blog.m9d2.cn/repo/
```

安装 `NetSpeedStatus` 后，在 RootHide Bootstrap 的 App List 中确认已启用 SpringBoard 注入，然后重启 SpringBoard。

也可以从 GitHub Actions 下载 `NetSpeedStatus-roothide-deb` 工件后手动安装。

## 设置

打开系统设置中的 **NetSpeedStatus**，可配置：

- 启用或关闭状态栏网速
- 分别显示下载速度和上传速度
- 字体大小（6–12 pt）

设置保存后会通过 Darwin 通知即时应用，不需要重启 SpringBoard。

## 构建

使用 RootHide 版 Theos 和 iOS SDK：

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

RootHide 与 rootless 的包格式、路径和动态库加载方式不同。请用 RootHide Theos 直接构建本项目，不要把普通 rootless `.deb` 当作 RootHide 包安装。

## 软件源

GitHub 仓库 `m9d2/repo` 从本项目 `main` 分支构建 RootHide `.deb`，并更新该源的 APT 索引。源地址为 `https://blog.m9d2.cn/repo/`。
