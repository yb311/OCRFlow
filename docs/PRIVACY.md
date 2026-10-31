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
- Screenshots, in the `Screenshots` folder inside `Library`. Capturing needs
  macOS's Screen Recording permission; the app looks at the screen only when
  you capture.
- For **Record Actions**, the steps you record — clicks, key presses, text you
  type, scrolls, the names of buttons you click and the windows they are in —
  are saved in `Macros.json` inside `Library` until you delete the macro, and
  repeated with the Accessibility permission. What you capture while
  recording waits in `Macro Captures` beside it until the macro next runs, or
  until you delete that step. They are watched only between
  starting a recording and clicking Done or Cancel. Text typed while recording
  is saved as typed, so avoid recording passwords.

Removing an entry from the history deletes its text and result. **Clear
History** deletes all of them, and the recognition cache too. Deleting the
`OCRFlow` folder above removes everything the app has stored.

## When the app goes online

Only in these cases, and never with any of your files or text:

| When | Where | What is sent |
| --- | --- | --- |
| You download a model in the model manager | `huggingface.co`, or `hf-mirror.com` if you choose the mirror | An ordinary file download request |
| You open the model manager's source check | The same hosts | A request for one small file, to time the connection |
| Checking for updates (on by default, can be turned off in **Settings → Behavior → Software Update**) | `github.com` | A request for the update feed. No system profile is sent |
| Translation | Apple, through the system's Translation framework, only to download a language pack the first time a language pair is used | What Apple's framework sends for that download; the text itself is translated on the device |

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
- 截图,存放在 `Library` 里的 `Screenshots` 文件夹。截图需要 macOS 的“录屏”权限;只有在你截图时,应用才会读取屏幕。
- 使用**录制操作**时,你录下的步骤——点按、按键、输入的文字、滚动,以及点按的按钮名称和所在窗口——保存在 `Library` 里的 `Macros.json`,直到你删除这个操作为止,并借助“辅助功能”权限重复执行。录制时截的图存放在旁边的 `Macro Captures` 文件夹里,下次运行这个操作时取用,或者在你删除那一步时一起删除。只有从开始录制到点按“完成”或“取消”的这段时间才会记录。录制时输入的文字会原样保存,请不要录制密码。

从历史记录里删除一条,会删除它的文字和识别结果。**清除历史记录**会删除全部记录,连同识别缓存一起清空。删除上面的 `OCRFlow` 文件夹,就会清除应用存储的全部数据。

## 应用什么时候会联网

只有下面几种情况,而且从不发送你的任何文件或文本:

| 情况 | 连接的地址 | 发送的内容 |
| --- | --- | --- |
| 在模型管理器里下载模型 | `huggingface.co`;如果选择了镜像,则是 `hf-mirror.com` | 普通的文件下载请求 |
| 在模型管理器里检测下载源 | 同上 | 请求一个小文件,用来测连接速度 |
| 检查更新(默认开启,可在**设置 → 行为 → 软件更新**里关闭) | `github.com` | 请求更新信息,不发送系统概况 |
| 翻译 | 通过系统的翻译框架连接 Apple,仅在第一次使用某个语言对时下载语言包 | Apple 框架为下载语言包发送的请求;文本本身在设备上翻译 |

## 问题报告

**帮助 → 报告问题…** 会生成一份报告。你先查看,再自己复制或保存,应用从不自动发送。报告包含:应用和 macOS 版本、Mac 机型、你的设置(不含文件夹路径)、已下载模型的名称,以及每个失败文件的类型、大小、页数和错误信息。除非你勾选**包含文件名**,否则不含文件名。文件内容永远不会包含在内。

如果应用上次运行时崩溃了,它会提示你附上 macOS 生成的崩溃日志,日志里的用户主目录会替换成 `~`。
