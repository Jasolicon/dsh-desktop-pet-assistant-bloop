// 生成 update.json（发行清单）：版本、说明、安装包/便携版的大小与 SHA-256。
// 用法：npm run release:manifest
// 产物：dist/update.json；发布时把它和安装包一起上传到 GitHub Release。
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('.', import.meta.url)), '..');
const dist = join(root, 'dist');
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const version = String(pkg.version || '0.0.0');

function repoUrl() {
  if (process.env.GITHUB_REPOSITORY) return `https://github.com/${process.env.GITHUB_REPOSITORY}`;
  try {
    const remote = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd: root, encoding: 'utf8' }).trim();
    if (remote.startsWith('git@github.com:')) return `https://github.com/${remote.slice('git@github.com:'.length).replace(/\.git$/, '')}`;
    return remote.replace(/\.git$/, '');
  } catch {
    return 'https://github.com/Jasolicon/dsh-desktop-pet-assistant-bloop';
  }
}

function sha256(file) {
  return new Promise((resolveHash, reject) => {
    const hash = createHash('sha256');
    createReadStream(file)
      .on('data', (chunk) => hash.update(chunk))
      .on('error', reject)
      .on('end', () => resolveHash(hash.digest('hex')));
  });
}

if (!existsSync(dist)) {
  console.error('没有 dist/。先跑 npm run dist（安装包 + 便携版）或 npm run pack（onedir）。');
  process.exit(1);
}

const names = readdirSync(dist)
  .filter((name) => /\.(exe|zip)$/i.test(name))
  .filter((name) => !/^win-|unpacked/i.test(name))
  // 只收本次版本产出的文件，避免把 dist 里上一轮的 zip/exe 误写进发行清单。
  .filter((name) => name.includes(version))
  .sort();

const base = repoUrl();
const assets = {};
for (const name of names) {
  const file = join(dist, name);
  if (!statSync(file).isFile()) continue;
  const kind = /portable/i.test(name) ? 'portable' : (/setup|installer/i.test(name) ? 'installer' : 'archive');
  assets[name] = {
    fileName: name,
    urls: [`${base}/releases/download/v${version}/${encodeURIComponent(name)}`],
    size: statSync(file).size,
    sha256: await sha256(file),
    platform: 'windows',
    kind,
    variant: 'chat',
  };
}

const manifest = {
  version,
  html_url: `${base}/releases/tag/v${version}`,
  notes: process.env.RELEASE_NOTES || `泡泡 · Bloop ${version}`,
  assets,
};

writeFileSync(join(dist, 'update.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
console.log(`已写入 dist/update.json：${Object.keys(assets).length} 个附件，版本 ${version}`);
