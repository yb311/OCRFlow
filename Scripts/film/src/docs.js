// Everything in the film that looks printed is drawn here, in code.
import { C, FONT, LANG, canvas, paragraph, rng, rrect } from './core.js';

const EN = `The committee reviewed the survey results in detail and agreed that the new schedule should begin in spring. Attendance rose steadily over the period, with the largest gains among younger readers and families. Further study of the archive suggests that early records were kept with far more care than previously assumed. Each region reported its figures separately, and the totals below combine them without adjustment. Visitors may request copies of any document held in the collection at no charge. Measurements were taken at regular intervals throughout the season and compared against the long-term average.`.split(' ');
const ZH = `委员会详细审阅了调查结果，并一致同意新的日程从春季开始。这一时期的到访人数稳步上升，其中年轻读者和家庭的增幅最大。对档案的进一步研究表明，早期记录的保存远比此前认为的更为细致。各地区分别上报数据，下表合并时未作调整。访客可以免费索取馆藏中任何文件的副本。整个季节定期进行测量，并与长期平均值进行比较。`;

function sentence(r, n) {
  const start = Math.floor(r() * (EN.length - n));
  return EN.slice(start, start + n).join(' ');
}
const zhText = (r, n) => {
  const s = Math.floor(r() * (ZH.length - n));
  return ZH.slice(s, s + n);
};

function table(g, x, y, w, rows, cols, rowH, r) {
  g.strokeStyle = '#333';
  g.lineWidth = Math.max(1, rowH * 0.03);
  for (let i = 0; i <= rows; i++) { g.beginPath(); g.moveTo(x, y + i * rowH); g.lineTo(x + w, y + i * rowH); g.stroke(); }
  for (let j = 0; j <= cols; j++) { const cx = x + (w / cols) * j; g.beginPath(); g.moveTo(cx, y); g.lineTo(cx, y + rows * rowH); g.stroke(); }
  g.fillStyle = '#222';
  g.font = `${rowH * 0.46}px ${FONT.serif}`;
  for (let i = 0; i < rows; i++) for (let j = 0; j < cols; j++) {
    const v = i === 0 ? ['Item', 'Q1', 'Q2', 'Total', 'Share', 'Note'][j % 6] : j === 0 ? `Row ${i}` : String(Math.floor(r() * 90000) / 10);
    g.fillText(v, x + (w / cols) * j + rowH * 0.25, y + i * rowH + rowH * 0.66);
  }
  return y + rows * rowH;
}

/** One random document in a w × h cell of the atlas. */
export function drawDoc(g, type, x, y, w, h, r) {
  g.save();
  g.translate(x, y);
  const paper = ['#F6F4EE', '#F2EFE5', '#FBFAF6', '#ECEAE0', '#F7F2E3'][Math.floor(r() * 5)];
  g.fillStyle = paper;
  g.fillRect(0, 0, w, h);
  g.fillStyle = '#23302E';
  g.textBaseline = 'alphabetic';
  const m = w * 0.1;
  const body = w * 0.034;
  const lead = body * 1.45;
  let cy = m + body;
  const inner = w - m * 2;
  const prose = (lines, font = FONT.serif) => {
    g.font = `${body}px ${font}`;
    g.fillStyle = '#2A2F2E';
    cy = paragraph(g, sentence(r, lines), m, cy, inner, lead) + lead * 0.6;
  };
  const head = (text, size = 2.1, bold = 700) => {
    g.font = `${bold} ${body * size}px ${FONT.ui}`;
    g.fillStyle = '#16211F';
    cy = paragraph(g, text, m, cy + body, inner, body * size * 1.2) + lead * 0.5;
  };
  switch (type % 8) {
    case 0:
      head('Annual Review'); prose(44); head('Findings', 1.4); prose(36); prose(52); head('Outlook', 1.4); prose(46);
      break;
    case 1: {
      head('Invoice 20418', 1.7);
      g.font = `${body}px ${FONT.ui}`; g.fillStyle = '#556';
      g.fillText('Date  12 March · Terms  30 days', m, cy); cy += lead * 1.6;
      cy = table(g, m, cy, inner, 8, 4, h * 0.042, r) + lead * 1.4;
      g.font = `700 ${body * 1.4}px ${FONT.ui}`; g.fillStyle = '#16211F';
      g.fillText('Total   8,412.50', m + inner * 0.46, cy); cy += lead * 2;
      prose(22);
      break;
    }
    case 2:
      g.fillStyle = '#14665D'; g.fillRect(0, 0, w, h * 0.34);
      g.fillStyle = '#F6F4EE'; g.font = `700 ${body * 2.8}px ${FONT.ui}`;
      paragraph(g, 'Quarterly Results', m, h * 0.17, inner, body * 3.2);
      cy = h * 0.42;
      for (let i = 0; i < 6; i++) {
        const bw = inner * (0.3 + r() * 0.7);
        g.fillStyle = i % 2 ? '#3C8578' : '#6FA79C';
        g.fillRect(m, cy, bw, h * 0.03); cy += h * 0.05;
      }
      cy += lead; prose(34, FONT.ui);
      break;
    case 3:
      g.textAlign = 'center';
      g.font = `700 ${body * 2.8}px ${FONT.serif}`; g.fillStyle = '#111';
      g.fillText('THE DAILY RECORD', w / 2, cy + body * 1.5);
      g.textAlign = 'left';
      cy += body * 3.2;
      g.fillRect(m, cy, inner, 2); cy += lead * 1.5;
      {
        const top = cy; const colW = inner / 3 - 6;
        for (let c = 0; c < 3; c++) {
          g.font = `${body * 0.82}px ${FONT.serif}`; g.fillStyle = '#222';
          let yy = top;
          for (let k = 0; k < 3; k++) { yy = paragraph(g, sentence(r, 44), m + c * (colW + 9), yy, colW, body * 1.15) + 8; }
        }
      }
      break;
    case 4:
      head('调查报告', 2.1);
      g.font = `${body}px ${FONT.serif}`; g.fillStyle = '#2A2F2E';
      cy = paragraph(g, zhText(r, 70), m, cy, inner, lead) + lead * 0.6;
      head('主要结论', 1.4);
      g.font = `${body}px ${FONT.serif}`; g.fillStyle = '#2A2F2E';
      cy = paragraph(g, zhText(r, 80), m, cy, inner, lead) + lead * 0.6;
      cy = table(g, m, cy, inner, 5, 3, h * 0.04, r);
      break;
    case 5:
      head('On Measured Growth', 1.7, 600);
      g.font = `italic ${body}px ${FONT.serif}`; g.fillStyle = '#444';
      g.fillText('Abstract', m, cy); cy += lead;
      prose(40);
      g.font = `italic ${body * 1.5}px ${FONT.serif}`; g.fillStyle = '#111';
      g.textAlign = 'center';
      g.fillText('E(x) = ∑ pᵢ xᵢ,   σ² = E(x²) − μ²', w / 2, cy + lead); g.textAlign = 'left';
      cy += lead * 2.6;
      prose(48);
      g.font = `italic ${body * 1.5}px ${FONT.serif}`; g.fillStyle = '#111';
      g.textAlign = 'center';
      g.fillText('∫₀¹ f(t) dt ≈ ½ [ f(0) + f(1) ]', w / 2, cy + lead); g.textAlign = 'left';
      cy += lead * 2.6;
      prose(30);
      break;
    case 6:
      g.font = `${body * 0.95}px ${FONT.mono}`;
      head('RECEIPT', 1.5, 700);
      for (let i = 0; i < 14; i++) {
        g.font = `${body * 0.95}px ${FONT.mono}`; g.fillStyle = '#333';
        g.fillText(`${['Coffee', 'Paper', 'Ink', 'Stamps', 'Folder', 'Tea', 'Pens'][i % 7]}`, m, cy);
        g.textAlign = 'right'; g.fillText((r() * 40 + 2).toFixed(2), w - m, cy); g.textAlign = 'left';
        cy += lead;
      }
      g.fillRect(m, cy, inner, 2); cy += lead * 1.4;
      g.font = `700 ${body * 1.3}px ${FONT.mono}`; g.fillStyle = '#111';
      g.fillText('TOTAL 186.40', m, cy);
      break;
    default: {
      head('Field Notes', 1.8);
      const hh = h * 0.26;
      const grad = g.createLinearGradient(m, cy, m + inner, cy + hh);
      grad.addColorStop(0, '#3C8578'); grad.addColorStop(1, '#0A3D37');
      g.fillStyle = grad; g.fillRect(m, cy, inner, hh);
      g.fillStyle = '#F6F4EE'; g.beginPath(); g.arc(m + inner * 0.75, cy + hh * 0.3, hh * 0.13, 0, 7); g.fill();
      g.fillStyle = '#07423B'; g.beginPath(); g.moveTo(m, cy + hh); g.lineTo(m + inner * 0.4, cy + hh * 0.4); g.lineTo(m + inner * 0.7, cy + hh); g.fill();
      cy += hh + lead * 1.4;
      prose(50); prose(30);
    }
  }
  g.restore();
}

/** Atlas of documents; returns the canvas, its columns and rows. */
export function docAtlas(cols = 8, rows = 4, cw = 512, ch = 660, seed = 11) {
  const c = canvas(cols * cw, rows * ch);
  const g = c.getContext('2d');
  const r = rng(seed);
  for (let i = 0; i < cols * rows; i++) drawDoc(g, i, (i % cols) * cw, Math.floor(i / cols) * ch, cw, ch, r);
  return { canvas: c, cols, rows };
}

const HERO = {
  en: {
    title: 'Community Library Annual Report',
    p1: 'Reading rooms stayed busy throughout the year. Visits rose in every quarter, and the new evening hours brought in many first-time members. Volunteers digitized the local newspaper archive, so that residents can now search more than sixty years of stories from home.',
    h1: 'Visits by quarter',
    th: ['Quarter', 'Visits', 'New members'],
    h2: 'Next year',
    p2: 'The library will extend weekend opening, add two study rooms, and continue scanning the photograph collection, starting with the harbor and the old market square.',
  },
  zh: {
    title: '社区图书馆年度报告',
    p1: '阅览室全年都很热闹。每个季度的到馆人次都在增长，新开放的夜间时段吸引了许多首次办证的读者。志愿者把本地报纸档案全部数字化，居民现在在家就能搜索六十多年来的报道。',
    h1: '各季度到馆人次',
    th: ['季度', '到馆人次', '新增读者'],
    h2: '明年计划',
    p2: '图书馆将延长周末开放时间，增设两间自习室，并继续扫描老照片馆藏，先从港口和旧市集广场开始。',
  },
}[LANG];

/** The page the film reads: a made-up report, with where each block is. */
export function heroPage() {
  const W = 1240; const H = 1600;
  const c = canvas(W, H);
  const g = c.getContext('2d');
  g.fillStyle = '#FBFAF5';
  g.fillRect(0, 0, W, H);
  g.textBaseline = 'alphabetic';
  const x = 110; const inner = W - 220;
  const blocks = [];
  const mark = (y0, y1, w = inner) => blocks.push({ x: x - 16, y: y0 - 12, w: w + 32, h: y1 - y0 + 24 });

  let y = 150;
  g.fillStyle = '#111';
  g.font = `700 54px ${FONT.ui}`;
  g.fillText(HERO.title, x, y);
  mark(y - 50, y + 12, g.measureText(HERO.title).width);
  y += 88;

  g.font = `31px ${FONT.serif}`; g.fillStyle = '#1a1a1a';
  let y0 = y - 28;
  y = paragraph(g, HERO.p1, x, y, inner, 44);
  mark(y0, y - 28);
  y += 40;

  g.font = `700 37px ${FONT.ui}`; g.fillStyle = '#111';
  g.fillText(HERO.h1, x, y);
  mark(y - 34, y + 10, g.measureText(HERO.h1).width);
  y += 36;

  const rows = [HERO.th, ['Q1', '18,240', '312'], ['Q2', '19,875', '401'], ['Q3', '21,330', '458'], ['Q4', '23,160', '526']];
  const rowH = 66; const col = [0, 340, 680, inner];
  y0 = y;
  g.strokeStyle = '#111'; g.lineWidth = 2;
  for (let i = 0; i <= rows.length; i++) { g.beginPath(); g.moveTo(x, y + i * rowH); g.lineTo(x + inner, y + i * rowH); g.stroke(); }
  for (const cx of col) { g.beginPath(); g.moveTo(x + cx, y); g.lineTo(x + cx, y + rows.length * rowH); g.stroke(); }
  rows.forEach((row, i) => row.forEach((v, j) => {
    g.font = `${i === 0 ? '700 ' : ''}30px ${i === 0 ? FONT.ui : FONT.serif}`;
    g.fillStyle = '#111';
    g.fillText(v, x + col[j] + 20, y + i * rowH + 44);
  }));
  y += rows.length * rowH;
  mark(y0, y);
  y += 72;

  g.font = `italic 40px ${FONT.serif}`; g.fillStyle = '#111';
  const formula = '(23,160 − 18,240) ÷ 18,240 = 27%';
  const fw = g.measureText(formula).width;
  g.fillText(formula, (W - fw) / 2, y);
  blocks.push({ x: (W - fw) / 2 - 22, y: y - 44, w: fw + 44, h: 68 });
  y += 90;

  g.font = `700 37px ${FONT.ui}`; g.fillStyle = '#111';
  g.fillText(HERO.h2, x, y);
  mark(y - 34, y + 10, g.measureText(HERO.h2).width);
  y += 62;

  g.font = `31px ${FONT.serif}`; g.fillStyle = '#1a1a1a';
  y0 = y - 28;
  y = paragraph(g, HERO.p2, x, y, inner, 44);
  mark(y0, y - 28);

  return { canvas: c, blocks, w: W, h: H };
}

/** An article in a browser-like window on a teal desktop, with the bit to pick. */
export function desktop() {
  const W = 2560; const H = 1440;
  const c = canvas(W, H);
  const g = c.getContext('2d');
  const wall = g.createLinearGradient(0, 0, W, H);
  wall.addColorStop(0, '#0B3B35'); wall.addColorStop(0.55, '#0F5A50'); wall.addColorStop(1, '#3C8578');
  g.fillStyle = wall; g.fillRect(0, 0, W, H);

  // Menu bar.
  g.fillStyle = 'rgba(255,255,255,.16)'; g.fillRect(0, 0, W, 44);

  const wx = 300; const wy = 110; const ww = 1960; const wh = 1240;
  g.save();
  g.shadowColor = 'rgba(0,0,0,.5)'; g.shadowBlur = 80; g.shadowOffsetY = 30;
  rrect(g, wx, wy, ww, wh, 26); g.fillStyle = '#FBFAF6'; g.fill();
  g.restore();
  g.save(); rrect(g, wx, wy, ww, wh, 26); g.clip();
  g.fillStyle = '#E9E7DF'; g.fillRect(wx, wy, ww, 84);
  ['#EC6A5E', '#F4BF4F', '#61C554'].forEach((d, i) => { g.fillStyle = d; g.beginPath(); g.arc(wx + 44 + i * 36, wy + 42, 12, 0, 7); g.fill(); });
  g.fillStyle = '#F8F7F2'; rrect(g, wx + 560, wy + 20, 840, 44, 12); g.fill();
  g.fillStyle = '#777'; g.font = `24px ${FONT.ui}`; g.textAlign = 'center';
  g.fillText(LANG === 'zh' ? '任何网页、任何应用' : 'any page, any app', wx + 980, wy + 50); g.textAlign = 'left';

  const text = LANG === 'zh'
    ? { h: '深海里的光', a: '在阳光到达不了的地方，大多数生物都会自己发光。有的用光来寻找伴侣，有的用它引诱猎物，还有的用一闪而过的亮光吓退敌人。', b: '科学家估计，生活在海洋中层的动物里，约有四分之三能够发光。这可能是地球上最常见的一种交流方式，却也是我们了解最少的一种。', c: '研究人员用低光相机拍摄了数千小时的影像，首次记录下这些信号随深度的变化。' }
    : { h: 'The Light Under the Sea', a: 'Where sunlight never reaches, most living things make their own. Some use it to find a mate, some to lure their prey, and others to startle a predator with a sudden flash.', b: 'Scientists estimate that around three quarters of the animals in the open ocean can produce light. It may be the most common form of communication on Earth, and it is one of the least understood.', c: 'Using low-light cameras, researchers have now filmed thousands of hours of footage, and for the first time recorded how these signals change with depth.' };
  const tx = wx + 240; const inner = ww - 480;
  g.fillStyle = '#111'; g.font = `700 76px ${FONT.ui}`;
  g.fillText(text.h, tx, wy + 200);
  g.fillStyle = '#222'; g.font = `38px ${FONT.serif}`;
  let y = paragraph(g, text.a, tx, wy + 290, inner, 56);
  const pick = { x: tx - 28, y: y - 18, w: inner + 56, h: 0 };
  y = paragraph(g, text.b, tx, y + 34, inner, 56);
  y = paragraph(g, text.c, tx, y + 34, inner, 56);
  pick.h = y - pick.y - 22;
  const pg = g.createLinearGradient(tx, y + 20, tx + inner, y + 300);
  pg.addColorStop(0, '#0A3D37'); pg.addColorStop(1, '#3C8578');
  g.fillStyle = pg; rrect(g, tx, y + 20, inner, wy + wh - y - 60, 14); g.fill();
  g.restore();
  return { canvas: c, pick, w: W, h: H };
}

/** A tall page, for the long screenshot: one continuous, dense article. */
export function tallPage() {
  const W = 1024; const H = 8192;
  const c = canvas(W, H);
  const g = c.getContext('2d');
  g.fillStyle = '#FBFAF5'; g.fillRect(0, 0, W, H);
  const r = rng(29);
  let y = 110;
  const m = 90; const inner = W - m * 2;
  const heads = LANG === 'zh'
    ? ['开始之前', '第一步', '材料与方法', '结果', '讨论', '接下来', '附录', '致谢', '参考文献']
    : ['Before you begin', 'The first step', 'Materials and methods', 'Results', 'Discussion', 'What comes next', 'Appendix', 'Thanks', 'References'];
  let n = 0;
  while (y < H - 200) {
    g.fillStyle = '#111'; g.font = `700 52px ${FONT.ui}`;
    g.fillText(heads[n % heads.length], m, y); y += 74; n++;
    const parts = 2 + Math.floor(r() * 2);
    for (let i = 0; i < parts && y < H - 300; i++) {
      g.font = `30px ${FONT.serif}`; g.fillStyle = '#222';
      y = paragraph(g, LANG === 'zh' ? zhText(r, 120) : sentence(r, 56), m, y, inner, 43) + 26;
    }
    if (n % 3 === 0 && y < H - 500) {
      const hh = 240;
      const grad = g.createLinearGradient(m, y, m + inner, y + hh);
      grad.addColorStop(0, '#14665D'); grad.addColorStop(1, '#6FA79C');
      g.fillStyle = grad; rrect(g, m, y, inner, hh, 14); g.fill();
      g.fillStyle = 'rgba(255,255,255,.85)';
      for (let k = 0; k < 9; k++) { const bh = 30 + r() * 150; g.fillRect(m + 40 + k * 88, y + hh - 20 - bh, 56, bh); }
      y += hh + 44;
    } else if (n % 3 === 1 && y < H - 400) {
      y = table(g, m, y, inner, 5, 4, 54, r) + 44;
    }
    y += 34;
  }
  return { canvas: c, w: W, h: H };
}

/** Slides of a made-up deck, as an atlas. */
export function slideAtlas(cols = 6, rows = 4, cw = 640, ch = 360, seed = 5) {
  const c = canvas(cols * cw, rows * ch);
  const g = c.getContext('2d');
  const r = rng(seed);
  const titles = LANG === 'zh'
    ? ['我们的目标', '市场概况', '用户调研', '路线图', '增长数据', '团队', '预算', '风险', '竞争格局', '里程碑', '下一步', '总结']
    : ['Our goals', 'The market', 'What users say', 'Roadmap', 'Growth', 'The team', 'Budget', 'Risks', 'Landscape', 'Milestones', 'Next steps', 'Summary'];
  const schemes = [['#F6F4EE', '#14665D', '#23302E'], ['#07423B', '#8FF0D8', '#F6F4EE'], ['#FBFAF6', '#3C8578', '#23302E'], ['#14665D', '#F6F4EE', '#E8F8F2'], ['#E2E0D6', '#07423B', '#23302E']];
  for (let i = 0; i < cols * rows; i++) {
    const x = (i % cols) * cw; const y = Math.floor(i / cols) * ch;
    const [bg, accent, ink] = schemes[i % schemes.length];
    g.save(); g.translate(x, y); g.beginPath(); g.rect(0, 0, cw, ch); g.clip();
    g.fillStyle = bg; g.fillRect(0, 0, cw, ch);
    g.fillStyle = accent; g.font = `700 44px ${FONT.ui}`;
    g.fillText(titles[i % titles.length], 44, 78);
    g.fillStyle = accent; g.fillRect(44, 98, 70, 5);
    const kind = i % 4;
    g.fillStyle = ink;
    if (kind === 0) {
      g.font = `24px ${FONT.ui}`;
      for (let k = 0; k < 4; k++) {
        g.globalAlpha = 0.9; g.fillStyle = accent; g.beginPath(); g.arc(54, 148 + k * 46, 6, 0, 7); g.fill();
        g.globalAlpha = 1; g.fillStyle = ink;
        g.fillText(LANG === 'zh' ? zhText(r, 18) : sentence(r, 6).slice(0, 44), 74, 156 + k * 46);
      }
    } else if (kind === 1) {
      for (let k = 0; k < 8; k++) {
        const bh = 40 + r() * 170; g.fillStyle = accent; g.globalAlpha = 0.45 + k * 0.07;
        g.fillRect(50 + k * 68, 330 - bh, 48, bh);
      }
      g.globalAlpha = 1;
    } else if (kind === 2) {
      g.strokeStyle = accent; g.lineWidth = 34; let a = -1.57;
      [0.45, 0.3, 0.25].forEach((p, k) => {
        g.globalAlpha = 1 - k * 0.3; g.beginPath(); g.arc(180, 225, 80, a, a + p * 6.283); g.stroke(); a += p * 6.283;
      });
      g.globalAlpha = 1; g.fillStyle = ink; g.font = `24px ${FONT.ui}`;
      for (let k = 0; k < 3; k++) g.fillText(LANG === 'zh' ? zhText(r, 11) : sentence(r, 4).slice(0, 26), 320, 180 + k * 46);
    } else {
      g.strokeStyle = accent; g.lineWidth = 6; g.beginPath(); let v = 300;
      for (let k = 0; k < 11; k++) { v -= r() * 34 - 6; const px = 50 + k * 54; if (k) g.lineTo(px, v); else g.moveTo(px, v); }
      g.stroke();
    }
    g.fillStyle = accent; g.globalAlpha = 0.6; g.font = `18px ${FONT.ui}`; g.textAlign = 'right';
    g.fillText(String(i + 1), cw - 26, ch - 22); g.textAlign = 'left'; g.globalAlpha = 1;
    g.restore();
  }
  return { canvas: c, cols, rows };
}
