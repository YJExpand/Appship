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

配置保存在 `~/.appship/.config` 的数组中，`project_name` 对应当前目录的 `.xcodeproj` 或 `.xcworkspace` 名称，不包含后缀。切换项目后，工具会根据工程名匹配配置；如果没有匹配项，交互终端会直接进入首次配置引导，自动识别 `project_name`，依次输入 `app_name`、API Key 和可选密码。填写完成后自动追加到配置数组，保留已有项目，并继续构建流程。例如 fir.im 新增的配置项：

```json
{
  "project_name": "Demo",
  "app_name": "DemoApp",
  "pgyer_api_key":"your-pgyer-api-key",
  "pgyer_password": "",
  "fir_api_key": "your-fir-api-key",
  "fir_password": "",
  "wechat_webhook": "",
  "dingtalk_webhook": ""
}
```

使用 fir.im 时，引导填写的字段为 `fir_api_key` 和 `fir_password`。使用 `--env-file` 时，新项目配置会保存到指定文件；非交互环境则提示手动补充配置。

首次配置输入中断后，重新执行命令会再次进入引导；空配置数组 `[]` 也视为尚未配置。密码直接回车表示留空，输入结束或取消不会提交未完成的首次配置。

选择使用缓存时，找不到缓存 App 会直接报错退出，不会自动切换到重新构建。如需重新构建，请重新执行命令并选择对应模式。上传进度在服务端确认成功前最多显示 99%；上传失败时显示失败状态，不显示 100% 或“上传完成”。

蒲公英模式统一使用 `pgyer_api_key` 和 `pgyer_password`；fir.im 模式使用 `fir_api_key` 和 `fir_password`。两种模式分别读写自己的平台字段，密码可留空。不兼容或迁移 `api_key`、`password` 缓存字段。

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

## 发布结果通知机器人

`wechat_webhook`（企业微信）和 `dingtalk_webhook`（钉钉）都是可选字段，不填写或留空时不发送通知。在项目目录执行以下命令保存地址；URL 需要用引号包裹：

```bash
appship webhook wechat "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx"
appship webhook dingtalk "https://oapi.dingtalk.com/robot/send?access_token=xxx"
```

命令只修改当前项目对应的配置，不发送测试消息，也不要求填写 API Key。可使用 `--project-name NAME` 选择已配置的项目，或使用 `--env-file PATH`、`--project-dir PATH` 指定配置文件及工程目录。项目尚未配置时，请先执行 `appship pgyer` 或 `appship fir` 完成首次配置。

`appship pgyer` 或 `appship fir` 上传成功后，会向所有已配置的机器人发送与终端相同的发布消息，沿用 `message.txt` 或默认模板。不自动 @ 群成员；通知失败只输出警告，不影响已完成的发布。消息内容包括模板中的安装密码，请使用面向该应用测试人员的群。

发布流程发生异常时（配置校验、缓存查找、归档、导出、签名、上传或用户中断等），也会向当前项目已配置的每个机器人发送一次失败通知，包含应用名称、分发平台、构建配置和错误原因。失败通知使用固定格式，并隐藏 API Key、密码、Webhook 地址及 URL 查询参数。通知发送失败时只提示警告，保留原始异常，不递归发送其他失败通知。

如果配置文件无法读取、无法唯一匹配项目或没有配置 Webhook，则仅在终端报错，不会向其他项目的机器人发送消息。直接使用 `build`、`package`、`upload` 时，也可以在 `.appship.yml` 的 `upload` 部分配置 `wechat_webhook` 和 `dingtalk_webhook`。

关闭某个平台的通知：

```bash
appship webhook wechat ""
appship webhook dingtalk ""
```

当前发送普通文本消息。钉钉机器人需配置匹配消息内容的关键词或出口 IP 白名单；本次不包含动态加签密钥配置。Webhook 地址不会回显到终端，配置文件权限保持为 `0600`。

接口参考：[企业微信文本消息示例](https://cloud.tencent.com/document/product/1831/134518)、[钉钉机器人安全设置](https://open.dingtalk.com/document/robots/customize-robot-security-settings)。

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
