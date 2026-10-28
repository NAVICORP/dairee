/*
 * Compresses the site's text files ahead of time, next to each file as
 * name.br (brotli at its best) and name.gz, so server/site.mjs never makes
 * someone wait while it compresses a large file. Brotli at its best takes
 * about 13 seconds for one CanvasKit engine file, far too long to do on a
 * request. Runs in CI before the image is built:
 *
 *   node server/pack.mjs app/build/web web
 */
import { readdirSync, statSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import zlib from 'node:zlib';

const br = promisify(zlib.brotliCompress);
const gz = promisify(zlib.gzip);
export const PACKED = /\.(html|js|mjs|css|json|svg|txt|webmanifest|wasm|ttf|otf|frag|symbols|bin)$|(^|[\\/])NOTICES$/;

const files = [];
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const f = path.join(dir, name);
    if (statSync(f).isDirectory()) walk(f);
    else if (PACKED.test(f) && !f.endsWith('.map') && statSync(f).size > 1024) files.push(f);
  }
};
for (const dir of process.argv.slice(2)) walk(path.resolve(dir));

const started = Date.now();
let raw = 0;
let out = 0;
await Promise.all(files.map(async (f) => {
  const buf = readFileSync(f);
  const [b, g] = await Promise.all([
    br(buf, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: buf.length } }),
    gz(buf, { level: 9 }),
  ]);
  // Kept only when it saves something worth the trouble.
  if (b.length < buf.length * 0.9) writeFileSync(`${f}.br`, b);
  if (g.length < buf.length * 0.9) writeFileSync(`${f}.gz`, g);
  raw += buf.length;
  out += Math.min(b.length, buf.length);
}));
console.log(`packed ${files.length} files, ${(raw / 1e6).toFixed(1)} MB to ${(out / 1e6).toFixed(1)} MB in ${((Date.now() - started) / 1000).toFixed(0)} s`);
