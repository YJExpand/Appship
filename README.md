# Appship

Appship 是一款面向 iOS 开发者的命令行自动化工具，旨在简化应用从构建、打包到内测分发的完整流程。

它支持自动构建和导出 IPA，并将应用上传至蒲公英（Pgyer）或 fir.im，同时提供 API Key、访问密码和项目配置管理。上传完成后，终端会输出应用版本、密码状态及下载链接，方便团队快速进行测试和分发。

### 构建耗时对比（构建机器： Apple M4 16gb）

```mermaid
gantt
    title IPA 构建耗时对比
    dateFormat X
    axisFormat %S 秒
    section 构建方式
    使用真机缓存包（39.91 秒） :cache, 0, 40
    重新构建（4 分 1.42 秒）    :rebuild, 0, 241
```

使用真机缓存包约 ​**39.91 秒**​，重新构建约 ​**4 分 1.42 秒**​，缓存模式约快 ​**6 倍**​。

## 安装

macOS 默认的 zsh 终端只需执行以下两条命令：

```bash
gem install appship
echo 'export PATH="$(ruby -rrubygems -e "print Gem.bindir"):$PATH"' >> ~/.zshrc && source ~/.zshrc
```

第二条命令只需执行一次：将 gem 的命令目录写入 `~/.zshrc`，并立即加载。以后重新打开终端，即可直接执行 `appship pgyer` 或 `appship fir`。

### 环境依赖

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
appship pgyer
或
appship fir
```

等待片刻...

配置保存在 `~/.appship/.config` 的数组中，`project_name` 对应当前目录的 `.xcodeproj` 或 `.xcworkspace` 名称，不包含后缀。切换项目后，工具会根据工程名匹配配置；如果没有匹配项，交互终端会直接进入首次配置引导，自动识别 `project_name`，依次输入 `app_name`、API Key 和可选密码。填写完成后自动追加到配置数组，保留已有项目，并继续构建流程。例如新增的配置项：

```json
{
  "project_name": "Demo",
  "app_name": "DemoApp",
  "pgyer_api_key": "your-api-key",
  "pgyer_password": ""
}
```

使用 fir.im 时，引导填写的字段为 `fir_api_key` 和 `fir_password`。使用 `--env-file` 时，新项目配置会保存到指定文件；非交互环境则提示手动补充配置。

首次运行 `appship` 时，会自动初始化 `~/.appship/.default_message`，用于蒲公英和 fir.im 发布成功后的消息输出。该文件只保存消息模板，不保存 API Key 或真实密码；由程序维护并设置为只读（`0444`），随内置模板更新，不作为用户可编辑配置。

```text
应用名称: Demo
应用类型: iOS
版本信息: 1.0.0(42)
更新描述: xxx
安装密码: 已设置
下载链接: https://fir.im/abc123
```

## 自定义发布消息

创建 `~/.appship/message.txt` 并在终端打印变量说明、示例和相关命令：

```bash
appship message init
```

已有的 `message.txt` 不会被初始化覆盖。文件开头的 `/* ... */` 是备注，下面才是发布时使用的正文。例如：

```text
🚀 %{name} 发布成功
版本：%{version_info}

更新内容：
%{description}

下载地址：%{url}
```

编辑当前模板：

```bash
appship message -e
```

优先使用 `VISUAL` 或 `EDITOR` 指定的编辑器；未设置时使用 macOS 默认文本编辑器。

使用指定文件覆盖当前模板（先校验内容，再替换文件）：

```bash
appship message -o /path/to/message.txt
```

支持的变量为 `name`、`build_type_name`、`version_info`、`configuration`、`build_size_mb`、`build_updated`、`description`、`password`、`url`，完整说明保存在文件备注中。`password` 在蒲公英中为安装密码，在 fir.im 中为密码设置状态。未获取到数据的字段会省略其所在行，建议将可选字段单独放在一行。正文只替换 `%{变量名}`，普通 `%` 原样保留，未知变量会在构建或上传前报错。

发布时优先使用 `message.txt`；文件不存在时使用 `.default_message`。升级内置模板不会覆盖用户的 `message.txt`。

## 其他用法

更换安装密码

```
appship pgyer -password xxx
或
appship fir -password xxx
```

更换上传秘钥

```
appship pgyer -key xxx
或
appship fir -key xxx
```

## 待办

```
1、补充消息机器人
2、其他分发平台
3、AI 接入git log ，自动归纳更新描述
4、优化命令
...
```
