# 从源码构建

需要 macOS、Xcode 及命令行工具。工程最低系统版本为 macOS 14，当前使用 Xcode 26.5 构建；其他组合尚未全面验证。

## 本地签名

复制 `Config/Local.xcconfig.example` 为 `Config/Local.xcconfig`，填写自己的 `DEVELOPMENT_TEAM`。该文件被 Git 忽略，不要上传。个人 Apple 开发者账号同样有 Team ID；这不表示需要组织账号。

主程序和 WidgetKit 扩展必须由同一身份签名，共享容器默认使用 `$(DEVELOPMENT_TEAM).$(DESKKIT_BUNDLE_ID)`。`DESKKIT_BUNDLE_ID` 可在本地配置中改为你自己的标识。不要复用其他开发者的 Team ID，也不要把证书、私钥或描述文件提交到仓库。

打开 `DeskKit.xcodeproj`，选择 DeskKit scheme 后构建；也可以执行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project DeskKit.xcodeproj -scheme DeskKit \
  -configuration Debug -derivedDataPath DerivedData build
python3 Scripts/install_local.py
```

安装脚本默认读取 `DerivedData/Build/Products/Debug/DeskKit.app`，安装到项目内的 `Build/DeskKit.app` 并打开。可通过 `--source` / `--destination` 指定其他位置。

签名身份由 Xcode/钥匙串提供，开源仓库不包含它。仅完成编译不代表桌面扩展能在别人的电脑运行。若共享容器不可用，应用仍保留菜单栏和编辑器。

## 实验包

```sh
python3 Scripts/package_experimental.py
```

脚本使用本机配置做优化构建，把 app、三个样例和说明文件打包为 `dist/DeskKit-experimental-YYYY-MM-DD-arm64.dmg`，同时生成样例 ZIP 和 SHA-256 校验文件。它不会安装、启动、上传或公证应用；`Release` 在这里仅是 Xcode 的编译配置。

若命令行工具未选中完整 Xcode，打包脚本会尝试 `/Applications/Xcode.app`；其他安装位置请通过 `DEVELOPER_DIR` 指定。它不会修改系统的 Xcode 选择。

此脚本生成 Apple Silicon 包；它会检查 app 与扩展的签名并排除调试符号、运行数据和扩展文件属性。公开签名后的包会公开证书身份与 Team ID；不要将其误认为匿名发布。

若要正常面向大众分发，应自行准备 Developer ID 签名和 Apple 公证。这里不提供绕过 Gatekeeper 或禁用系统保护的脚本。

## 维护资源

- `python3 Scripts/generate_project.py`：更新工程文件，个人签名仍从忽略的本地配置读取。
- `python3 Scripts/generate_app_icon.py`：从 Artwork 中的原图生成应用图标尺寸。
- `python3 Scripts/package_examples.py`：重新打包三个经过检查的样例。
- `Scripts/test.sh`：现有基础检查入口，需自行按环境运行。
