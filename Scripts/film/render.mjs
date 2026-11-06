// Renders the film in headless Chrome, one exact frame at a time.
//
//   node render.mjs --still 3.2,9.5 --out /tmp/stills      frames to look at
//   node render.mjs --lang zh --audio music.wav --out f.mp4  the whole film
//
// Time only ever comes from here, so every run gives the same pictures.
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';
import ffmpegPath from 'ffmpeg-static';

const root = dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, arg, i, all) => {
  if (arg.startsWith('--')) pairs.push([arg.slice(2), all[i + 1]?.startsWith('--') ? 'true' : all[i + 1]]);
  return pairs;
}, []));

const lang = args.lang ?? 'en';
const fps = Number(args.fps ?? 60);
const width = Number(args.width ?? 1920);
const height = Number(args.height ?? 1080);
const out = resolve(args.out ?? 'out');

const types = { '.html': 'text/html', '.js': 'text/javascript', '.png': 'image/png', '.mjs': 'text/javascript' };
const server = createServer(async (req, res) => {
  try {
    const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = join(root, path === '/' ? 'film.html' : path);
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const url = `http://127.0.0.1:${server.address().port}/?lang=${lang}&w=${width}&h=${height}${'clean' in args ? '&clean=1' : ''}`;

const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: 'new',
  args: ['--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader',
         '--force-color-profile=srgb', '--hide-scrollbars', '--disable-background-timer-throttling'],
  protocolTimeout: 600000,
});

try {
  const page = await browser.newPage();
  await page.setViewport({ width, height, deviceScaleFactor: 1 });
  page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warn') console.error('[page]', m.text()); });
  page.on('pageerror', (e) => console.error('[page error]', e.message));
  await page.goto(url);
  await page.waitForFunction('window.filmReady === true', { timeout: 120000 });
  const duration = await page.evaluate('window.filmDuration');

  const frame = (t) => page.evaluate(async (time) => window.filmFrame(time), t);

  if (args.still) {
    await mkdir(out, { recursive: true });
    for (const t of args.still.split(',').map(Number)) {
      // Effects that accumulate settle from a little before the frame.
      const data = await frame(t);
      const name = `${lang}-${t.toFixed(2).padStart(6, '0')}.jpg`;
      await writeFile(join(out, name), Buffer.from(data, 'base64'));
      console.log(name);
    }
  } else {
    const from = Number(args.from ?? 0);
    const to = Number(args.to ?? duration);
    const encoder = spawn(ffmpegPath, [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'image2pipe', '-c:v', 'mjpeg', '-framerate', String(fps), '-i', '-',
      ...(args.audio ? ['-ss', String(from), '-t', String(to - from), '-i', args.audio] : []),
      '-c:v', 'libx264', '-preset', args.preset ?? 'slow', '-crf', args.crf ?? '19',
      '-pix_fmt', 'yuv420p', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
      '-movflags', '+faststart',
      ...(args.audio ? ['-c:a', 'aac', '-b:a', '192k', '-shortest'] : ['-an']),
      out,
    ], { stdio: ['pipe', 'inherit', 'inherit'] });
    const done = new Promise((ok, fail) => encoder.on('close', (c) => (c === 0 ? ok() : fail(new Error(`ffmpeg ${c}`)))));
    const count = Math.round((to - from) * fps);
    const started = Date.now();
    for (let i = 0; i < count; i++) {
      const data = await frame(from + i / fps);
      if (!encoder.stdin.write(Buffer.from(data, 'base64'))) {
        await new Promise((ok) => encoder.stdin.once('drain', ok));
      }
      if (i % 120 === 0) {
        const rate = (i + 1) / ((Date.now() - started) / 1000);
        console.log(`${i}/${count}  ${rate.toFixed(1)} fps  ${Math.round((count - i) / rate)} s left`);
      }
    }
    encoder.stdin.end();
    await done;
    console.log('wrote', out);
  }
} finally {
  await browser.close();
  server.close();
}
