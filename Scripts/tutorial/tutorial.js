// The how-to video. Nothing is recorded: the screens are drawn here, with the app's
// own wording from Localizable.xcstrings, and one clock moves everything.
const lang = new URLSearchParams(location.search).get('lang') === 'zh' ? 'zh' : 'en';
const zh = lang === 'zh';
const L = (en, cn) => (zh ? cn : en);

// When each chapter starts. Kept equal to CHAPTER_TIMES in Scripts/site/build.py.
const CHAPTERS = { files: 4, capture: 36, long: 58, queue: 78, record: 98, end: 134 };
const DURATION = 138;
const NAMES = {
  files: L('Recognize files', '识别文件'), capture: L('Screenshot', '截图'), long: L('Long screenshot', '长截图'),
  queue: L('Queue Screenshots', '队列截图'), record: L('Record Actions', '录制操作'),
};

// Words of the sample report, and the sample article. --------------------------
const REPORT = zh ? {
  title: '社区图书馆年度报告',
  p1: '阅览室全年都很热闹。每个季度的到馆人次都在增长，新开放的夜间时段吸引了许多首次办证的读者。',
  h1: '各季度到馆人次', th: ['季度', '到馆人次', '新增读者'], h2: '明年计划',
  p2: '图书馆将延长周末开放时间，增设两间自习室，并继续扫描老照片馆藏。',
} : {
  title: 'Community Library Annual Report',
  p1: 'Reading rooms stayed busy throughout the year. Visits rose in every quarter, and the new evening hours brought in many first-time members.',
  h1: 'Visits by quarter', th: ['Quarter', 'Visits', 'New members'], h2: 'Next year',
  p2: 'The library will extend weekend opening, add two study rooms, and continue scanning the photograph collection.',
};
const ROWS = [['Q1', '18,240', '312'], ['Q2', '19,875', '401'], ['Q3', '21,330', '458'], ['Q4', '23,160', '526']];
const tableHTML = `<table><tr>${REPORT.th.map((h) => `<th>${h}</th>`).join('')}</tr>${ROWS.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join('')}</tr>`).join('')}</table>`;
const ARTICLE = zh ? {
  title: '深海里的光',
  p: ['在阳光到达不了的地方，大多数生物都会自己发光。有的用光来寻找伴侣，有的用它引诱猎物，还有的靠一闪而过的亮光吓退捕食者。',
      '科学家估计，生活在海洋中层的动物里，约有四分之三能够发光。这可能是地球上最常见的一种交流方式，却也是我们了解最少的一种。',
      '研究人员用低光相机拍摄了数千个小时的影像，首次记录下这些信号随深度的变化。',
      '越往深处，光的颜色越单一，几乎只剩下蓝绿色，因为这是海水中传播得最远的颜色。',
      '有些鱼却能发出红光，别的生物看不见它，它们就像带着一盏只有自己能用的探照灯。',
      '水母的发光蛋白后来被带进实验室，成了生物学研究里最常用的工具之一。',
      '我们对这片黑暗的了解还很少，每次下潜几乎都会遇到从未见过的物种。'],
} : {
  title: 'The Light Under the Sea',
  p: ['Where sunlight never reaches, most living things make their own. Some use it to find a mate, some to lure their prey, and others to startle a predator with a sudden flash.',
      'Scientists estimate that around three quarters of the animals in the open ocean can produce light. It may be the most common form of communication on Earth, and it is one of the least understood.',
      'Using low-light cameras, researchers have now filmed thousands of hours of footage, and for the first time recorded how these signals change with depth.',
      'The deeper you go, the narrower the colors become, until almost everything glows blue-green, the color that travels furthest through water.',
      'A few fish make red light that others cannot see, as if carrying a searchlight only they can use.',
      'A protein from a jellyfish was later carried into the laboratory, and became one of the most used tools in biology.',
      'We still know very little about this darkness. Nearly every dive meets a species nobody has seen before.'],
};

// Icons. ----------------------------------------------------------------------
const svg = (p, size = 24, extra = '') => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" ${extra}>${p}</svg>`;
const I = {
  play: `<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M7 4.5v15a1 1 0 0 0 1.5.86l12-7.5a1 1 0 0 0 0-1.72l-12-7.5A1 1 0 0 0 7 4.5z"/></svg>`,
  share: svg('<path d="M12 15V4M8 8l4-4 4 4"/><path d="M6 12v7a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-7"/>'),
  gear: svg('<circle cx="12" cy="12" r="3.2"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1"/>'),
  long: svg('<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M12 7v10M9.5 9.5L12 7l2.5 2.5M9.5 14.5L12 17l2.5-2.5"/>'),
  x: svg('<path d="M6 6l12 12M18 6L6 18"/>'),
  save: svg('<path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/>'),
  check: svg('<path d="M5 12.5l4.5 4.5L19 7.5"/>'),
  finder: svg('<path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2"/>', 20),
  down: svg('<path d="M12 5v14M6 13l6 6 6-6"/>', 18),
  pause: `<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4.5" height="16" rx="1"/><rect x="13.5" y="4" width="4.5" height="16" rx="1"/></svg>`,
  rec: `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#ff453a" stroke-width="2"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.5" fill="#ff453a"/></svg>`,
  arrow: svg('<path d="M5 12h14M13 6l6 6-6 6"/>', 20),
  tray: svg('<rect x="5" y="4" width="14" height="16" rx="2.5"/><path d="M8.5 9h7M8.5 12.5h5"/>', 22),
};

// Helpers. ---------------------------------------------------------------------
const stage = document.getElementById('stage');
const add = (html, parent = stage) => { const t = document.createElement('template'); t.innerHTML = html.trim(); return parent.appendChild(t.content.firstChild); };
const $ = (s, root = stage) => root.querySelector(s);
const $$ = (s, root = stage) => [...root.querySelectorAll(s)];
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const seg = (t, a, b) => clamp((t - a) / (b - a));
const smooth = (x) => x * x * (3 - 2 * x);
const out = (x) => 1 - (1 - x) ** 3;
const lerp = (a, b, k) => a + (b - a) * k;
const vis = (el, on) => { el.style.visibility = on ? 'visible' : 'hidden'; };
// Seen between a and b, fading at both ends.
const span = (el, t, a, b, fade = 0.25) => {
  const k = Math.min(seg(t, a, a + fade), 1 - seg(t, b - fade, b));
  vis(el, k > 0); el.style.opacity = k;
  return k;
};

const menubar = (app = 'Safari') => `<div class="menubar"><b>${app}</b><span>${L('File', '文件')}</span><span>${L('Edit', '编辑')}</span><span>${L('View', '显示')}</span><div class="tray"><span class="tray-icon" data-tray>${I.tray}</span><span>9:41</span></div></div>`;
const menu = () => `<div class="menu" style="right:60px">
  <div data-m="capture"><span>${L('Capture Screenshot', '截图')}</span><small>⌥⇧⌘2</small></div>
  <div data-m="queue"><span>${L('Queue Screenshots', '队列截图')}</span></div><hr>
  <div data-m="record"><span>${L('Record Actions…', '录制操作…')}</span></div>
  <div><span>${L('Manage Recorded Actions…', '管理录制的操作…')}</span></div><hr>
  <div><span>${L('Open Images…', '打开图片…')}</span></div><hr>
  <div><span>${L('Floating Capture Button', '悬浮截图按钮')}</span></div><hr>
  <div><span>${L('Open OCRFlow', '打开 OCRFlow')}</span></div>
  <div><span>${L('Settings…', '设置…')}</span><small>⌘,</small></div>
  <div><span>${L('Quit OCRFlow', '退出 OCRFlow')}</span><small>⌘Q</small></div></div>`;
const docHTML = () => `<div class="doc">
  <div class="blk"><i data-n="1"></i><h5>${REPORT.title}</h5></div>
  <div class="blk"><i data-n="2"></i><p>${REPORT.p1}</p></div>
  <div class="blk"><i data-n="3"></i><h6>${REPORT.h1}</h6></div>
  <div class="blk"><i data-n="4"></i>${tableHTML}</div>
  <div class="blk"><i data-n="5"></i><h6>${REPORT.h2}</h6></div>
  <div class="blk"><i data-n="6"></i><p>${REPORT.p2}</p></div></div>`;
const kind = { h: L('Paragraph Title', '段落标题'), p: L('Text', '正文'), t: L('Table', '表格') };
const blocksHTML = () => [
  ['h', 'PP-OCRv6 small · 98%', `<h5>${REPORT.title}</h5>`], ['p', 'PP-OCRv6 small · 100%', `<p>${REPORT.p1}</p>`],
  ['h', 'PP-OCRv6 small · 100%', `<h5>${REPORT.h1}</h5>`], ['t', 'PaddleOCR-VL-1.6 Q4', tableHTML],
  ['h', 'PP-OCRv6 small · 100%', `<h5>${REPORT.h2}</h5>`], ['p', 'PP-OCRv6 small · 100%', `<p>${REPORT.p2}</p>`],
].map(([k, m, h], i) => `<div class="block"><small><span>${i + 1} · ${kind[k]}</span><em>${m}</em></small>${h}</div>`).join('');
const markdown = `# ${REPORT.title}\n\n${REPORT.p1}\n\n## ${REPORT.h1}\n\n| ${REPORT.th.join(' | ')} |\n| --- | --- | --- |\n${ROWS.map((r) => `| ${r.join(' | ')} |`).join('\n')}\n\n## ${REPORT.h2}\n\n${REPORT.p2}`;
const plainText = `${REPORT.title}\n\n${REPORT.p1}\n\n${REPORT.h1}\n\n${REPORT.th.join('   ')}\n${ROWS.map((r) => r.join('   ')).join('\n')}\n\n${REPORT.h2}\n\n${REPORT.p2}`;

// OCRFlow's main window: `left`, `top`, and what is in the list.
const mainWindow = (id, name, size, body) => `<div class="win" id="${id}" style="left:210px;top:48px;width:1500px;height:872px">
  <div class="side"><div class="lights"><i></i><i></i><i></i></div><div class="search">${L('Search names and text', '搜索文件名和文字')}</div>
    <div class="empty"><p>${L('No Images Yet', '尚未添加图片')}</p></div>
    <div class="row"><div class="thumb"></div><div>${name}<small>${size}</small></div><span class="state"></span></div>
    <div class="sidefoot"><span>+</span><span>−</span></div></div>
  <div class="top"><b>OCRFlow</b><div class="seg" style="margin-left:150px"><span class="on">${L('Workspace', '工作台')}</span><span>${L('Review', '复核')}</span></div>
    <div class="tools"><span class="status"></span><span class="playbtn">${I.play}</span><span class="btn-i exportbtn">${I.share}</span><span class="btn-i">${I.gear}</span></div></div>
  <div class="prev">${docHTML()}</div>
  <div class="res"><div class="restop"><div class="seg"><span class="t0 on">${L('Blocks', '区块')}</span><span class="t1">Markdown</span><span class="t2">${L('Plain Text', '纯文本')}</span></div></div>
    <div class="blocks">${blocksHTML()}</div><div class="plain md">${markdown.replace(/</g, '&lt;')}</div><div class="plain tx">${plainText}</div></div>
  ${body}</div>`;

const browserWin = (id, address, inner, extra = '') => `<div class="win page-win" id="${id}" style="left:210px;top:60px;width:1500px;height:860px"><div class="chrome"><div class="lights"><i></i><i></i><i></i></div><div class="address">${address}</div>${extra}</div>${inner}</div>`;
const articleHTML = (n = 3) => `<h2>${ARTICLE.title}</h2>${ARTICLE.p.slice(0, n).map((p) => `<p>${p}</p>`).join('')}`;
const capbar = (id, items) => `<div class="capbar" id="${id}">${items.map((x) => ({
  ocr: `<span data-c="ocr"><b>OCR</b></span>`, long: `<span data-c="long">${I.long}</span>`, sep: '<u></u>', x: `<span data-c="x">${I.x}</span>`,
  save: `<span data-c="save">${I.save}</span>`, ok: `<span class="ok" data-c="ok">${I.check}</span>`,
}[x])).join('')}</div>`;
// Darkens all but a rectangle; set with `hole`.
const dimmer = (id) => `<div id="${id}" class="layer"><div class="dim"></div><div class="dim"></div><div class="dim"></div><div class="dim"></div></div>`;
const hole = (el, x, y, w, h) => {
  const [a, b, c, d] = el.children;
  Object.assign(a.style, { left: 0, top: 0, width: '1920px', height: `${y}px` });
  Object.assign(b.style, { left: 0, top: `${y + h}px`, width: '1920px', height: `${1080 - y - h}px` });
  Object.assign(c.style, { left: 0, top: `${y}px`, width: `${x}px`, height: `${h}px` });
  Object.assign(d.style, { left: `${x + w}px`, top: `${y}px`, width: `${1920 - x - w}px`, height: `${h}px` });
};

// The always-there pieces. --------------------------------------------------------
const scenes = {
  files: add('<div class="scene"></div>'), capture: add('<div class="scene"></div>'), long: add('<div class="scene"></div>'),
  queue: add('<div class="scene"></div>'), record: add('<div class="scene"></div>'),
};
const chapterEl = add('<div id="chapter"></div>');
const captionEl = add('<div id="caption"><span></span></div>');
const cardEl = add('<div id="card"><div></div></div>');
const keysEl = add('<div id="keys"></div>');
const cursorEl = add(`<div id="cursor"><svg class="arrow" width="38" height="46" viewBox="0 0 19 23"><path d="M1.5 1v17.5l4.4-4.2 3 6.9 3.1-1.3-3-6.8h6.2z" fill="#111" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg><svg class="cross" width="44" height="44" viewBox="0 0 44 44" style="position:absolute;left:-22px;top:-22px"><path d="M22 2v40M2 22h40" stroke="#fff" stroke-width="2.4"/><path d="M22 2v40M2 22h40" stroke="#000" stroke-width="1" /></svg></div>`);
const rippleEl = add('<div id="ripple"></div>');

// Scene 1: recognize files ---------------------------------------------------------
add(mainWindow('w1', 'annual-report.png', 'PNG · 353 KB', `
  <div class="drop"><h4>${L('Drop Images Here', '拖放图片到这里')}</h4><p>PNG · JPEG · TIFF · BMP · GIF · HEIC · WebP · PDF</p><span class="choose">${L('Choose Files', '选择文件')}</span><div class="dropmark"></div></div>
  <div class="menu" id="exportmenu" style="left:auto;right:20px;top:66px;width:400px"><div class="on"><span>${L('Export “annual-report.png”…', '导出“annual-report.png”…')}</span></div><div><span>${L('Export All Results (1 Files)…', '导出全部结果（1 个文件）…')}</span></div><hr><div><span>${L('Export Original Files…', '导出原图…')}</span></div></div>`), scenes.files);
add(`<div class="file" id="dragfile" style="left:60px;top:680px"><div class="thumb"></div>annual-report.png</div>`, scenes.files);

// Scene 2: screenshot ----------------------------------------------------------------
const article = (id) => browserWin(id, 'example.com/deep-sea', `<div class="article">${articleHTML(3)}</div>`);
scenes.capture.insertAdjacentHTML('beforeend', menubar());
add(article('w2'), scenes.capture);
add(dimmer('d2'), scenes.capture);
add('<div class="area" id="a2"></div>', scenes.capture);
add('<div class="size" id="s2"></div>', scenes.capture);
add(capbar('b2', ['ocr', 'long', 'sep', 'x', 'save', 'ok']), scenes.capture);
add('<div class="tip" id="t2"></div>', scenes.capture);
add(mainWindow('w2r', L('Screenshot 2026-11-06 09.41.png', '截图 2026-11-06 09.41.png'), 'PNG · 212 KB', ''), scenes.capture);
{
  const w = $('#w2r');
  $('.doc', w).innerHTML = `<p>${ARTICLE.p[1]}</p><p>${ARTICLE.p[2]}</p>`;
  $('.doc', w).style.aspectRatio = '1100/330';
  $('.blocks', w).innerHTML = `<div class="block"><small><span>1 · ${kind.p}</span><em>PP-OCRv6 small · 100%</em></small><p>${ARTICLE.p[1]}</p></div><div class="block"><small><span>2 · ${kind.p}</span><em>PP-OCRv6 small · 100%</em></small><p>${ARTICLE.p[2]}</p></div>`;
}

// Scene 3: long screenshot --------------------------------------------------------------
const longArticle = `<h2>${ARTICLE.title}</h2>${[0, 1, 2, 3, 4].map(() => ARTICLE.p.map((x) => `<p>${x}</p>`).join('')).join('')}`;
scenes.long.insertAdjacentHTML('beforeend', menubar());
add(browserWin('w3', 'example.com/deep-sea', `<div class="clip"><div class="article" id="lp" style="top:0">${longArticle}</div></div>`), scenes.long);
add(dimmer('d3'), scenes.long);
add('<div class="area" id="a3"></div>', scenes.long);
add(capbar('b3', ['ocr', 'long', 'sep', 'x', 'save', 'ok']), scenes.long);
add(capbar('b3b', ['ocr', 'sep', 'x', 'save', 'ok']), scenes.long);
add('<div class="tip" id="t3"></div>', scenes.long);
add(`<div class="joined" id="j3"><div class="article" id="jp" style="top:0;left:0;width:1500px;transform-origin:0 0">${longArticle}</div></div>`, scenes.long);
add('<div class="size" id="s3"></div>', scenes.long);
add(`<div class="capsule" id="c3"></div>`, scenes.long);

// Scene 4: queue --------------------------------------------------------------------------
scenes.queue.insertAdjacentHTML('beforeend', menubar(L('Books', '图书')));
const readerPages = [0, 1, 2].map((i) => `<div class="readerpage" data-rp="${i}"><h3>${L('Chapter', '第')} ${i + 1}${L('', ' 章')}</h3>${[...ARTICLE.p.slice(i * 2), ...ARTICLE.p.slice(0, i * 2)].map((p) => `<p>${p}</p>`).join('')}</div>`).join('');
add(browserWin('w4', L('Book', '书'), readerPages, `<span class="pgnext" id="next4">${L('Next page', '下一页')} →</span>`), scenes.queue);
scenes.queue.insertAdjacentHTML('beforeend', menu());
for (let i = 0; i < 3; i++) add(`<div class="taken" data-q="${i}"></div>`, scenes.queue);
add(`<div class="hud" id="h4"><h4>${L('Queue Screenshots', '队列截图')} <span id="qn" style="margin-left:auto;font-weight:500;color:var(--mint)"></span></h4><p>${L('Drag out an area to take it. Clicks, scrolling and keys work as usual — turn the page, then drag again. Press Esc to finish.', '拖动框选即截取。点按、滚动和按键照常使用——翻到下一页再框选。按 Esc 结束。')}</p><div class="rowbtn end"><span class="pill">${L('Finish', '结束')}</span></div></div>`, scenes.queue);
add(`<div class="hud" id="c4"><h4>${L('3 screenshots taken. What becomes of them?', '共 3 张截图，怎么处理？')}</h4><div class="choice"><span class="pill main" id="c4a">${L('Recognize as one document', '识别为一份文档')}</span><span class="pill">${L('Recognize each on its own', '分别识别')}</span><span class="pill">${L('Only save, without recognizing', '只保存，不识别')}</span><span class="pill">${L('Discard', '丢弃')}</span></div></div>`, scenes.queue);

// Scene 5: record -----------------------------------------------------------------------------
scenes.record.insertAdjacentHTML('beforeend', menubar());
const slideTitles = zh ? ['市场概况', '用户增长', '竞争格局', '产品路线', '收入结构', '团队介绍'] : ['The market', 'Growth', 'Landscape', 'Roadmap', 'Revenue', 'The team'];
const slides = slideTitles.map((t, i) => `<div class="slide" data-sl="${i}"><h2>${t}</h2><div class="chart">${[0, 1, 2, 3, 4, 5, 6].map((j) => `<i style="height:${30 + ((i * 3 + j * 37) % 65)}%"></i>`).join('')}</div><span class="num">${i + 1} / 60</span></div>`).join('');
add(browserWin('w5', 'example.com/slides', slides), scenes.record);
scenes.record.insertAdjacentHTML('beforeend', menu());
add(dimmer('d5'), scenes.record);
add('<div class="area" id="a5"></div>', scenes.record);
add('<div class="size" id="s5"></div>', scenes.record);
add(capbar('b5', ['x', 'ok']), scenes.record);
add(`<div class="hud" id="h5"><h4>${I.rec}${L('Recording your actions', '正在录制你的操作')}</h4><p>${L('Do what you want repeated, the way you normally would. To keep what is on screen at a point, click Capture Here — or use the screenshot shortcut.', '照常做一遍想让它重复的操作。需要留下屏幕上的内容时，点“截取此处”，或者用截图快捷键。')}</p><p class="count" id="hc5"></p><div class="rowbtn"><span class="pill" id="capHere">${I.finder}${L('Capture Here', '截取此处')}</span><span class="pill">${L('Long Screenshot Here', '长截图此处')}</span></div><div class="rowbtn end"><span class="pill">${L('Cancel', '取消')}</span><span class="pill main" id="doneRec">${L('Done', '完成')}</span></div></div>`, scenes.record);
add(`<div class="win editor" id="e5" style="left:260px;top:90px;width:1400px;height:820px">
  <div class="edside"><div class="row"><div>${L('Recording 1', '录制 1')}<small>${L('2 steps', '2 步')}</small></div></div></div>
  <div class="edmain"><div class="edtop">${L('Recording 1', '录制 1')}<span class="run" id="run5">${I.play}${L('Run', '运行')}</span></div>
    <div class="form"><h6>${L('Steps', '步骤')}</h6><div class="group"><div>${I.finder}<span>${L('Capture an area of 1280 × 720', '截取 1280 × 720 的区域')}</span></div><div>${I.arrow}<span>${L('Press →', '按 →')}</span></div></div>
      <p class="hint">${L('Steps run one after another, each once the screen has settled. Right-click a step to move or delete it.', '步骤依次执行，每一步都等屏幕稳定之后再做。右键点按步骤可以移动或删除。')}</p>
      <h6>${L('How often', '执行次数')}</h6><div class="group"><div id="often"><span>${L('How often', '执行次数')}</span><span class="val">${L('Until the screen stops changing', '直到屏幕不再变化')}</span></div></div>
      <h6>${L('Pages to Open', '要打开的网页')}</h6><div class="group"><div style="height:64px"></div></div>
      <p class="hint">${L('One address a line. Each is opened in turn and the steps are done on it. Leave empty to work wherever things are.', '每行一个网址，依次打开并执行步骤。留空就在当前位置操作。')}</p>
      <h6>${L('Result', '结果')}</h6><div class="group"><div id="become"><span>${L('Captures become', '截图合成为')}</span><span class="val">${L('One document', '一份文档')}</span></div></div>
      <p class="hint">${L('When a run ends, you choose whether they are recognized, only saved, or discarded.', '运行结束时，由你选择识别、只保存还是丢弃。')}</p></div></div></div>`, scenes.record);
add(`<div class="hud" id="r5"><p id="r5n" style="color:var(--text);margin:0;font-weight:600"></p><p>${L('Press Esc to stop. Clicking or typing pauses the run.', '按 Esc 停止。点按或打字会暂停运行。')}</p><div class="rowbtn end"><span class="pill">${L('Stop', '停止')}</span></div></div>`, scenes.record);
add(`<div class="hud" id="c5"><h4>${L('“Recording 1” is done. Screenshots taken: 60', '“录制 1”已完成，共截取 60 张')}</h4><div class="choice"><span class="pill main" id="c5a">${L('Recognize the text', '识别文字')}</span><span class="pill">${L('Only save, without recognizing', '只保存，不识别')}</span><span class="pill">${L('Discard', '丢弃')}</span></div></div>`, scenes.record);

// Measured now, while nothing has been moved. --------------------------------------
const center = (selector, root = stage) => { const r = $(selector, root).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; };
const box = (el) => el.getBoundingClientRect();
for (const name of Object.keys(scenes)) vis(scenes[name], false);
const AT = {
  play: center('#w1 .playbtn'), exportBtn: center('#w1 .exportbtn'), md: center('#w1 .t1'), plain: center('#w1 .t2'), blocks: center('#w1 .t0'),
  tray: center('[data-tray]', scenes.queue), mQueue: center('[data-m="queue"]', scenes.queue), mRecord: center('[data-m="record"]', scenes.record),
  next: center('#next4'), c4a: center('#c4a'), capHere: center('#capHere'), done: center('#doneRec'), run: center('#run5'), c5a: center('#c5a'),
};
const ROWH = $$('#w1 .block').map((b) => box(b));

// Who speaks when. ----------------------------------------------------------------------
const CAPTIONS = [
  [5.4, L('Drag <b>images or PDFs</b> into the window. Whole folders work too.', '把<b>图片或 PDF</b> 拖进窗口，也可以拖入整个文件夹。')],
  [11.2, L('Click <b>▶ Start Recognition</b> in the toolbar.', '点工具栏的 <b>▶ 开始识别</b>。')],
  [17, L('Every block on the page gets a number, matching the results on the right.', '页面上的每一块都标了编号，和右边的结果一一对应。')],
  [23, L('See the result as <b>Markdown</b> or <b>plain text</b> too.', '结果也可以切换成 <b>Markdown</b> 或<b>纯文本</b>。')],
  [29, L('Click <b>Export</b> to save it. Choose the format in Settings: Markdown, text, JSON, searchable PDF or Excel.', '点<b>导出</b>存成文件。格式在设置里选：Markdown、纯文本、JSON、可搜索 PDF 或 Excel。')],
  [37.4, L('In any app, press <b>⌥⇧⌘2</b>. The menu bar icon and the floating button do the same.', '在任何应用里按 <b>⌥⇧⌘2</b>。菜单栏图标和悬浮按钮也可以。')],
  [41, L('Drag out an area, or click a window.', '拖出一个区域，或者点选一个窗口。')],
  [44.4, L('A bar appears beside it: recognize, long screenshot, cancel, save, copy.', '旁边出现操作栏：识别、长截图、取消、保存、拷贝。')],
  [51, L('Click <b>OCR</b>, and the text is in the OCRFlow window.', '点 <b>OCR</b>，文字就出现在 OCRFlow 窗口里。')],
  [59.4, L('After choosing an area, click the <b>long screenshot</b> button.', '选好区域后，点<b>长截图</b>按钮。')],
  [62.5, L('Scroll as usual. The joined picture grows beside the page.', '照常滚动，旁边能看到拼接的图一点点变长。')],
  [67, L('Or click <b>Auto Scroll</b>, and it scrolls for you.', '或者点<b>自动滚动</b>，让它替你滚。')],
  [72.5, L('Stop where you want it to end, then recognize, save or copy.', '滚到想要的位置就停，然后识别、保存或拷贝。')],
  [79.4, L('Choose <b>Queue Screenshots</b> from the menu bar icon.', '点菜单栏图标，选<b>队列截图</b>。')],
  [82.5, L('Drag out an area to take it.', '拖出区域，就截取一张。')],
  [86, L('Turn the page as usual and drag again. No shortcut needed.', '照常翻页，再拖下一张，不用按快捷键。')],
  [92.5, L('Press <b>Esc</b> to finish, then choose what becomes of them.', '按 <b>Esc</b> 结束，再选择怎么处理这些截图。')],
  [99.4, L('Choose <b>Record Actions…</b> from the menu bar icon.', '点菜单栏图标，选<b>录制操作…</b>')],
  [102, L('Do it once. Click <b>Capture Here</b> and choose the slide.', '照常做一遍。先点<b>截取此处</b>，选中幻灯片。')],
  [108, L('Press <b>→</b> to turn to the next slide.', '按 <b>→</b> 翻到下一页。')],
  [111, L('Click <b>Done</b>.', '点<b>完成</b>。')],
  [113.5, L('Your steps are listed. Choose how often it runs and what the captures become.', '这里列出了你的步骤。选好执行次数和截图的合成方式。')],
  [120, L('Click <b>Run</b>. It repeats until the screen stops changing. Press Esc to stop early.', '点<b>运行</b>。它会一直重复，直到屏幕不再变化。按 Esc 可以提前停止。')],
  [128.5, L('When it ends, choose to recognize them, only save them, or discard them.', '结束后，选择识别、只保存或丢弃。')],
  [131.3, L('The document then appears in the OCRFlow window.', '识别结果会出现在 OCRFlow 窗口里。')],
];
const captionAt = (t) => CAPTIONS.reduce((best, c) => (c[0] <= t ? c : best), null);
const NEXT = (c) => CAPTIONS[CAPTIONS.indexOf(c) + 1]?.[0] ?? Infinity;

// The pointer, as [time, x, y] stops, and when it clicks. ------------------------------
const para = $$('#w2 .article p');
const AREA2 = { x: 300, y: Math.round(box(para[1]).top - 12), w: 1320, h: Math.round(box(para[2]).bottom - box(para[1]).top + 24) };
const PATH = [
  [0, 960, 620],
  [5.6, 960, 620], [7, 110, 730], [7.5, 110, 730], [9.4, 960, 500], [10, 960, 500],
  [12.2, ...AT.play], [14, ...AT.play], [18, 1560, 560], [22.5, 1560, 560],
  [24, ...AT.md], [26.4, ...AT.md], [27, ...AT.plain], [29.4, ...AT.plain], [30.4, ...AT.exportBtn], [35.5, ...AT.exportBtn],
  [36, 880, 300], [41.3, 880, 300], [42, AREA2.x, AREA2.y], [42.3, AREA2.x, AREA2.y], [44, AREA2.x + AREA2.w, AREA2.y + AREA2.h], [44.6, AREA2.x + AREA2.w, AREA2.y + AREA2.h],
];
const CLICKS = [13, 25, 28, 31, 50, 60.6, 68, 72, 76.5, 80.1, 81.2, 85.7, 90, 96.5, 100.1, 101.2, 103, 106.8, 112.2, 119.6, 131];
// Points fixed for later scenes are added as the scenes are defined below.
const addPath = (...stops) => PATH.push(...stops);

// Bar positions under the areas.
const BAR2 = { x: AREA2.x + AREA2.w - 280, y: AREA2.y + AREA2.h + 12 };
const items = {
  ocr: BAR2.x + 30, long: BAR2.x + 74, x: BAR2.x + 128, save: BAR2.x + 172, ok: BAR2.x + 216, y: BAR2.y + 25,
};
addPath([45.4, items.ocr, items.y], [46.3, items.ocr, items.y], [46.7, items.long, items.y], [47.6, items.long, items.y], [48, items.save, items.y], [48.5, items.save, items.y], [48.8, items.ok, items.y], [49.2, items.ok, items.y], [49.7, items.ocr, items.y], [50.3, items.ocr, items.y], [52, items.ocr + 180, items.y - 120], [57.5, items.ocr + 180, items.y - 120]);
// Long screenshot.
const AREA3 = { x: 330, y: 250, w: 1000, h: 560 };
const BAR3 = { x: AREA3.x + AREA3.w - 280, y: AREA3.y + AREA3.h + 12 };
const JOIN = { x: AREA3.x + AREA3.w + 24, y: AREA3.y, w: 240 };
addPath([58, 800, 500], [59.7, 800, 500], [60.3, BAR3.x + 74, BAR3.y + 25], [61, BAR3.x + 74, BAR3.y + 25], [62.4, 830, 560], [67, 830, 560], [67.7, AREA3.x + 110, AREA3.y + AREA3.h + 36], [72.3, AREA3.x + 110, AREA3.y + AREA3.h + 36], [73, BAR3.x + 30, BAR3.y + 25], [77.5, BAR3.x + 30, BAR3.y + 25]);
// Queue.
const Q = [{ x: 310, y: 230, w: 1300, h: 230 }, { x: 310, y: 300, w: 1300, h: 320 }, { x: 310, y: 260, w: 1300, h: 270 }];
addPath([78, 960, 500], [79.6, ...AT.tray], [80.4, ...AT.tray], [81, ...AT.mQueue], [81.4, ...AT.mQueue],
  [82.6, Q[0].x, Q[0].y], [83, Q[0].x, Q[0].y], [84.6, Q[0].x + Q[0].w, Q[0].y + Q[0].h], [85, Q[0].x + Q[0].w, Q[0].y + Q[0].h], [85.6, ...AT.next], [86, ...AT.next],
  [86.6, Q[1].x, Q[1].y], [87, Q[1].x, Q[1].y], [88.6, Q[1].x + Q[1].w, Q[1].y + Q[1].h], [89, Q[1].x + Q[1].w, Q[1].y + Q[1].h], [89.8, ...AT.next], [90.2, ...AT.next],
  [90.6, Q[2].x, Q[2].y], [91, Q[2].x, Q[2].y], [92, Q[2].x + Q[2].w, Q[2].y + Q[2].h], [95.4, Q[2].x + Q[2].w, Q[2].y + Q[2].h], [96.2, ...AT.c4a], [97.5, ...AT.c4a]);
// Record.
const AREA5 = { x: 280, y: 130, w: 1360, h: 765 };
addPath([98, 960, 500], [99.6, ...AT.tray], [100.4, ...AT.tray], [101, ...AT.mRecord], [101.4, ...AT.mRecord], [102.4, ...AT.capHere], [103.2, ...AT.capHere],
  [103.7, AREA5.x, AREA5.y], [104.2, AREA5.x, AREA5.y], [105.6, AREA5.x + AREA5.w, AREA5.y + AREA5.h], [106.1, AREA5.x + AREA5.w - 38, AREA5.y + AREA5.h - 37], [107, AREA5.x + AREA5.w - 38, AREA5.y + AREA5.h - 37],
  [108, 960, 500], [111, 960, 500], [111.8, ...AT.done], [112.6, ...AT.done], [114, 900, 400], [117.5, 1100, 420], [118.5, 1100, 660], [119, ...AT.run], [120.2, ...AT.run], [121, 1800, 960], [128.8, 1800, 960], [130.6, ...AT.c5a], [133, ...AT.c5a]);
PATH.sort((a, b) => a[0] - b[0]);

function pointer(t) {
  let i = PATH.findIndex((p) => p[0] > t);
  if (i < 0) i = PATH.length - 1;
  const a = PATH[Math.max(0, i - 1)]; const b = PATH[i];
  const k = b[0] === a[0] ? 1 : smooth(seg(t, a[0], b[0]));
  return [lerp(a[1], b[1], k), lerp(a[2], b[2], k)];
}

// Drawing a frame. --------------------------------------------------------------------
const setClass = (el, name, on) => el.classList.toggle(name, on);
const place = (el, x, y) => { el.style.left = `${x}px`; el.style.top = `${y}px`; };
const box2 = (el, r) => { el.style.left = `${r.x}px`; el.style.top = `${r.y}px`; el.style.width = `${r.w}px`; el.style.height = `${r.h}px`; };
const growing = (r, k) => ({ x: r.x, y: r.y, w: r.w * k, h: r.h * k });

function drawMainResults(w, t, recognizedAt, showAll) {
  const k = seg(t, recognizedAt, recognizedAt + 2.2);
  const page = $$('.prev .blk i', w);
  page.forEach((b, i) => vis(b, k > (i + 1) / (page.length + 1)));
  $$('.block', w).forEach((b, i, all) => vis(b, showAll && k > (i + 1) / (all.length + 1)));
}

function drawFiles(t) {
  const w = $('#w1');
  const dropped = t >= 9.5;
  vis($('.drop', w), !dropped);
  vis($('.dropmark', w), t > 8.2 && !dropped);
  $('.prev', w).style.visibility = dropped ? 'visible' : 'hidden';
  $('.res', w).style.visibility = dropped ? 'visible' : 'hidden';
  vis($('.row', w), dropped);
  vis($('.empty', w), !dropped);
  $('.playbtn', w).style.background = dropped && t < 13 ? '#fff' : '#d5d7d9';
  $('.playbtn', w).style.opacity = dropped && t < 13.2 ? 1 : 0.5;
  const running = t >= 13 && t < 15.5;
  $('.status', w).textContent = running ? `${L('Recognizing', '识别中')} ${Math.round(seg(t, 13, 15.5) * 100)}%` : t >= 15.5 ? '✓ 1/1' : '';
  $('.row .state', w).textContent = t >= 15.5 ? '✓' : '';
  drawMainResults(w, t, 13.2, true);
  // The table, picked out on both sides.
  const hot = t > 18.4 && t < 22.8;
  setClass($$('.prev .blk', w)[3], 'hot', hot);
  setClass($$('.block', w)[3], 'hot', hot);
  // Markdown, plain text.
  const tab = t >= 28 && t < 34.5 ? 2 : t >= 25 ? 1 : 0;
  const tabNow = t >= 28 ? 2 : t >= 25 ? 1 : 0;
  ['.t0', '.t1', '.t2'].forEach((s, i) => setClass($(s, w), 'on', tabNow === i));
  if (tabNow > 0) $$('.block', w).forEach((b) => vis(b, false));
  vis($('.plain.md', w), tabNow === 1);
  vis($('.plain.tx', w), tabNow === 2);
  vis($('#exportmenu'), t >= 31 && tab >= 0);
  // The file, carried in.
  const f = $('#dragfile');
  vis(f, !dropped);
  if (t >= 7.5) { const [x, y] = pointer(t); place(f, x - 50, y - 60); } else place(f, 60, 680);
}

function drawCapture(t) {
  const w = $('#w2');
  vis(w, true);
  const frozen = t >= 41;
  vis($('#d2'), frozen && t < 50.4);
  const drag = seg(t, 42.3, 44);
  const a = growing(AREA2, drag);
  if (frozen) hole($('#d2'), a.x, a.y, a.w, a.h);
  vis($('#a2'), t >= 42.3 && t < 50.4);
  box2($('#a2'), a);
  vis($('#s2'), t >= 42.3 && t < 50.4);
  place($('#s2'), a.x + a.w - 110, a.y - 34);
  $('#s2').textContent = `${Math.round(a.w)} × ${Math.round(a.h)}`;
  const bar = $('#b2');
  vis(bar, t >= 44.2 && t < 50.4);
  place(bar, BAR2.x, BAR2.y);
  const tips = [[45.2, 46.5, 'ocr', L('Recognize the text', '识别文字')], [46.6, 47.8, 'long', L('Long screenshot: scroll on from here', '长截图：从这里往下滚动')], [47.9, 48.6, 'save', L('Save (Space)', '保存（空格）')], [48.7, 49.4, 'ok', L('Copy to the clipboard (Return)', '拷贝到剪贴板（回车）')], [49.6, 50.2, 'ocr', L('Recognize the text', '识别文字')]];
  const now = tips.find(([a0, b0]) => t >= a0 && t < b0);
  $$('span', bar).forEach((s) => setClass(s, 'hover', now && s.dataset.c === now[2]));
  vis($('#t2'), !!now);
  if (now) { $('#t2').textContent = now[3]; place($('#t2'), BAR2.x, BAR2.y + 58); }
  // Comes up with what was read.
  const r = $('#w2r');
  const k = out(seg(t, 50.3, 50.9));
  vis(r, k > 0);
  r.style.opacity = k;
  r.style.transform = `translateY(${(1 - k) * 30}px)`;
  vis($('.empty', r), false);
  $('.status', r).textContent = t >= 52.6 ? '✓ 1/1' : `${L('Recognizing', '识别中')} ${Math.round(seg(t, 50.8, 52.6) * 100)}%`;
  $('.row .state', r).textContent = t >= 52.6 ? '✓' : '';
  $('.playbtn', r).style.opacity = 0.5;
  $$('.prev .blk i', r).forEach((b) => vis(b, false));
  $$('.block', r).forEach((b, i) => vis(b, k > 0 && t > 51.4 + i * 0.6));
  [$('.plain.md', r), $('.plain.tx', r)].forEach((p) => vis(p, false));
}

const SCROLLED = (t) => {
  const byHand = lerp(0, 700, smooth(seg(t, 62.6, 66.6)));
  const auto = lerp(0, 1100, seg(t, 68, 71.8));
  return byHand + auto;
};
function drawLong(t) {
  const scrolled = SCROLLED(t);
  $('#lp').style.transform = `translateY(${-scrolled}px)`;
  const a3 = AREA3;
  vis($('#d3'), true);
  hole($('#d3'), a3.x, a3.y, a3.w, a3.h);
  vis($('#a3'), true);
  box2($('#a3'), a3);
  const first = t < 60.7;
  const bar = first ? $('#b3') : $('#b3b');
  vis($('#b3'), first);
  vis($('#b3b'), !first);
  place(bar, BAR3.x, BAR3.y);
  $$('span', $('#b3')).forEach((s) => setClass(s, 'hover', t > 60 && s.dataset.c === 'long'));
  vis($('#t3'), t > 60 && t < 60.7);
  $('#t3').textContent = L('Long screenshot: scroll on from here', '长截图：从这里往下滚动');
  place($('#t3'), BAR3.x, BAR3.y + 58);
  $$('span', $('#b3b')).forEach((s) => setClass(s, 'hover', t > 74 && s.dataset.c === 'ocr'));
  // The picture so far, beside the area.
  const scale = JOIN.w / 1500;
  const shown = (a3.h + scrolled) * scale;
  const room = 560;
  const j = $('#j3');
  vis(j, !first);
  box2(j, { x: JOIN.x, y: JOIN.y, w: JOIN.w, h: Math.min(shown, room) });
  const jp = $('#jp');
  jp.style.transform = `translateY(${-Math.max(0, shown - room)}px) scale(${scale})`;
  vis($('#s3'), !first);
  place($('#s3'), JOIN.x + 20, JOIN.y + Math.min(shown, room) + 8);
  $('#s3').textContent = `${a3.w} × ${Math.round(a3.h + scrolled)}`;
  const cap = $('#c3');
  vis(cap, !first);
  place(cap, a3.x + 40, a3.y + a3.h + 16);
  const auto = t >= 68 && t < 72;
  cap.innerHTML = `${auto ? I.pause : I.down}${auto ? L('Stop Scrolling', '停止滚动') : L('Auto Scroll', '自动滚动')}`;
}

function drawQueue(t) {
  const menuEl = $('.menu', scenes.queue);
  vis(menuEl, t >= 80.1 && t < 81.3);
  setClass($('[data-m="queue"]', scenes.queue), 'on', t > 80.8);
  setClass($('[data-tray]', scenes.queue), 'on', t > 80.1 && t < 81.3);
  const page = t >= 90 ? 2 : t >= 85.7 ? 1 : 0;
  $$('[data-rp]', scenes.queue).forEach((p, i) => vis(p, i === page));
  span($('#h4'), t, 81.5, 92.8);
  const taken = (t >= 84.8) + (t >= 88.8) + (t >= 92);
  $('#qn').textContent = taken ? `${taken}` : '';
  const windows = [[83, 84.6, 85.3], [87, 88.6, 89.3], [91, 92, 92.8]];
  $$('[data-q]', scenes.queue).forEach((el, i) => {
    const [a, b, c] = windows[i];
    vis(el, t >= a && t < c);
    box2(el, growing(Q[i], smooth(seg(t, a, b))));
    el.style.background = t >= b ? 'rgba(143,240,216,.55)' : 'rgba(21,184,153,.14)';
    el.style.opacity = t >= b ? 1 - seg(t, b, c) : 1;
  });
  span($('#c4'), t, 93.6, 96.8);
  showKeys(t, 92.8, 93.6, ['Esc']);
}

function drawRecord(t) {
  const menuEl = $('.menu', scenes.record);
  vis(menuEl, t >= 100.1 && t < 101.3);
  setClass($('[data-m="record"]', scenes.record), 'on', t > 100.8);
  const recording = t >= 101.4 && t < 112.3;
  // Slides turn when → is pressed, and quickly once running.
  const running = seg(t, 120.5, 128);
  const slide = t >= 120.5 ? Math.min(5, Math.floor(running * 6)) : t >= 109.2 ? 1 : 0;
  $$('[data-sl]', scenes.record).forEach((s, i) => vis(s, i === slide));
  $$('[data-sl] .num', scenes.record).forEach((n, i) => { if (i === slide && t >= 120.5) n.textContent = `${Math.min(60, 2 + Math.floor(running * 59))} / 60`; });
  span($('#h5'), t, 101.4, 112.3);
  vis($('#h5'), recording && !(t >= 103.2 && t < 107));
  $('#hc5').textContent = t >= 109.2 ? L('Steps recorded: 2', '已录制 2 步') : t >= 107 ? L('Steps recorded: 1', '已录制 1 步') : L('Waiting for you…', '等你操作…');
  const choosing = t >= 103.2 && t < 107;
  vis($('#d5'), choosing);
  const a = growing(AREA5, smooth(seg(t, 104.2, 105.6)));
  hole($('#d5'), a.x, a.y, a.w, a.h);
  vis($('#a5'), t >= 104.2 && choosing);
  box2($('#a5'), a);
  vis($('#s5'), false);
  vis($('#b5'), t >= 105.7 && choosing);
  place($('#b5'), AREA5.x + AREA5.w - 110, AREA5.y + AREA5.h - 62);
  $$('span', $('#b5')).forEach((s) => setClass(s, 'hover', t > 106.2 && s.dataset.c === 'ok'));
  showKeys(t, 108.2, 109.6, ['→']);
  span($('#e5'), t, 112.6, 120.1);
  span($('#r5'), t, 120.3, 128.4);
  $('#r5n').textContent = L(`Round ${Math.min(60, 1 + Math.floor(running * 59))}, ${Math.min(60, 1 + Math.floor(running * 59))} captured`, `第 ${Math.min(60, 1 + Math.floor(running * 59))} 轮，已截取 ${Math.min(60, 1 + Math.floor(running * 59))} 张`);
  span($('#c5'), t, 128.6, 131.2);
}

function showKeys(t, a, b, keys) {
  if (t < a || t >= b) return;
  keysEl.innerHTML = keys.map((k) => `<kbd>${k}</kbd>`).join('');
  keysEl.style.visibility = 'visible';
  keysEl.style.opacity = Math.min(seg(t, a, a + 0.15), 1 - seg(t, b - 0.2, b));
}

const CARD = [[0, 3.6], [CHAPTERS.files + 0, CHAPTERS.files + 1.3], [CHAPTERS.capture, CHAPTERS.capture + 1.3], [CHAPTERS.long, CHAPTERS.long + 1.3], [CHAPTERS.queue, CHAPTERS.queue + 1.3], [CHAPTERS.record, CHAPTERS.record + 1.3], [CHAPTERS.end, DURATION + 1]];

function drawCard(t) {
  const c = CARD.find(([a, b]) => t >= a && t < b);
  if (!c) { vis(cardEl, false); return; }
  vis(cardEl, true);
  cardEl.style.opacity = c[0] === CHAPTERS.end ? seg(t, c[0], c[0] + 0.5) : c[0] === 0 ? 1 - seg(t, 3.3, 3.6) : Math.min(seg(t, c[0], c[0] + 0.2), 1 - seg(t, c[1] - 0.25, c[1]));
  const box0 = cardEl.firstChild;
  if (c[0] === 0) {
    box0.innerHTML = `<div style="display:grid;place-items:center"><h1>${L('How to use OCRFlow', 'OCRFlow 使用说明')}</h1><ol>${Object.values(NAMES).map((n) => `<li>${n}</li>`).join('')}</ol></div>`;
  } else if (c[0] === CHAPTERS.end) {
    box0.innerHTML = `<div><h1>OCRFlow</h1><small style="margin-top:16px;margin-bottom:0">yb311.github.io/OCRFlow</small></div>`;
  } else {
    const names = Object.keys(NAMES);
    const key = names.find((n) => CHAPTERS[n] === c[0]);
    box0.innerHTML = `<div><small>${names.indexOf(key) + 1} / ${names.length}</small><h1>${NAMES[key]}</h1></div>`;
  }
}

window.tutorialFrame = (t) => {
  const key = t < CHAPTERS.capture ? 'files' : t < CHAPTERS.long ? 'capture' : t < CHAPTERS.queue ? 'long' : t < CHAPTERS.record ? 'queue' : 'record';
  for (const name of Object.keys(scenes)) vis(scenes[name], name === key);
  keysEl.style.visibility = 'hidden';
  // A hidden parent does not hide children set visible, so those are hidden too.
  for (const name of Object.keys(scenes)) if (name !== key) $$('*', scenes[name]).forEach((el) => { el.style.visibility = 'hidden'; });
  $$('*', scenes[key]).forEach((el) => { el.style.visibility = ''; });
  ({ files: drawFiles, capture: drawCapture, long: drawLong, queue: drawQueue, record: drawRecord })[key](t);
  if (key === 'capture') showKeys(t, 38, 40.8, ['⌥', '⇧', '⌘', '2']);

  // Chapter name, top left.
  const inside = t >= CHAPTERS.files + 1.3 && t < CHAPTERS.end;
  vis(chapterEl, inside);
  chapterEl.textContent = NAMES[key];

  const c = captionAt(t);
  const showing = c && t < CHAPTERS.end && t < NEXT(c) && !CARD.some(([a, b]) => t >= a && t < b);
  vis(captionEl, !!showing);
  if (showing) { captionEl.firstChild.innerHTML = c[1]; captionEl.firstChild.style.opacity = Math.min(seg(t, c[0], c[0] + 0.25), 1 - seg(t, NEXT(c) - 0.15, NEXT(c))); }

  // Pointer.
  const [x, y] = pointer(t);
  const crossNow = (t >= 41 && t < 44.2) || (t >= 82.4 && t < 85) || (t >= 86.4 && t < 89) || (t >= 90.4 && t < 92.4) || (t >= 103.4 && t < 105.8);
  cursorEl.style.transform = `translate(${x}px, ${y}px)`;
  $('.arrow', cursorEl).style.visibility = crossNow ? 'hidden' : 'visible';
  $('.cross', cursorEl).style.visibility = crossNow ? 'visible' : 'hidden';
  vis(cursorEl, t > 3.6 && t < CHAPTERS.end);
  const click = CLICKS.find((k) => t >= k && t < k + 0.35);
  vis(rippleEl, click !== undefined);
  if (click !== undefined) {
    const [cx, cy] = pointer(click);
    place(rippleEl, cx, cy);
    const p = seg(t, click, click + 0.35);
    rippleEl.style.transform = `scale(${0.4 + p})`;
    rippleEl.style.opacity = 1 - p;
  }
  drawCard(t);
  return true;
};
window.tutorialDuration = DURATION;
window.tutorialReady = true;
