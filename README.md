# Appship

Appship 是一款面向 iOS 开发者的命令行自动化工具，旨在简化应用从构建、打包到内测分发的完整流程。

它支持自动构建和导出 IPA，并将应用上传至蒲公英（Pgyer）或 fir.im，同时提供 API Key、访问密码和项目配置管理。上传完成后，终端会输出应用版本、密码状态及下载链接，方便团队快速进行测试和分发。

### 构建耗时对比

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

```
gem install appship

export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
```

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

```
=======================================================
                   🎉 发布完成 🎉
=======================================================
分发平台: fir.im
应用名称: Demo
应用类型: iOS
版本信息: 1.0.0(42)
更新描述: xxx
访问密码: xxx
下载链接: https://fir.im/abc123
=======================================================
```

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
2、自定义消息格式
3、其他分发平台
...
```
