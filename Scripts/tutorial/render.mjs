// Renders the how-to video in headless Chrome, one exact frame at a time.
// Needs Scripts/film's node_modules (npm install there first).
//
//   node render.mjs --still 8,20 --lang zh --out /tmp/stills   frames to look at
//   node render.mjs --lang zh --out tutorial-zh.mp4            the whole video
import { createRequire } from 'node:module';
import { mkdir, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const require = createRequire(join(root, '../film/package.json'));
const puppeteer = require('puppeteer-core');
const ffmpegPath = require('ffmpeg-static');

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, arg, i, all) => {
  if (arg.startsWith('--')) pairs.push([arg.slice(2), all[i + 1]?.startsWith('--') ? 'true' : all[i + 1]]);
  return pairs;
}, []));
const lang = args.lang ?? 'en';
const fps = Number(args.fps ?? 30);
const out = resolve(args.out ?? 'out');

const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: 'new',
  args: ['--force-color-profile=srgb', '--hide-scrollbars', '--allow-file-access-from-files'],
  protocolTimeout: 600000,
});

try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });
  page.on('pageerror', (e) => console.error('[page error]', e.message));
  page.on('console', (m) => { if (m.type() === 'error') console.error('[page]', m.text()); });
  await page.goto(`${pathToFileURL(join(root, 'tutorial.html')).href}?lang=${lang}`);
  await page.waitForFunction('window.tutorialReady === true');
  const duration = await page.evaluate('window.tutorialDuration');
  const shot = async (t) => {
    await page.evaluate((time) => window.tutorialFrame(time), t);
    return page.screenshot({ type: 'jpeg', quality: 92 });
  };

  if (args.still) {
    await mkdir(out, { recursive: true });
    for (const t of args.still.split(',').map(Number)) {
      await writeFile(join(out, `${lang}-${t.toFixed(2).padStart(7, '0')}.jpg`), await shot(t));
    }
  } else {
    const encoder = spawn(ffmpegPath, [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'image2pipe', '-c:v', 'mjpeg', '-framerate', String(fps), '-i', '-',
      '-c:v', 'libx264', '-preset', 'slow', '-crf', '22', '-maxrate', '5M', '-bufsize', '10M',
      '-pix_fmt', 'yuv420p', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
      '-movflags', '+faststart', '-an', out,
    ], { stdio: ['pipe', 'inherit', 'inherit'] });
    const done = new Promise((ok, fail) => encoder.on('close', (c) => (c === 0 ? ok() : fail(new Error(`ffmpeg ${c}`)))));
    const count = Math.round(duration * fps);
    for (let i = 0; i < count; i++) {
      if (!encoder.stdin.write(await shot(i / fps))) await new Promise((ok) => encoder.stdin.once('drain', ok));
      if (i % 300 === 0) console.log(`${i}/${count}`);
    }
    encoder.stdin.end();
    await done;
    console.log('wrote', out);
  }
} finally {
  await browser.close();
}
