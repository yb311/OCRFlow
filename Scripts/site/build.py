#!/usr/bin/env python3
"""Writes site/index.html and site/zh.html from template.html and the words here."""
import hashlib
import re
from pathlib import Path

HERE = Path(__file__).parent
SITE = HERE.parent.parent / 'site'
BASE = 'https://yb311.github.io/OCRFlow/'
DOWNLOAD = 'https://github.com/yb311/OCRFlow/releases/latest/download/OCRFlow.dmg'


def mark(cls='', paper='ip', front='if'):
    """The app icon, sheet for sheet as in OCRFlow/AppIcon.icon. A second copy on
    the same page needs its own gradient ids, or it would draw with the first's."""
    return f'''<svg {cls} viewBox="0 0 220 220" aria-hidden="true"><defs><linearGradient id="{paper}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F6F4EE"/><stop offset="1" stop-color="#E2E0D6"/></linearGradient><linearGradient id="{front}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#14665D"/><stop offset="1" stop-color="#07423B"/></linearGradient></defs><rect width="220" height="220" rx="50" fill="url(#{paper})"/><g transform="translate(110 110) scale(1.3) translate(-105.745 -109.497)"><g transform="translate(-9.816 1.908) rotate(-11 110 107)"><rect x="60" y="44" width="100" height="126" rx="12" fill="#6FA79C"/></g><g transform="translate(-1.995 .14) rotate(-4 110 109)"><rect x="60" y="46" width="100" height="126" rx="12" fill="#3C8578"/></g><g transform="rotate(4 116 113)"><rect x="64" y="48" width="104" height="130" rx="13" fill="url(#{front})"/><rect x="81" y="72" width="70" height="7" rx="3.5" fill="#8FF0D8"/><rect x="81" y="90" width="54.6" height="7" rx="3.5" fill="#8FF0D8" fill-opacity=".85"/><rect x="81" y="108" width="70" height="7" rx="3.5" fill="#8FF0D8" fill-opacity=".7"/><rect x="81" y="126" width="36.4" height="7" rx="3.5" fill="#8FF0D8" fill-opacity=".5"/></g></g></svg>'''


def icon(path, extra=''):
    return f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"{extra}>{path}</svg>'


ICONS = dict(
    apple='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11M7 11l5 5 5-5M5 20h14"/></svg>',
    playfill='<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"/></svg>',
    i_review=icon('<path d="M9 12l2 2 4-4"/><path d="M12 3l7 3v6c0 4-3 7-7 9-4-2-7-5-7-9V6z"/>'),
    i_search=icon('<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>'),
    i_search_small=icon('<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>'),
    i_export=icon('<path d="M12 15V4M8 8l4-4 4 4"/><path d="M5 13v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5"/>'),
    i_batch=icon('<rect x="7" y="7" width="13" height="13" rx="2"/><path d="M4 16V6a2 2 0 0 1 2-2h10"/>'),
    i_folder=icon('<path d="M3 7a2 2 0 0 1 2-2h4l2 3h8a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M12 11v5M9.5 13.5L12 11l2.5 2.5"/>'),
    i_translate=icon('<path d="M4 6h9M8.5 4v2M11 6c-.8 3.6-3.2 6.3-6.5 7.8M6 9c1 2 2.8 3.6 5 4.6"/><path d="M13 20l3.8-9L21 20M14.3 17h5.2"/>'),
    i_long=icon('<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M12 7v10M9 9.5L12 7l3 2.5M9 14.5l3 2.5 3-2.5"/>'),
    i_x=icon('<path d="M6 6l12 12M18 6L6 18"/>'),
    i_save=icon('<path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/>'),
    i_check=icon('<path d="M5 12.5l4.5 4.5L19 7.5"/>'),
    i_view=icon('<path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2"/>'),
    i_arrow=icon('<path d="M5 12h14M13 6l6 6-6 6"/>'),
)

LATIN = 'English Français Deutsch Español Italiano Português Nederlands Svenska Norsk Dansk Polski Čeština Română Türkçe Tiếng_Việt Bahasa_Indonesia'.split()
EXTRA = '한국어 العربية Русский ไทย Ελληνικά हिन्दी'.split()


def marquee(items):
    row = ''.join(f'<span>{w.replace("_", " ")}</span>' for w in items)
    return row * 2



EN = dict(
    lang='en', code='en', self='', other='zh.html', other_lang='zh-Hans', other_name='简体中文', main_shot='main-en.png',
    title='OCRFlow — Text recognition (OCR) for Mac',
    description='OCRFlow is a free Mac app that turns images, PDFs and anything on your screen into text you can copy and edit. Everything runs on your Mac and nothing is uploaded.',
    nav_label='Main', nav_jobs='What it does', nav_how='How to use it', nav_privacy='Privacy', nav_faq='FAQ',
    download_short='Download', download_long='Download for Mac', watch='See what it does',
    hero_title='Turn images, PDFs and anything on your screen into <em>text.</em>',
    hero_lede='OCRFlow is a text recognition (OCR) app for Mac. Free, runs entirely on your Mac, nothing uploaded.',
    fine='macOS 15 or later · Apple silicon and Intel · Open source',
    jobs_title='What you can do with it', jobs_have='You have', jobs_get='You get', jobs_use='Use',
    jobs=[
        ('Scans, photos or a PDF', 'Text you can copy and edit, with headings, paragraphs, tables and formulas kept apart', 'Recognize files', 'files'),
        ('A table in a picture', 'An Excel workbook, with merged cells kept', 'Recognize files', 'files'),
        ('A scanned PDF you cannot search', 'The same PDF with a searchable text layer', 'Recognize files', 'files'),
        ('Text you cannot select, in an app or on a website', 'The text itself: press a shortcut and drag over it', 'Screenshot', 'capture'),
        ('A web page longer than your screen', 'One long picture, and its text if you want it', 'Long screenshot', 'long'),
        ('Pages you turn one at a time', 'Each one taken with a drag, then one document', 'Queue Screenshots', 'queue'),
        ('A slide deck of 60 slides on the web', 'All of them taken for you, as one document', 'Record Actions', 'record'),
    ],
    s_label='Recognize files',
    s1_title='1. Drag files into the window', s1_text='PNG, JPEG, TIFF, BMP, GIF, HEIC, WebP and PDF. As many as you like, or whole folders.',
    s2_title='2. Click Start Recognition', s2_text='Headings, paragraphs, tables and formulas each become a numbered block, in reading order. Tables, formulas and layout need an optional download of about 1 GB, once.',
    s3_title='3. Check it, correct it, export it', s3_text='See the result as blocks, Markdown or plain text. Export it as Markdown, plain text, JSON, searchable PDF or Excel.',
    page_alt='A report being read, and turning into numbered blocks of text.',
    doc_title='Community Library Annual Report',
    doc_p1='Reading rooms stayed busy throughout the year. Visits rose in every quarter, and the new evening hours brought in many first-time members. Volunteers digitized the local newspaper archive.',
    doc_h1='Visits by quarter', doc_th=['Quarter', 'Visits', 'New members'], doc_h2='Next year',
    doc_p2='The library will extend weekend opening, add two study rooms, and continue scanning the photograph collection.',
    kinds=['Heading', 'Paragraph', 'Heading', 'Table', 'Formula', 'Heading', 'Paragraph'],
    main_alt='The OCRFlow window: a list of files, a report with its blocks numbered, and the title, paragraphs and table read from it.',
    main_cap='The OCRFlow window: your files, the page, and what was read from it.',
    cap_label='Screenshot', cap_title='Read anything on your screen',
    cap_lede='For text you cannot select: in an image, a video, a locked PDF, an app.',
    cap_steps=['Press <b>⌥⇧⌘2</b> in any app, or start from the menu bar or the floating button.', 'Drag out an area, or click a window.', 'Click <b>OCR</b> in the bar beside it to read the text. Or save the picture, or copy it.'],
    long_label='Long screenshot', long_title='Capture a page longer than your screen',
    long_lede='The pieces are joined into one picture, and you can see it grow as you go.',
    long_steps=['Take a screenshot as above, then click the long screenshot button in the bar.', 'Scroll by hand, or click <b>Auto Scroll</b>. Stop wherever you want it to end.', 'Click <b>OCR</b> to read it, or save or copy the picture.'],
    queue_label='Queue Screenshots', queue_title='Take many areas in a row',
    queue_lede='For a book or a document you turn yourself. No shortcut between one and the next.',
    queue_steps=['Choose <b>Queue Screenshots</b> from the menu bar icon.', 'Drag out an area to take it. Turn the page as usual, then drag again.', 'Press <b>Esc</b> and choose: one document, each on its own, only save, or discard.'],
    rec_label='Record Actions', rec_title='Do it once, and it repeats',
    rec_lede='It records your clicks, keys, typing and scrolls, then does them again. Works in any app or website.',
    rec_steps=['Choose <b>Record Actions…</b> from the menu bar icon.', 'Do it once. Click <b>Capture Here</b> where you want a screenshot, then turn the page, say. Click <b>Done</b>.', 'Choose how often it runs, and what the captures become. Click <b>Run</b>. Press Esc to stop.'],
    rec_d_steps='Steps', rec_d1='Capture an area of 1280 × 720', rec_d2='Press →', rec_d3='How often', rec_d4='Until the screen stops changing', rec_d5='Captures become', rec_d6='One document',
    more_title='Also in the app',
    t1_title='Flags what needs checking', t1_text='Regions are flagged with a reason: low confidence, output cut off, two readers disagreeing. Correct them in the Review view.',
    t2_title='Search everything you have read', t2_text='Every document stays in the history (⌘Y), searchable by any phrase, Chinese included.', t2_phrases='sixty years of stories|harbor and market square|annual report',
    t3_title='Export formats', t3_text='All in one file, or one per source with the folder structure kept. Choose the format in Settings.', plain_text='Plain text', searchable_pdf='Searchable PDF',
    t4_title='Batches', t4_text='Drop in a whole folder. The list and every result survive quitting, and a file already read is not read again.',
    t5_title='Watched folder', t5_text='Files that land in a folder you choose are read automatically, and the results exported for you.',
    t6_title='Translation', t6_text='Translate results on your Mac with Apple’s built-in translation.',
    lang_label='Languages',
    lang1_title='50 languages built in', lang1_text='Simplified and Traditional Chinese, English, Japanese and 46 Latin-script languages, ready straight away.',
    lang2_title='6 more scripts to install', lang2_text='Korean, Arabic, Cyrillic, Thai, Greek and Devanagari, one click each in the model manager.',
    lang3_title='Tables and formulas', lang3_text='Reading tables, formulas and complex layouts needs an optional download of about 1 GB. Plain text does not.',
    pri_title='Everything stays on your Mac',
    p1_title='Recognition runs locally', p1_text='Your files and text are never uploaded.',
    p2_title='No account, no analytics, no tracking', p2_text='Nothing to sign in to. This website has no trackers either.',
    p3_title='Online only for', p3_text='Models you choose to download, Apple’s translation language packs, and the update check, which you can turn off.',
    pri_link='Read the privacy statement', lock_alt='A padlock made of points of light.',
    videos_title='Videos',
    guide_title='How to use OCRFlow', guide_text='Two minutes, no sound. Every feature, step by step.', guide_play='Play',
    film_title='The film', film_text='48 seconds, with music.', film_play='Play with sound',
    faq_title='Questions',
    faq=[
        ('Is it really free?', 'Yes. OCRFlow is open source under the MIT license, with no account, subscription or limit.'),
        ('Which Macs does it run on?', 'macOS 15 Sequoia or later, on Apple silicon or Intel. Releases are signed and notarized by Apple, and update themselves.'),
        ('Why is there an optional 1 GB download?', 'Text in 50 languages works straight away, with the 69 MB app. The layout model and close reading, which handle tables, formulas and complex layouts, are about 1 GB, so you choose whether to add them.'),
        ('Why does it ask for permissions?', 'Screenshots need macOS’s Screen Recording permission. Record Actions, Queue Screenshots and Auto Scroll also need Accessibility, to follow and repeat your clicks and keys. It only watches while you record or capture.'),
        ('Does it record passwords?', 'Text typed during a recording is saved as typed, in the recording on your Mac, so avoid typing passwords while recording. Nothing is watched outside a recording or capture.'),
        ('Is it in the Mac App Store?', 'No. Download it here. It installs like any other Mac app and keeps itself up to date.'),
    ],
    end_title='Download OCRFlow',
    end_fine='Version 1.3.0 · 69 MB · macOS 15 or later', license='MIT License', footer_label='Links', releases='Releases', report='Report a problem',
)

ZH = dict(
    lang='zh-Hans', code='zh', self='zh.html', other='./', other_lang='en', other_name='English', main_shot='main-zh.png',
    title='OCRFlow — Mac 上的文字识别（OCR）软件',
    description='OCRFlow 是一款免费的 Mac 软件，把图片、PDF 和屏幕上的内容变成可以复制和编辑的文字。全部在本机运行，不上传任何内容。',
    nav_label='主导航', nav_jobs='能做什么', nav_how='怎么用', nav_privacy='隐私', nav_faq='常见问题',
    download_short='下载', download_long='下载 Mac 版', watch='看看能做什么',
    hero_title='把图片、PDF 和屏幕上的内容，变成<em>文字。</em>',
    hero_lede='OCRFlow 是一款 Mac 上的文字识别（OCR）软件。免费，全部在本机运行，不上传任何内容。',
    fine='macOS 15 或更高版本 · 支持 Apple 芯片和 Intel · 开源',
    jobs_title='它能帮你做什么', jobs_have='你手上有', jobs_get='你能得到', jobs_use='用这个功能',
    jobs=[
        ('扫描件、照片或 PDF', '可以复制和编辑的文字，标题、正文、表格和公式各归各位', '识别文件', 'files'),
        ('图片里的表格', 'Excel 表格，合并单元格也保留', '识别文件', 'files'),
        ('搜不了的扫描版 PDF', '同一份 PDF，加上可搜索的文字层', '识别文件', 'files'),
        ('软件或网页里选不中的文字', '按个快捷键、拖一下，文字就出来了', '截图', 'capture'),
        ('一屏放不下的长网页', '一张完整的长图，需要的话连文字一起', '长截图', 'long'),
        ('要一页一页翻的内容', '翻一页拖一下，最后合成一份文档', '队列截图', 'queue'),
        ('网页上 60 页的幻灯片', '自动一页页截完，合成一份文档', '录制操作', 'record'),
    ],
    s_label='识别文件',
    s1_title='1. 把文件拖进窗口', s1_text='支持 PNG、JPEG、TIFF、BMP、GIF、HEIC、WebP 和 PDF。可以一次拖入多个文件，或整个文件夹。',
    s2_title='2. 点“开始识别”', s2_text='标题、正文、表格和公式各分成一块，标上编号，按阅读顺序排好。表格、公式和版面分析需要下载一次约 1 GB 的模型（可选）。',
    s3_title='3. 校对、修改、导出', s3_text='结果可以按区块、Markdown 或纯文本查看，再导出成 Markdown、纯文本、JSON、可搜索 PDF 或 Excel。',
    page_alt='一份报告被读取，变成带编号的文字区块。',
    doc_title='社区图书馆年度报告',
    doc_p1='阅览室全年都很热闹。每个季度的到馆人次都在增长，新开放的夜间时段吸引了许多首次办证的读者。志愿者把本地报纸档案全部数字化。',
    doc_h1='各季度到馆人次', doc_th=['季度', '到馆人次', '新增读者'], doc_h2='明年计划',
    doc_p2='图书馆将延长周末开放时间，增设两间自习室，并继续扫描老照片馆藏。',
    kinds=['标题', '正文', '标题', '表格', '公式', '标题', '正文'],
    main_alt='OCRFlow 窗口：文件列表、标好区块编号的报告，以及从中识别出的标题、段落和表格。',
    main_cap='OCRFlow 的窗口：左边是文件，中间是页面，右边是识别结果。',
    cap_label='截图', cap_title='识别屏幕上的任何内容',
    cap_lede='用来对付选不中的文字：图片里的、视频里的、加密 PDF 里的、软件界面上的。',
    cap_steps=['在任何应用里按 <b>⌥⇧⌘2</b>，或者从菜单栏、悬浮按钮开始。', '拖出一个区域，或者点选一个窗口。', '点旁边操作栏里的 <b>OCR</b> 识别文字。也可以保存或拷贝这张图。'],
    long_label='长截图', long_title='截下比屏幕还长的页面',
    long_lede='滚动时自动拼成一张图，旁边能看到它一点点变长。',
    long_steps=['先按上面的方法截图，再点操作栏里的长截图按钮。', '自己滚动，或者点<b>自动滚动</b>。滚到哪里停，图就到哪里。', '点 <b>OCR</b> 识别，或者保存、拷贝这张图。'],
    queue_label='队列截图', queue_title='连续截取很多个区域',
    queue_lede='适合自己一页页翻的书和文档。每次之间不用按快捷键。',
    queue_steps=['点菜单栏图标，选<b>队列截图</b>。', '拖出区域就截取一张。照常翻页，再拖下一张。', '按 <b>Esc</b> 结束，然后选择：识别为一份文档、分别识别、只保存或丢弃。'],
    rec_label='录制操作', rec_title='做一遍，它来重复',
    rec_lede='录下你的点按、按键、输入和滚动，然后照做。任何应用和网站都能用。',
    rec_steps=['点菜单栏图标，选<b>录制操作…</b>', '照常做一遍。需要截图时点<b>截取此处</b>，比如截完再翻一页，然后点<b>完成</b>。', '选好执行次数和截图合成方式，点<b>运行</b>。按 Esc 可以随时停止。'],
    rec_d_steps='步骤', rec_d1='截取 1280 × 720 的区域', rec_d2='按 →', rec_d3='执行次数', rec_d4='直到屏幕不再变化', rec_d5='截图合成为', rec_d6='一份文档',
    more_title='还有这些功能',
    t1_title='标出需要复核的地方', t1_text='被标记的区域都写明原因：置信度低、输出被截断、两种识别结果不一致。可以在“复核”视图里修改。',
    t2_title='搜索读过的一切', t2_text='每份文档都留在历史记录里（⌘Y），可以按任意词句搜索，包括中文。', t2_phrases='六十多年来的报道|港口和旧市集广场|年度报告',
    t3_title='导出格式', t3_text='合并成一个文件，或者按来源分开并保留文件夹结构。格式在设置里选。', plain_text='纯文本', searchable_pdf='可搜索 PDF',
    t4_title='批量处理', t4_text='拖入整个文件夹。退出后列表和结果都还在，读过的文件不会再读一遍。',
    t5_title='监视文件夹', t5_text='放进指定文件夹的文件会被自动识别，结果也会替你导出。',
    t6_title='翻译', t6_text='用 Apple 内置的翻译，在你的 Mac 上翻译识别结果。',
    lang_label='语言',
    lang1_title='内置 50 种语言', lang1_text='简体和繁体中文、英文、日文，以及 46 种拉丁字母语言，装好就能用。',
    lang2_title='另外 6 种文字可安装', lang2_text='韩文、阿拉伯文、西里尔文、泰文、希腊文和德瓦那加里文，在模型管理器里一键安装。',
    lang3_title='表格和公式', lang3_text='识别表格、公式和复杂版面，需要下载约 1 GB 的模型（可选）。只识别普通文字不需要。',
    pri_title='所有内容都留在你的 Mac 上',
    p1_title='识别在本机完成', p1_text='你的文件和文字从不上传。',
    p2_title='没有账号，没有统计，没有追踪', p2_text='不需要登录。这个网站同样没有追踪器。',
    p3_title='只有这些时候联网', p3_text='下载你选择的模型、Apple 的翻译语言包，以及检查更新（可以关闭）。',
    pri_link='阅读隐私说明', lock_alt='由光点组成的一把锁。',
    videos_title='视频',
    guide_title='OCRFlow 使用说明', guide_text='两分钟，无声。每个功能一步步演示。', guide_play='播放',
    film_title='宣传短片', film_text='48 秒，有音乐。', film_play='有声播放',
    faq_title='常见问题',
    faq=[
        ('真的免费吗？', '是的。OCRFlow 以 MIT 许可证开源，没有账号、订阅或使用限制。'),
        ('支持哪些 Mac？', 'macOS 15 Sequoia 或更高版本，支持 Apple 芯片和 Intel。每个版本都经过签名和 Apple 公证，并且可以自动更新。'),
        ('为什么有一个约 1 GB 的可选下载？', '69 MB 的应用本身就能识别 50 种语言的文字。处理表格、公式和复杂版面需要版面模型和仔细识别模型，约 1 GB，要不要下载由你决定。'),
        ('为什么需要这些权限？', '截图需要 macOS 的“录屏”权限。录制操作、队列截图和自动滚动还需要“辅助功能”权限，用来跟随和重复你的点按和按键。只有在录制或截图期间才会读取你的操作。'),
        ('会录下密码吗？', '录制时输入的文字会原样保存在你 Mac 上的录制内容里，所以录制时请不要输入密码。录制和截图之外，不会读取你的任何操作。'),
        ('Mac App Store 里有吗？', '没有。请在这里下载。它和其他 Mac 应用一样安装，并且会自动更新。'),
    ],
    end_title='下载 OCRFlow',
    end_fine='版本 1.3.0 · 69 MB · macOS 15 或更高版本', license='MIT 许可证', footer_label='链接', releases='版本发布', report='报告问题',
)


def doc(w, blocks):
    n = iter(range(1, 8))

    def wrap(html):
        return f'<div class="blk" data-n="{next(n)}">{html}</div>' if blocks else html

    rows = [['Q1', '18,240', '312'], ['Q2', '19,875', '401'], ['Q3', '21,330', '458'], ['Q4', '23,160', '526']]
    head = ''.join(f'<th>{h}</th>' for h in w['doc_th'])
    body = ''.join('<tr>' + ''.join(f'<td>{c}</td>' for c in r) + '</tr>' for r in rows)
    return ''.join([
        wrap(f'<p class="doc-title">{w["doc_title"]}</p>'),
        wrap(f'<p class="doc-p">{w["doc_p1"]}</p>'),
        wrap(f'<p class="doc-h">{w["doc_h1"]}</p>'),
        wrap(f'<table class="doc-table"><tr>{head}</tr>{body}</table>'),
        wrap('<p class="doc-f">(23,160 − 18,240) ÷ 18,240 = 27%</p>'),
        wrap(f'<p class="doc-h">{w["doc_h2"]}</p>'),
        wrap(f'<p class="doc-p">{w["doc_p2"]}</p>'),
    ])


def results(w):
    rows = [['Q1', '18,240', '312'], ['Q2', '19,875', '401'], ['Q3', '21,330', '458'], ['Q4', '23,160', '526']]
    head = ''.join(f'<th>{h}</th>' for h in w['doc_th'])
    body = ''.join('<tr>' + ''.join(f'<td>{c}</td>' for c in r) + '</tr>' for r in rows)
    inner = [
        f'<h3>{w["doc_title"]}</h3>',
        f'<p>{w["doc_p1"]}</p>',
        f'<h3>{w["doc_h1"]}</h3>',
        f'<table><tr>{head}</tr>{body}</table>',
        '<code>(23,160 − 18,240) ÷ 18,240 = 27%</code>',
        f'<h3>{w["doc_h2"]}</h3>',
        f'<p>{w["doc_p2"]}</p>',
    ]
    return ''.join(f'<div class="result"><small><b>{i + 1}</b>{w["kinds"][i]}</small>{html}</div>' for i, html in enumerate(inner))


def stamp(name):
    """A short hash of a file, put in its address so browsers fetch it again once it changes."""
    return hashlib.sha1((SITE / name).read_bytes()).hexdigest()[:8]


def page(w):
    values = dict(w)
    values.update(ICONS)
    values.update(
        v_css=stamp('style.css'), v_js=stamp('site.js'),
        base=BASE, download=DOWNLOAD, mark=mark(), mark_large=mark('class="mark rise"', 'mp', 'mf'),
        doc_plain=doc(w, False), doc_blocks=doc(w, True), results=results(w),
        marquee_a=marquee(['中文', '繁體中文', '日本語'] + LATIN), marquee_b=marquee(EXTRA * 3),
        faq=''.join(f'<details><summary>{q}</summary><p>{a}</p></details>' for q, a in w['faq']),
        jobs=''.join(f'<a class="job" role="row" href="#{to}"><span role="cell">{have}</span><span role="cell">{get}</span><span role="cell"><b>{use}</b></span></a>' for have, get, use, to in w['jobs']),
        cap_steps=''.join(f'<li><span>{x}</span></li>' for x in w['cap_steps']),
        long_steps=''.join(f'<li><span>{x}</span></li>' for x in w['long_steps']),
        queue_steps=''.join(f'<li><span>{x}</span></li>' for x in w['queue_steps']),
        rec_steps=''.join(f'<li><span>{x}</span></li>' for x in w['rec_steps']),
    )
    html = (HERE / 'template.html').read_text(encoding='utf-8')
    html = re.sub(r'\{\{(\w+)\}\}', lambda m: str(values[m.group(1)]), html)
    (SITE / ('index.html' if w['code'] == 'en' else 'zh.html')).write_text(html, encoding='utf-8')


for words in (EN, ZH):
    page(words)
(SITE / 'icon.svg').write_text(mark('xmlns="http://www.w3.org/2000/svg"'), encoding='utf-8')
print('wrote site/index.html, site/zh.html, site/icon.svg')
