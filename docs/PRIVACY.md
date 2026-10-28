# Privacy

**OCRFlow reads your files on your Mac and never uploads them.** Recognition,
layout analysis, the PaddleOCR-VL model, translation and search all run
locally. There are no accounts, no analytics and no tracking.

## What stays on your Mac

- The files you add, and everything recognised from them.
- The queue, results, corrections and recognition cache, kept in
  `~/Library/Application Support/OCRFlow/Library`.
- The history and its search index, in the same folder.
- Downloaded models, in `~/Library/Application Support/OCRFlow/Models`.

Removing an entry from the history, or choosing **Clear History**, deletes
what was kept for it. Deleting the `OCRFlow` folder above removes everything
the app has stored.

## When the app goes online

Only in these cases, and never with any of your files or text:

| When | Where | What is sent |
| --- | --- | --- |
| You download a model in the model manager | `huggingface.co`, or `hf-mirror.com` if you choose the mirror | An ordinary file download request |
| You open the model manager's source check | The same hosts | A request for one small file, to time the connection |
| Checking for updates (on by default, can be turned off in **Settings → Behavior → Software Update**) | `github.com` | A request for the update feed. No system profile is sent |
| Translation (macOS 15+) | Apple, through the system's Translation framework, only to download a language pack the first time a language pair is used | What Apple's framework sends for that download; the text itself is translated on the device |

## Problem reports

**Help → Report a Problem…** puts together a report that you review, then
copy or save yourself — the app never sends it. It contains the app and macOS
versions, your Mac model, your settings (folder paths left out), the names of
the downloaded models, and for each failed file its type, size, page count and
error. File names are left out unless you tick **Include file names**. The
contents of your files are never included.

If the app crashed the last time it ran, it offers to include the crash log
macOS wrote, with your home folder replaced by `~`.

---

# 隐私说明

**OCRFlow 在你的 Mac 上读取文件,从不上传。** 识别、版面分析、PaddleOCR-VL 模型、翻译和搜索全部在本机完成。没有账号,没有统计分析,没有追踪。

## 留在本机的数据

- 你添加的文件,以及从中识别出的全部内容。
- 队列、识别结果、修改记录和识别缓存,存放在 `~/Library/Application Support/OCRFlow/Library`。
- 历史记录及其搜索索引,也在同一个文件夹里。
- 下载的模型,存放在 `~/Library/Application Support/OCRFlow/Models`。

从历史记录里删除一条,或选择**清除历史记录**,会一并删除为它保存的数据。删除上面的 `OCRFlow` 文件夹,就会清除应用存储的全部数据。

## 应用什么时候会联网

只有下面几种情况,而且从不发送你的任何文件或文本:

| 情况 | 连接的地址 | 发送的内容 |
| --- | --- | --- |
| 在模型管理器里下载模型 | `huggingface.co`;如果选择了镜像,则是 `hf-mirror.com` | 普通的文件下载请求 |
| 在模型管理器里检测下载源 | 同上 | 请求一个小文件,用来测连接速度 |
| 检查更新(默认开启,可在**设置 → 行为 → 软件更新**里关闭) | `github.com` | 请求更新信息,不发送系统概况 |
| 翻译(macOS 15 及以上) | 通过系统的翻译框架连接 Apple,仅在第一次使用某个语言对时下载语言包 | Apple 框架为下载语言包发送的请求;文本本身在设备上翻译 |

## 问题报告

**帮助 → 报告问题…** 会生成一份报告。你先查看,再自己复制或保存,应用从不自动发送。报告包含:应用和 macOS 版本、Mac 机型、你的设置(不含文件夹路径)、已下载模型的名称,以及每个失败文件的类型、大小、页数和错误信息。除非你勾选**包含文件名**,否则不含文件名。文件内容永远不会包含在内。

如果应用上次运行时崩溃了,它会提示你附上 macOS 生成的崩溃日志,日志里的用户主目录会替换成 `~`。
