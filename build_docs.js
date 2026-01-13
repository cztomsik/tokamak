import { readFileSync, writeFileSync, readdirSync, mkdirSync, cpSync, rmSync, existsSync } from 'fs';
import { join, basename, dirname, relative } from 'path';
import { marked } from 'marked';

const DOCS_DIR = 'docs';
const DIST_DIR = 'docs/dist';
const SRC_DIR = 'src';
const BASE_PATH = process.env.BASE_PATH || '';

const SECTIONS = {
  guide: {
    title: 'Guide',
    order: ['getting-started', 'server', 'routing', 'dependency-injection', 'middlewares', 'examples', 'terminal', 'time']
  },
  reference: {
    title: 'Reference',
    order: ['index', 'server', 'routing', 'dependency-injection', 'cli', 'tui', 'monitoring', 'time']
  },
  examples: {
    title: 'Examples',
    order: ['hello', 'hello_app', 'hello_cli', 'hello_ai', 'blog', 'todos_orm_sqlite', 'webview_app', 'clown-commander']
  }
};

// --- API Docs Generation ---

function findZigFiles(dir, files = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      findZigFiles(fullPath, files);
    } else if (entry.name.endsWith('.zig')) {
      files.push(fullPath);
    }
  }
  return files;
}

function parseZigFile(filePath) {
  const content = readFileSync(filePath, 'utf-8');
  const lines = content.split('\n');
  const items = [];
  let docComment = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();

    if (trimmed.startsWith('///')) {
      docComment.push(trimmed.slice(3).trim());
      continue;
    }

    if (trimmed.startsWith('pub ')) {
      const item = parseZigDeclaration(trimmed, docComment);
      if (item) items.push(item);
    }

    if (!trimmed.startsWith('///')) {
      docComment = [];
    }
  }

  return items;
}

function parseZigDeclaration(line, docComment) {
  const fnMatch = line.match(/^pub fn\s+(\w+)\s*\(([^)]*)\)/);
  if (fnMatch) {
    const afterParen = line.slice(line.indexOf(')') + 1);
    const retMatch = afterParen.match(/\s*([^{]+)/);
    return {
      kind: 'fn',
      name: fnMatch[1],
      params: fnMatch[2].trim(),
      returns: retMatch ? retMatch[1].trim() : '',
      doc: docComment.join('\n')
    };
  }

  const structMatch = line.match(/^pub const\s+(\w+)\s*=\s*struct/);
  if (structMatch) {
    return { kind: 'struct', name: structMatch[1], doc: docComment.join('\n') };
  }

  const enumMatch = line.match(/^pub const\s+(\w+)\s*=\s*enum/);
  if (enumMatch) {
    return { kind: 'enum', name: enumMatch[1], doc: docComment.join('\n') };
  }

  const unionMatch = line.match(/^pub const\s+(\w+)\s*=\s*union/);
  if (unionMatch) {
    return { kind: 'union', name: unionMatch[1], doc: docComment.join('\n') };
  }

  const constMatch = line.match(/^pub const\s+(\w+)\s*=\s*(.+)/);
  if (constMatch && !constMatch[2].startsWith('@import')) {
    return {
      kind: 'const',
      name: constMatch[1],
      value: constMatch[2].replace(/;$/, '').trim(),
      doc: docComment.join('\n')
    };
  }

  return null;
}

function escapeHtml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function makeAnchorId(filePath) {
  return filePath.replace(/[^a-zA-Z0-9]/g, '-').replace(/-+/g, '-');
}

function buildApiDocs(template, nav) {
  const files = findZigFiles(SRC_DIR).sort();
  const fileData = files.map(file => ({
    file,
    items: parseZigFile(file)
  })).filter(({ items }) => items.length > 0);

  // Generate TOC
  const tocHtml = fileData.map(({ file, items }) => {
    const relativePath = relative(SRC_DIR, file);
    const anchorId = makeAnchorId(relativePath);
    const counts = {
      fn: items.filter(i => i.kind === 'fn').length,
      struct: items.filter(i => i.kind === 'struct').length,
      enum: items.filter(i => i.kind === 'enum').length,
      union: items.filter(i => i.kind === 'union').length,
      const: items.filter(i => i.kind === 'const').length,
    };
    const badges = [];
    if (counts.fn) badges.push(`<span class="badge fn">${counts.fn} fn</span>`);
    if (counts.struct) badges.push(`<span class="badge struct">${counts.struct} struct</span>`);
    if (counts.enum) badges.push(`<span class="badge enum">${counts.enum} enum</span>`);
    if (counts.union) badges.push(`<span class="badge union">${counts.union} union</span>`);
    if (counts.const) badges.push(`<span class="badge const">${counts.const} const</span>`);
    return `<li><a href="#${anchorId}">${relativePath}</a> ${badges.join(' ')}</li>`;
  }).join('\n');

  // Generate sections
  const sections = fileData.map(({ file, items }) => {
    const relativePath = relative(SRC_DIR, file);
    const anchorId = makeAnchorId(relativePath);
    const itemsHtml = items.map(item => {
      const docHtml = item.doc ? `<p class="api-doc">${escapeHtml(item.doc)}</p>` : '';

      switch (item.kind) {
        case 'fn':
          return `<div class="api-item fn">
            <code class="signature">pub fn <strong>${item.name}</strong>(${item.params})${item.returns ? ' ' + item.returns : ''}</code>
            ${docHtml}
          </div>`;
        case 'struct':
          return `<div class="api-item struct">
            <code class="signature">pub const <strong>${item.name}</strong> = struct</code>
            ${docHtml}
          </div>`;
        case 'enum':
          return `<div class="api-item enum">
            <code class="signature">pub const <strong>${item.name}</strong> = enum</code>
            ${docHtml}
          </div>`;
        case 'union':
          return `<div class="api-item union">
            <code class="signature">pub const <strong>${item.name}</strong> = union</code>
            ${docHtml}
          </div>`;
        case 'const':
          return `<div class="api-item const">
            <code class="signature">pub const <strong>${item.name}</strong> = ${item.value}</code>
            ${docHtml}
          </div>`;
        default:
          return '';
      }
    }).join('\n');

    return `<section id="${anchorId}">
      <h2>${relativePath}</h2>
      ${itemsHtml}
    </section>`;
  }).join('\n');

  const totalItems = fileData.reduce((sum, { items }) => sum + items.length, 0);

  const content = `
    <h1>API Reference</h1>
    <p>Auto-generated from source. ${fileData.length} files, ${totalItems} public items.</p>
    <div class="api-toc">
      <h2>Table of Contents</h2>
      <input type="text" id="api-search" placeholder="Filter files..." autocomplete="off">
      <ul>${tocHtml}</ul>
    </div>
    <script>
      document.getElementById('api-search').addEventListener('input', function(e) {
        const query = e.target.value.toLowerCase();
        document.querySelectorAll('.api-toc li').forEach(li => {
          const text = li.textContent.toLowerCase();
          li.style.display = (query && !text.includes(query)) ? 'none' : '';
        });
      });
    </script>
    ${sections}
  `;

  return template
    .replace(/\{\{title\}\}/g, 'API Reference')
    .replace(/\{\{nav\}\}/g, nav)
    .replace(/\{\{content\}\}/g, content);
}

function parseFrontmatter(content) {
  const lines = content.split('\n');
  if (lines[0] !== '---') return { meta: {}, body: content };

  let endIndex = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === '---') {
      endIndex = i;
      break;
    }
  }

  if (endIndex === -1) return { meta: {}, body: content };

  // Simple YAML parsing for our needs
  const yamlStr = lines.slice(1, endIndex).join('\n');
  const meta = parseSimpleYaml(yamlStr);
  const body = lines.slice(endIndex + 1).join('\n').trim();
  return { meta, body };
}

function parseSimpleYaml(yaml) {
  const result = {};
  const lines = yaml.split('\n');
  let i = 0;

  function parseValue(baseIndent) {
    const items = [];
    const obj = {};
    let isArray = false;

    while (i < lines.length) {
      const line = lines[i];
      if (!line.trim()) { i++; continue; }

      const indent = line.search(/\S/);
      if (indent <= baseIndent && baseIndent >= 0) break;

      const content = line.trim();
      i++;

      if (content.startsWith('- ')) {
        isArray = true;
        const itemContent = content.slice(2);
        if (itemContent.includes(':')) {
          const colonIdx = itemContent.indexOf(':');
          const key = itemContent.slice(0, colonIdx).trim();
          const value = itemContent.slice(colonIdx + 1).trim();
          const item = { [key]: value.replace(/^["']|["']$/g, '') };

          // Check for more properties at deeper indent
          while (i < lines.length) {
            const nextLine = lines[i];
            if (!nextLine.trim()) { i++; continue; }
            const nextIndent = nextLine.search(/\S/);
            if (nextIndent <= indent) break;
            const nextContent = nextLine.trim();
            if (nextContent.includes(':')) {
              const nColonIdx = nextContent.indexOf(':');
              const nKey = nextContent.slice(0, nColonIdx).trim();
              const nValue = nextContent.slice(nColonIdx + 1).trim();
              item[nKey] = nValue.replace(/^["']|["']$/g, '');
            }
            i++;
          }
          items.push(item);
        } else {
          items.push(itemContent);
        }
      } else if (content.includes(':')) {
        const colonIdx = content.indexOf(':');
        const key = content.slice(0, colonIdx).trim();
        const value = content.slice(colonIdx + 1).trim();

        if (value) {
          obj[key] = value.replace(/^["']|["']$/g, '');
        } else {
          obj[key] = parseValue(indent);
        }
      }
    }

    return isArray ? items : obj;
  }

  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }

    const content = line.trim();
    const indent = line.search(/\S/);
    i++;

    if (content.includes(':')) {
      const colonIdx = content.indexOf(':');
      const key = content.slice(0, colonIdx).trim();
      const value = content.slice(colonIdx + 1).trim();

      if (value) {
        result[key] = value.replace(/^["']|["']$/g, '');
      } else {
        result[key] = parseValue(indent);
      }
    }
  }

  return result;
}

function convertInfoBoxes(markdown) {
  // Convert ::: warning Title\ncontent\n::: to HTML
  return markdown.replace(/::: (\w+)(?: ([^\n]*))?\n([\s\S]*?):::/g, (_, type, title, content) => {
    const titleHtml = title ? `<strong>${title}</strong> ` : '';
    return `<div class="info-box ${type}">${titleHtml}${content.trim()}</div>`;
  });
}

function fixLinks(html, currentPath) {
  // Fix markdown links: /guide/foo -> BASE_PATH/guide/foo/
  // Fix relative links: ./foo.md -> ../foo/
  return html
    .replace(/href="\/([^"]+)"/g, (_, path) => {
      if (path.endsWith('/') || path.includes('.') || path.startsWith('http')) return `href="${BASE_PATH}/${path}"`;
      return `href="${BASE_PATH}/${path}/"`;
    })
    .replace(/href="\.\/([^"]+)\.md"/g, (_, name) => `href="../${name}/"`)
    .replace(/href="([^"]+)\.md"/g, (_, path) => {
      if (path.startsWith('http') || path.startsWith('/')) return `href="${path}"`;
      return `href="${path}/"`;
    });
}

function getTitleFromContent(content) {
  const match = content.match(/^#\s+(.+)$/m);
  return match ? match[1] : null;
}

function slugToTitle(slug) {
  return slug
    .split('-')
    .map(word => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ')
    .replace('_', ' ');
}

function buildHomePage(filepath, template, nav) {
  const content = readFileSync(filepath, 'utf-8');
  const { meta } = parseFrontmatter(content);

  const hero = meta.hero || {};
  const features = meta.features || [];

  let heroHtml = '';
  if (hero.name) {
    const actions = (hero.actions || [])
      .map(a => {
        const href = a.link.startsWith('/') ? `${BASE_PATH}${a.link}` : a.link;
        return `<a href="${href}" class="btn ${a.theme || ''}">${a.text}</a>`;
      })
      .join('\n');

    heroHtml = `
      <div class="hero">
        <h1>${hero.name}</h1>
        <p class="tagline">${hero.text || ''}</p>
        <p class="subtitle">${hero.tagline || ''}</p>
        <div class="actions">${actions}</div>
      </div>
    `;
  }

  let featuresHtml = '';
  if (features.length) {
    const items = features
      .map(f => `<div class="feature"><h3>${f.title}</h3><p>${f.details}</p></div>`)
      .join('\n');
    featuresHtml = `<div class="features">${items}</div>`;
  }

  return template
    .replace(/\{\{title\}\}/g, hero.name || 'Tokamak')
    .replace(/\{\{nav\}\}/g, nav)
    .replace(/\{\{content\}\}/g, heroHtml + featuresHtml);
}

function buildPage(filepath, template, nav) {
  const content = readFileSync(filepath, 'utf-8');
  const { meta, body } = parseFrontmatter(content);

  const processed = convertInfoBoxes(body);
  let html = marked(processed);

  const pathParts = filepath.split('/');
  html = fixLinks(html, filepath);

  const title = meta.title || getTitleFromContent(body) || slugToTitle(basename(filepath, '.md'));

  return template
    .replace(/\{\{title\}\}/g, title)
    .replace(/\{\{nav\}\}/g, nav)
    .replace(/\{\{content\}\}/g, html);
}

function buildNav(pages) {
  let html = `<nav>\n<a href="${BASE_PATH}/" class="logo">Tokamak</a>\n`;

  for (const [section, config] of Object.entries(SECTIONS)) {
    const sectionPages = pages.filter(p => p.section === section);
    if (!sectionPages.length) continue;

    html += `<details open><summary>${config.title}</summary>\n<ul>\n`;
    for (const page of sectionPages) {
      const label = page.title === 'Index' ? config.title : page.title;
      html += `<li><a href="${BASE_PATH}/${section}/${page.slug}/">${label}</a></li>\n`;
    }
    html += '</ul>\n</details>\n';
  }

  // Add API link
  html += `<a href="${BASE_PATH}/api/" class="nav-link">API</a>\n`;

  html += '</nav>';
  return html;
}

// Clean dist
if (existsSync(DIST_DIR)) {
  rmSync(DIST_DIR, { recursive: true });
}
mkdirSync(DIST_DIR);

// Copy public assets
if (existsSync(join(DOCS_DIR, 'public'))) {
  cpSync(join(DOCS_DIR, 'public'), DIST_DIR, { recursive: true });
}

// Load template
const template = readFileSync(join(DOCS_DIR, 'template.html'), 'utf-8');

// Collect all pages
const pages = [];

for (const [section, config] of Object.entries(SECTIONS)) {
  const sectionDir = join(DOCS_DIR, section);
  if (!existsSync(sectionDir)) continue;

  for (const file of readdirSync(sectionDir)) {
    if (!file.endsWith('.md')) continue;

    const slug = basename(file, '.md');
    const filepath = join(sectionDir, file);
    const content = readFileSync(filepath, 'utf-8');
    const title = getTitleFromContent(content) || slugToTitle(slug);

    pages.push({
      section,
      slug,
      filepath,
      title,
      order: config.order.indexOf(slug)
    });
  }
}

// Sort pages by section order
pages.sort((a, b) => a.order - b.order);

// Build navigation
const nav = buildNav(pages);

// Build section pages
for (const page of pages) {
  const html = buildPage(page.filepath, template, nav);
  const outDir = join(DIST_DIR, page.section, page.slug);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'index.html'), html);
  console.log(`Built: ${page.section}/${page.slug}`);
}

// Build home page
if (existsSync(join(DOCS_DIR, 'index.md'))) {
  const html = buildHomePage(join(DOCS_DIR, 'index.md'), template, nav);
  writeFileSync(join(DIST_DIR, 'index.html'), html);
  console.log('Built: index');
}

// Build API docs
const apiHtml = buildApiDocs(template, nav);
const apiDir = join(DIST_DIR, 'api');
mkdirSync(apiDir, { recursive: true });
writeFileSync(join(apiDir, 'index.html'), apiHtml);
console.log('Built: api');

console.log(`\nDone! Built ${pages.length + 2} pages.`);
