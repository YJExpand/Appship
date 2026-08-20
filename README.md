# appship

一个独立的 macOS 命令行工具，用于：

- 构建任意 Xcode workspace 或 project
- archive / export IPA
- 从已有 `.app` 打包 IPA
- 给 App Icon 添加 DEBUG、RELEASE 等环境角标
- 重新签名修改后的 App
- 上传 IPA/APK 到蒲公英或 fir.im

它不要求工程使用固定的项目名或目录结构。

## 安装

### 本地开发安装

```bash
gem build appship.gemspec
gem install ./appship-0.1.0.gem
```

如果不想安装 Gem，也可以直接运行：

```bash
./exe/appship --help
```

### 环境依赖

构建和签名功能需要 macOS、Xcode Command Line Tools，以及系统自带的：

```bash
xcodebuild xcrun codesign security zip unzip
```

如果需要图标角标，还需要 ImageMagick：

```bash
brew install imagemagick
```

检查环境：

```bash
appship doctor
```

## 快速开始

在 Xcode 工程目录执行：

```bash
appship init
```

编辑生成的 `.appship.yml`，然后执行：

```bash
appship build
```

也可以完全通过命令行指定工程：

```bash
appship build \
  --workspace MyApp.xcworkspace \
  --scheme MyApp \
  --configuration Debug \
  --output build/MyApp-Debug.ipa
```

使用 `.xcodeproj`：

```bash
appship build \
  --project MyApp.xcodeproj \
  --scheme MyApp \
  --configuration Release
```

## 图标角标

```bash
appship build \
  --workspace MyApp.xcworkspace \
  --scheme MyApp \
  --badge DEBUG \
  --assets MyApp/Assets.xcassets
```

工具会修改 `Assets.car`，并在修改后重新签名 App。签名身份默认沿用原 App 的证书；因此必须在有可用 Apple 签名身份的机器上执行。

如果已经有编译产物：

```bash
appship package \
  --app ~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug-iphoneos/MyApp.app \
  --output build/MyApp-Debug.ipa \
  --badge DEBUG \
  --assets MyApp/Assets.xcassets
```

## 上传蒲公英

不要把 API Key 写进仓库，建议使用环境变量：

```bash
export PGYER_API_KEY="your-api-key"
appship build --workspace MyApp.xcworkspace --scheme MyApp --upload
```

密码安装包：

```bash
export PGYER_INSTALL_PASSWORD="123456"
appship upload build/MyApp-Debug.ipa \
  --install-type 2 \
  --password-env PGYER_INSTALL_PASSWORD \
  --description "测试版本"
```

上传 IPA/APK 到蒲公英时，终端会显示实时上传进度、百分比和文件大小。

## 上传 fir.im

使用 fir.im API Token 上传已生成的 IPA/APK。IPA 会自动读取 Bundle ID、应用名称、版本号和 Build 号；如果无法读取，使用命令行参数补充：

```bash
export FIR_API_TOKEN="your-fir-api-token"
appship upload build/MyApp.ipa \
  --provider fir \
  --bundle-id com.example.MyApp \
  --description "测试版本"
```

也可以在构建或打包时直接上传：

```bash
FIR_API_TOKEN="$FIR_API_TOKEN" \
  appship build --workspace MyApp.xcworkspace --scheme MyApp \
  --export-method adhoc --provider fir --upload --bundle-id com.example.MyApp
```

fir.im 的 iOS 上传包需要使用 Ad Hoc 或 InHouse 签名；默认上传类型为 `Adhoc`，也可以通过 `--release-type Inhouse` 指定。图标不是必填项，如需更新 fir.im 应用图标可使用 `--icon path/to/icon.png`。

首次使用 `appship fir` 时还会引导填写 `fir_password`。密码为空表示公开访问；填写后 appship 会在上传完成后设置 fir.im 下载页的访客密码。也可以使用 `--fir-password-env FIR_PASSWORD` 指定环境变量。

更新 fir.im 缓存凭证：

```bash
appship fir -key new-fir-api-key -password new-password
```

蒲公英使用同样的写法：

```bash
appship pgyer -key new-pgyer-api-key -password new-password
```

如果希望使用和蒲公英相同的快捷命令，`appship fir` 会读取本机 `.config`，检查并补充 `fir_api_key`，然后默认采用 Ad Hoc 导出并上传 fir.im：

```bash
FIR_API_TOKEN="$FIR_API_TOKEN" \
  appship fir --workspace MyApp.xcworkspace --scheme MyApp
```

CI 示例：

```bash
PGYER_API_KEY="$PGYER_API_KEY" \
  appship --config .appship.ci.yml build \
  --upload \
  --description "CI ${GIT_COMMIT:0:8}"
```

## 常用命令

```text
appship init       创建配置模板
appship doctor     检查本机依赖
appship pgyer      读取本机缓存并构建、上传蒲公英
appship fir        构建并上传 fir.im
appship build      archive、export 并生成 IPA
appship package    将已有 .app 打包成 IPA
appship upload     上传已有 IPA/APK（蒲公英或 fir.im）
appship version    查看版本
```

## 安全建议

`.appship.yml` 只保存工程配置；上传命令的 API Key、fir.im Token 和安装密码通过环境变量传入，`appship pgyer` 使用本机私有缓存 `~/.appship/.config`。不要提交真实凭证、IPA 或 xcarchive。

## 一键发布蒲公英

安装后，在项目目录执行：

```bash
brew install appship
cd /path/to/your/project
appship pgyer
```

`appship pgyer` 默认从本机缓存 `~/.appship/.config` 读取项目配置。如果文件或目录不存在，工具会从当前目录唯一的 `.xcodeproj` 文件名自动获取 `project_name`，然后交互式引导填写 `app_name`、`pgyer_api_key` 和可选的 `pgyer_password`。密码为空时使用公开安装模式，不设置安装密码。如果找不到或存在多个 `.xcodeproj`，命令会直接报错。文件内容是 JSON 或 YAML 字典数组，例如：

每次执行 `appship pgyer` 都会检查当前项目缓存中的 `pgyer_api_key` 和 `pgyer_password`；如果缺失，会在交互终端中引导补填。`appship fir` 使用同样的机制检查并补填 `fir_api_key` 和 `fir_password`。

`appship pgyer` 生成的默认 IPA 会保存到 `~/.appship/build/`，也可以使用 `--output` 指定其他路径。

```json
[
  {
    "project_name": "MyApp",
    "app_name": "MyApp",
    "pgyer_api_key": "your-api-key",
    "pgyer_password": "qiahao"
  }
]
```

工具会根据 `project_name` 查找同名的 `.xcworkspace` 或 `.xcodeproj`，并使用同名 scheme。缓存包含多个项目时，可以指定：

```bash
appship pgyer --project-name MyApp
```

常用选项：

```bash
appship pgyer --cache                 # 复用 DerivedData 中已有的 .app
appship pgyer --rebuild --badge DEBUG # 重新构建并添加图标角标
appship pgyer --env-file ~/.appship/.config
appship pgyer --project-dir /path/to/project
```

在交互终端中，`appship pgyer` 会执行以下流程：选择使用缓存或重新构建；缓存模式会先输入更新内容，再显示动画查找 `.app`，找到后打包；重新构建模式会依次选择 Debug/Release、是否添加 Badge，再输入更新内容。缓存找不到时会自动回退到重新构建。

交互选择优先使用 `gum`，可以直接用上下键和回车选择。如果本机没有 `gum`，appship 会自动执行 `brew install gum`；只有 Homebrew 不存在或安装失败时，才回退到普通的 1/2 输入方式。
