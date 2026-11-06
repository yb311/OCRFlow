#!/usr/bin/env python3
"""Writes site/index.html and site/zh.html from template.html and the words here."""
import re
from pathlib import Path

HERE = Path(__file__).parent
SITE = HERE.parent.parent / 'site'
BASE = 'https://yb311.github.io/OCRFlow/'
DOWNLOAD = 'https://github.com/yb311/OCRFlow/releases/latest/download/OCRFlow.dmg'


def mark(cls=''):
    """The app icon, sheet for sheet as in OCRFlow/AppIcon.icon."""
    return f'''<svg {cls} viewBox="0 0 220 220" aria-hidden="true"><defs><linearGradient id="ip" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F6F4EE"/><stop offset="1" stop-color="#E2E0D6"/></linearGradient><linearGradient id="if" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#14665D"/><stop offset="1" stop-color="#07423B"/></linearGradient></defs><rect width="220" height="220" rx="50" fill="url(#ip)"/><g transform="translate(110 110) scale(1.3) translate(-105.745 -109.497)"><g transform="translate(-9.816 1.908) rotate(-11 110 107)"><rect x="60" y="44" width="100" height="126" rx="12" fill="#6FA79C"/></g><g transform="translate(-1.995 .14) rotate(-4 110 109)"><rect x="60" y="46" width="100" height="126" rx="12" fill="#3C8578"/></g><g transform="rotate(4 116 113)"><rect x="64" y="48" width="104" height="130" rx="13" fill="url(#if)"/><rect x="81" y="72" width="70" height="7" rx="3.5" fill="#8FF0D8"/><rect x="81" y="90" width="54.6" height="7" rx="3.5" fill="#8FF0D8" fill-opacity=".85"/><rect x="81" y="108" width="70" height="7" rx="3.5" fill="#8FF0D8" fill-opacity=".7"/><rect x="81" y="126" width="36.4" height="7" rx="3.5" fill="#8FF0D8" fill-opacity=".5"/></g></g></svg>'''


def icon(path, extra=''):
    return f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"{extra}>{path}</svg>'


ICONS = dict(
    apple='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11M7 11l5 5 5-5M5 20h14"/></svg>',
    playicon='<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"/></svg>',
    playfill='<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"/></svg>',
    i_review=icon('<path d="M9 12l2 2 4-4"/><path d="M12 3l7 3v6c0 4-3 7-7 9-4-2-7-5-7-9V6z"/>'),
    i_search=icon('<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>'),
    i_search_small=icon('<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>'),
    i_export=icon('<path d="M12 15V4M8 8l4-4 4 4"/><path d="M5 13v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5"/>'),
    i_batch=icon('<rect x="7" y="7" width="13" height="13" rx="2"/><path d="M4 16V6a2 2 0 0 1 2-2h10"/>'),
    i_folder=icon('<path d="M3 7a2 2 0 0 1 2-2h4l2 3h8a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M12 11v5M9.5 13.5L12 11l2.5 2.5"/>'),
    i_translate=icon('<path d="M4 6h9M8.5 4v2M11 6c-.8 3.6-3.2 6.3-6.5 7.8M6 9c1 2 2.8 3.6 5 4.6"/><path d="M13 20l3.8-9L21 20M14.3 17h5.2"/>'),
)

LATIN = 'English Français Deutsch Español Italiano Português Nederlands Svenska Norsk Dansk Polski Čeština Română Türkçe Tiếng_Việt Bahasa_Indonesia'.split()
EXTRA = '한국어 العربية Русский ไทย Ελληνικά हिन्दी'.split()


def marquee(items):
    row = ''.join(f'<span>{w.replace("_", " ")}</span>' for w in items)
    return row * 2


EN = dict(
    lang='en', code='en', self='', other='zh.html', other_lang='zh-Hans', other_name='简体中文', main_shot='main-en.png',
    title='OCRFlow — Everything on your screen is text',
    description='OCRFlow turns scans, PDFs and anything on your screen into text you can search and edit. Free for Mac. Recognition runs on your Mac and nothing is uploaded.',
    nav_label='Main', nav_film='Film', nav_read='Reading', nav_capture='Capture', nav_record='Record', nav_privacy='Privacy',
    download_short='Download', download_long='Download for Mac', watch='Watch the film',
    hero_title='Everything on your screen is <em>text.</em>',
    hero_lede='Read scans and PDFs by the folder, capture from any app, or show OCRFlow once how to turn a page and let it assemble the whole document.',
    fine='Free and open source · macOS 15 or later · Apple silicon and Intel · Signed and notarized',
    main_alt='The OCRFlow window: a report with its blocks numbered on one side, and the title, paragraphs and table read from it on the other.',
    main_cap='The app itself, reading a made-up report.',
    film_eyebrow='The film', film_title='Forty-eight seconds, in light.', film_play='Play with sound',
    s1_eyebrow='Reading', s1_title='A page is more than lines of text.', s1_text='Keep scrolling. This one is being read as you go.',
    s2_eyebrow='Layout', s2_title='It finds the structure first.', s2_text='Headings, paragraphs, tables and formulas each get their own block, in reading order.',
    s3_eyebrow='Results', s3_title='Then every block is real, usable text.', s3_text='Tables stay tables and formulas stay formulas. Check it, correct it, export it.',
    page_alt='A report being read by a line of light, and turning into structured text.',
    doc_title='Community Library Annual Report',
    doc_p1='Reading rooms stayed busy throughout the year. Visits rose in every quarter, and the new evening hours brought in many first-time members. Volunteers digitized the local newspaper archive.',
    doc_h1='Visits by quarter', doc_th=['Quarter', 'Visits', 'New members'], doc_h2='Next year',
    doc_p2='The library will extend weekend opening, add two study rooms, and continue scanning the photograph collection.',
    kinds=['Heading', 'Paragraph', 'Heading', 'Table', 'Formula', 'Heading', 'Paragraph'],
    cap_eyebrow='Capture', cap_title='Take it from anywhere.',
    cap_lede='A capture engine built for reading. OCRFlow stays out of the way: it never comes forward, so the window you are capturing looks exactly as it did.',
    cap1_title='Choose it. Read it.', cap1_text='Press the shortcut in any app, drag out an area or click a window, and pick from the bar beside it: recognize, long screenshot, save or copy.',
    cap1_alt='An area of an article is chosen on screen, and its text is read.',
    cap2_title='Long screenshots', cap2_text='Scroll by hand or let Auto Scroll do it. The joined picture grows beside the page as you go, and is read as pages so small text stays sharp.',
    cap2_alt='A long page joined into one continuous ribbon.',
    cap3_title='Queue Screenshots', cap3_text='Drag out area after area, with no shortcut in between, turning pages as usual. Esc ends it.',
    cap4_title='Always one click away', cap4_text='A small button floats above every window. Click it to capture; point at it and Queue Screenshots and Record Actions open out. Or start from the menu bar, even with the main window closed.',
    rec_eyebrow='Record Actions', rec_title='Show it once. It does the rest.',
    rec_lede='Clicks, keys, typing, scrolls, captures: whatever you do, OCRFlow can repeat. It knows nothing about any particular app or site, so it works with all of them.',
    rec_alt='A slide is captured and the next one brought up, again and again, until the whole deck has been taken.',
    rec1_title='Do it once', rec1_text='Capture a slide and press →, say. Every step can be edited afterwards.',
    rec2_title='It repeats', rec2_text='A set number of times, or until the screen stops changing, and optionally on each of a list of web addresses.',
    rec3_title='You get the result', rec3_text='One document, one long picture or separate pictures, recognized when it ends. Or only saved.',
    eng_eyebrow='Smart Layering', eng_title='The right reader for each part of the page.',
    eng_lede='Fast where the page is simple, careful where it is not. You do not have to choose.',
    eng_from_title='Every page', eng_from_text='A PDF with trustworthy text of its own keeps it as it is. Anything else is split into regions by the layout model.',
    r1_name='Quick reading', r1_small='PP-OCRv6', r1_text='Prose and ordinary text, quickly. Built in, and offline from the first moment.',
    r2_name='Close reading', r2_small='PaddleOCR-VL-1.6', r2_text='Tables, formulas, charts and seals, and any region quick reading is unsure of.',
    r3_name='Apple Vision', r3_small='Also available', r3_text='Choose it, or either reader alone, whenever you prefer.',
    t1_title='Review what deserves a look', t1_text='Regions are flagged with a specific reason: low confidence, output cut off, two readers disagreeing. Your corrections are never overwritten without asking.',
    t2_title='Search everything you have read', t2_text='Every document stays in the history, searchable by any phrase, Chinese included.', t2_phrases='sixty years of stories|harbor and market square|annual report',
    t3_title='Export it your way', t3_text='Combined into one file, or one per source with the folder structure kept.', plain_text='Plain text', searchable_pdf='Searchable PDF',
    t4_title='Whole folders at once', t4_text='Drop in images, PDFs or folders. The list and every result survive quitting, and nothing is read twice.',
    t5_title='A folder that reads itself', t5_text='Files that land in a watched folder are read once they finish copying, and the results are exported for you.',
    t6_title='Translate on the device', t6_text='Results can be translated with Apple’s Translation framework. The text is translated on your Mac.',
    lang_label='Languages',
    lang1_title='Fifty languages, built in', lang1_text='Simplified and Traditional Chinese, English, Japanese and 46 Latin-script languages, read by one model that ships inside the app.',
    lang2_title='Six more scripts, one click away', lang2_text='Korean, Arabic, Cyrillic, Thai, Greek and Devanagari install from the model manager.',
    pri_eyebrow='Privacy', pri_title='It stays on your Mac.',
    p1_title='Recognition runs locally', p1_text='Layout analysis, both readers, translation and search all happen on your Mac. Your files and text are never uploaded.',
    p2_title='No accounts, analytics or tracking', p2_text='There is nothing to sign in to, and nothing is watching what you do. This website has no trackers either.',
    p3_title='Online only when it has to be', p3_text='For models you choose to download, Apple’s translation language packs, and the update check, which you can turn off. Never with your files or text.',
    pri_link='Read the privacy statement', lock_alt='A padlock made of points of light.',
    faq_title='Good questions',
    faq=[
        ('Is it really free?', 'Yes. OCRFlow is open source under the MIT license, with no account, subscription or limit.'),
        ('Which Macs does it run on?', 'macOS 15 Sequoia or later, on Apple silicon or Intel. Releases are signed and notarized by Apple, and update themselves.'),
        ('Why is there an optional 1 GB download?', 'Text in 50 languages works straight away, with the 69 MB app. The layout model and close reading, which handle tables, formulas and complex layouts, are about 1 GB, so you choose whether to add them.'),
        ('Why does it ask for permissions?', 'Screenshots need macOS’s Screen Recording permission. Record Actions, Queue Screenshots and Auto Scroll also need Accessibility, to follow and repeat your clicks and keys. It only watches while you record or capture.'),
        ('Does it record passwords?', 'Text typed during a recording is saved as typed, in the recording on your Mac, so avoid typing passwords while recording. Nothing is watched outside a recording or capture.'),
        ('Is it in the Mac App Store?', 'No. Download it here. It installs like any other Mac app and keeps itself up to date.'),
    ],
    end_title='Your screen is full of words.', end_lede='Now they can all be yours.',
    end_fine='Version 1.3.0 · 69 MB · macOS 15 or later', license='MIT License', footer_label='Links', releases='Releases', report='Report a problem',
)

ZH = dict(
    lang='zh-Hans', code='zh', self='zh.html', other='./', other_lang='en', other_name='English', main_shot='main-zh.png',
    title='OCRFlow — 屏幕上的一切，都是文字',
    description='OCRFlow 把扫描件、PDF 和屏幕上的任何内容变成可以搜索、编辑的文字。Mac 版免费。识别全部在你的 Mac 上完成，不上传任何内容。',
    nav_label='主导航', nav_film='短片', nav_read='识别', nav_capture='截图', nav_record='录制', nav_privacy='隐私',
    download_short='下载', download_long='下载 Mac 版', watch='观看短片',
    hero_title='屏幕上的一切，<br>都是<em>文字。</em>',
    hero_lede='成批识别扫描件和 PDF，在任何应用里截图，或者演示一次翻页，让 OCRFlow 替你整理出完整的文档。',
    fine='免费开源 · macOS 15 或更高版本 · 支持 Apple 芯片和 Intel · 已签名并通过 Apple 公证',
    main_alt='OCRFlow 窗口：一侧是标好区块编号的报告，另一侧是从中识别出的标题、段落和表格。',
    main_cap='这就是应用本身，正在识别一份虚构的报告。',
    film_eyebrow='短片', film_title='48 秒，一道光。', film_play='有声播放',
    s1_eyebrow='识别', s1_title='一页文档，不只是几行字。', s1_text='继续往下滚动。这一页正随着你的滚动被读取。',
    s2_eyebrow='版面', s2_title='先看懂结构。', s2_text='标题、正文、表格和公式各成一块，并按阅读顺序排好。',
    s3_eyebrow='结果', s3_title='每一块，都是能直接用的文字。', s3_text='表格还是表格，公式还是公式。校对、修改，然后导出。',
    page_alt='一道光读过一份报告，报告变成结构化的文字。',
    doc_title='社区图书馆年度报告',
    doc_p1='阅览室全年都很热闹。每个季度的到馆人次都在增长，新开放的夜间时段吸引了许多首次办证的读者。志愿者把本地报纸档案全部数字化。',
    doc_h1='各季度到馆人次', doc_th=['季度', '到馆人次', '新增读者'], doc_h2='明年计划',
    doc_p2='图书馆将延长周末开放时间，增设两间自习室，并继续扫描老照片馆藏。',
    kinds=['标题', '正文', '标题', '表格', '公式', '标题', '正文'],
    cap_eyebrow='截图', cap_title='从任何地方取得文字。',
    cap_lede='一套为识别而做的截图引擎。OCRFlow 不会打扰你：它从不跳到前台，你截的窗口始终保持原样。',
    cap1_title='选中，就能读。', cap1_text='在任何应用里按下快捷键，拖出区域或点选窗口，然后在旁边的操作栏里选择：识别、长截图、保存或拷贝。',
    cap1_alt='在屏幕上选中一段文章，读出其中的文字。',
    cap2_title='长截图', cap2_text='手动滚动，或者交给自动滚动。拼接结果在页面旁边实时变长，并按页识别，小字也能保持清晰。',
    cap2_alt='一个长页面拼接成连续的长条。',
    cap3_title='队列截图', cap3_text='一次又一次拖出区域，中间不用按快捷键，照常翻页就行。按 Esc 结束。',
    cap4_title='随时一键可达', cap4_text='一个小按钮浮在所有窗口之上。点按即可截图，鼠标移上去还会展开队列截图和录制操作。也可以从菜单栏开始，主窗口关着也行。',
    rec_eyebrow='录制操作', rec_title='演示一次，剩下的交给它。',
    rec_lede='点按、按键、输入、滚动、截图，你做过的都能重复。它不针对任何特定的应用或网站，所以哪里都能用。',
    rec_alt='截下一张幻灯片，翻到下一张，一遍又一遍，直到整份幻灯片都截完。',
    rec1_title='做一遍', rec1_text='比如截一张幻灯片，再按 →。之后每一步都可以修改。',
    rec2_title='它来重复', rec2_text='按设定的次数，或者一直到屏幕不再变化，还可以依次处理一组网址。',
    rec3_title='拿到结果', rec3_text='一份文档、一张长图或多张单独的图片，结束后自动识别。也可以只保存。',
    eng_eyebrow='智能分层', eng_title='页面的每个部分，都交给合适的读取方式。',
    eng_lede='简单的地方快，复杂的地方细。你不需要自己选。',
    eng_from_title='每一页', eng_from_text='自带可靠文字的 PDF 直接使用原有文字。其余页面由版面模型划分成多个区域。',
    r1_name='快速读取', r1_small='PP-OCRv6', r1_text='正文和普通文字，读得很快。内置在应用里，一开始就能离线使用。',
    r2_name='精读', r2_small='PaddleOCR-VL-1.6', r2_text='表格、公式、图表和印章，以及快速读取拿不准的区域。',
    r3_name='Apple Vision', r3_small='也可以选用', r3_text='想用时可以选它，也可以单独使用上面任一种。',
    t1_title='标出值得复核的地方', t1_text='每个被标记的区域都写明原因：置信度低、输出被截断、两种读取结果不一致。你的修改不会在未询问时被覆盖。',
    t2_title='搜索读过的一切', t2_text='每份文档都留在历史记录里，可以按任意词句搜索，包括中文。', t2_phrases='六十多年来的报道|港口和旧市集广场|年度报告',
    t3_title='按你的方式导出', t3_text='合并成一个文件，或者按来源分开并保留文件夹结构。', plain_text='纯文本', searchable_pdf='可搜索 PDF',
    t4_title='整个文件夹一起来', t4_text='拖入图片、PDF 或文件夹。退出后列表和结果都还在，同样的内容不会读第二遍。',
    t5_title='会自己读取的文件夹', t5_text='放进监视文件夹的文件，复制完成后会被自动识别，结果也会替你导出。',
    t6_title='在设备上翻译', t6_text='可以用 Apple 的翻译框架，在你的 Mac 上翻译识别结果。',
    lang_label='语言',
    lang1_title='内置 50 种语言', lang1_text='简体和繁体中文、英文、日文，以及 46 种拉丁字母语言，由应用内置的同一个模型读取。',
    lang2_title='另外 6 种文字，一键安装', lang2_text='韩文、阿拉伯文、西里尔文、泰文、希腊文和德瓦那加里文，可以在模型管理器里安装。',
    pri_eyebrow='隐私', pri_title='所有数据都留在你的 Mac 上。',
    p1_title='识别在本机完成', p1_text='版面分析、两种读取方式、翻译和搜索都在你的 Mac 上进行。你的文件和文字从不上传。',
    p2_title='没有账号，没有统计，没有追踪', p2_text='不需要登录，也没有东西在观察你的操作。这个网站同样没有追踪器。',
    p3_title='只在必要时联网', p3_text='下载你选择的模型、Apple 的翻译语言包，以及检查更新（可以关闭）。从不发送你的文件或文字。',
    pri_link='阅读隐私说明', lock_alt='由光点组成的一把锁。',
    faq_title='常见问题',
    faq=[
        ('真的免费吗？', '是的。OCRFlow 以 MIT 许可证开源，没有账号、订阅或使用限制。'),
        ('支持哪些 Mac？', 'macOS 15 Sequoia 或更高版本，支持 Apple 芯片和 Intel。每个版本都经过签名和 Apple 公证，并且可以自动更新。'),
        ('为什么有一个约 1 GB 的可选下载？', '69 MB 的应用本身就能识别 50 种语言的文字。处理表格、公式和复杂版面需要版面模型和精读模型，约 1 GB，要不要下载由你决定。'),
        ('为什么需要这些权限？', '截图需要 macOS 的“录屏”权限。录制操作、队列截图和自动滚动还需要“辅助功能”权限，用来跟随和重复你的点按和按键。只有在录制或截图期间才会读取你的操作。'),
        ('会录下密码吗？', '录制时输入的文字会原样保存在你 Mac 上的录制内容里，所以录制时请不要输入密码。录制和截图之外，不会读取你的任何操作。'),
        ('Mac App Store 里有吗？', '没有。请在这里下载。它和其他 Mac 应用一样安装，并且会自动更新。'),
    ],
    end_title='你的屏幕上全是文字。', end_lede='现在，它们都可以为你所用。',
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


def page(w):
    values = dict(w)
    values.update(ICONS)
    values.update(
        base=BASE, download=DOWNLOAD, mark=mark(), mark_large=mark('class="mark rise"'),
        doc_plain=doc(w, False), doc_blocks=doc(w, True), results=results(w),
        marquee_a=marquee(['中文', '繁體中文', '日本語'] + LATIN), marquee_b=marquee(EXTRA * 3),
        faq=''.join(f'<details><summary>{q}</summary><p>{a}</p></details>' for q, a in w['faq']),
    )
    html = (HERE / 'template.html').read_text(encoding='utf-8')
    html = re.sub(r'\{\{(\w+)\}\}', lambda m: str(values[m.group(1)]), html)
    (SITE / ('index.html' if w['code'] == 'en' else 'zh.html')).write_text(html, encoding='utf-8')


for words in (EN, ZH):
    page(words)
(SITE / 'icon.svg').write_text(mark('xmlns="http://www.w3.org/2000/svg"'), encoding='utf-8')
print('wrote site/index.html, site/zh.html, site/icon.svg')
