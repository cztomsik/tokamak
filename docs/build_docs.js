import { readFileSync, writeFileSync, mkdirSync, cpSync, rmSync, existsSync, globSync } from 'fs'
import { join, basename, relative } from 'path'
import { Marked } from 'marked'
import { h } from 'preact'
import renderToString from 'preact-render-to-string'
import { parse } from './zig-parser.js'
import htm from 'htm'
import _ from 'lodash'

const html = htm.bind(h)

// --- Global Context ---

const cx = {
  DOCS_DIR: 'docs',
  DIST_DIR: 'docs/dist',
  SRC_DIR: 'src',
  BASE_PATH: process.env.BASE_PATH || '',
  SECTIONS: {
    guide: {
      title: 'Guide',
      order: ['getting-started', 'server', 'routing', 'dependency-injection', 'middlewares', 'examples', 'terminal', 'time'],
    },
    examples: {
      title: 'Examples',
      order: ['hello', 'hello_app', 'hello_cli', 'blog', 'todos_orm_sqlite', 'webview_app', 'clown-commander'],
    },
  },
  pages: [],
}

// --- Components ---

const STYLES = `
  @custom-variant dark (&:is(.dark *));

  @layer base {
    html { @apply scroll-smooth; }
    body { @apply antialiased; }
    ::selection { @apply bg-blue-500/20; }
  }

  @layer components {
    main {
      @apply flex-1 px-4 py-6 md:px-6 md:py-10 lg:px-10 lg:py-14;
      h1, h2, h3, h4, h5, h6 { @apply mt-8 mb-3 leading-tight tracking-tight font-bold scroll-mt-20; }
      h1 { @apply text-4xl md:text-5xl text-gray-900 dark:text-white mt-0; }
      h2 { @apply text-2xl md:text-3xl text-gray-900 dark:text-gray-100 border-b border-gray-200 dark:border-gray-800 pb-2; }
      h3 { @apply text-xl md:text-2xl text-gray-800 dark:text-gray-200; }
      h4 { @apply text-lg text-gray-800 dark:text-gray-200; }
      p { @apply my-4 leading-relaxed text-gray-700 dark:text-gray-300; }
      a { @apply text-blue-500 hover:text-blue-600 underline-offset-4 transition-colors; }
      a:hover { @apply underline; }
      code { @apply font-mono text-[0.875rem] bg-gray-100 dark:bg-gray-800/80 text-gray-900 dark:text-gray-100 px-1.5 py-0.5 rounded-md; }
      pre {
        @apply bg-gray-900 dark:bg-gray-950 rounded-xl overflow-hidden my-5 shadow-lg;
      }
      pre code {
        @apply bg-transparent p-5 block text-sm leading-relaxed;
      }
      /* Let highlight.js control code colors; fallback for non-highlighted blocks */
      pre code:not(.hljs) {
        @apply text-gray-100;
      }
      ul { @apply my-4 pl-6 list-disc marker:text-gray-400 dark:marker:text-gray-500; }
      ol { @apply my-4 pl-6 list-decimal marker:text-gray-400 dark:marker:text-gray-500; }
      li { @apply my-1.5 leading-relaxed text-gray-700 dark:text-gray-300; }
      table { @apply w-full my-6 border-collapse text-sm; }
      th { @apply text-left px-4 py-2 font-semibold text-gray-900 dark:text-gray-100 bg-gray-100 dark:bg-gray-800 border border-gray-200 dark:border-gray-700; }
      td { @apply px-4 py-2 text-gray-700 dark:text-gray-300 border border-gray-200 dark:border-gray-700; }
      tr:nth-child(even) td { @apply bg-gray-50 dark:bg-gray-800/50; }
      blockquote { @apply p-4 rounded-lg my-5 border-l-4 bg-gray-50 dark:bg-gray-800/50 border-gray-300 dark:border-gray-600; }
      blockquote.tip { @apply bg-blue-50 dark:bg-blue-950 border-blue-500; }
      blockquote.warning { @apply bg-amber-50 dark:bg-amber-950 border-amber-500; }
      blockquote p { @apply my-2 first:mt-0 last:mb-0; }
      blockquote pre { @apply my-2; }
      hr { @apply my-8 border-gray-200 dark:border-gray-800; }
      img { @apply rounded-lg my-4; }
    }

    /* Shared classes */
    .btn { @apply inline-flex items-center gap-2 px-5 py-2.5 rounded-lg no-underline font-medium text-sm transition-all duration-150; }
    .btn.brand { @apply bg-blue-500 text-white hover:bg-blue-600 shadow-sm hover:shadow; }
    .btn.alt { @apply border border-gray-300 dark:border-gray-700 text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800; }
    .badge { @apply inline-flex items-center text-xs font-medium px-2 py-0.5 rounded-full ml-1.5; }

    /* API docs styles */
    .api-item { @apply flex flex-col border-l-2 my-5 pl-4; }
    .api-item.fn { @apply border-blue-500; }
    .api-item.struct { @apply border-rose-400; }
    .api-item.enum { @apply border-amber-500; }
    .api-item.union { @apply border-violet-400; }
    .api-item.const { @apply border-emerald-500; }
    .api-doc { @apply px-1 mt-1 }
    .api-doc * { @apply bg-transparent text-sm/5 text-gray-600 dark:text-gray-400 border-none list-disc }
    .api-doc :is(h1, h2, h3, h4) { @apply p-0 my-0; }
    .api-decl { @apply bg-gray-900 dark:bg-gray-950 text-gray-100 w-full overflow-x-auto whitespace-pre text-sm font-mono px-4 py-3 rounded-t-lg; scrollbar-width: none; }
  }
`

const HeadScripts = () => {
  // This runs in <head> to prevent flash of wrong theme
  const themeScript = `(function(){var s=localStorage.getItem("theme"),d=window.matchMedia("(prefers-color-scheme:dark)").matches,t=s||(d?"dark":"light");document.documentElement.classList.toggle("dark",t==="dark");window.toggleTheme=function(){document.documentElement.classList.toggle("dark");localStorage.setItem("theme",document.documentElement.classList.contains("dark")?"dark":"light")}})();`

  return html`<script dangerouslySetInnerHTML=${{ __html: themeScript }} />`
}

const BodyScripts = () => {
  const mobileMenuScript = `
    window.toggleMobileMenu = function() {
      var nav = document.getElementById('mobile-nav');
      var overlay = document.getElementById('mobile-overlay');
      var isOpen = nav.classList.contains('translate-x-[-100%]');
      if (isOpen) {
        nav.classList.remove('translate-x-[-100%]');
        nav.classList.add('translate-x-0');
        overlay.classList.remove('hidden');
        document.body.style.overflow = 'hidden';
      } else {
        nav.classList.add('translate-x-[-100%]');
        nav.classList.remove('translate-x-0');
        overlay.classList.add('hidden');
        document.body.style.overflow = '';
      }
    };
    window.addEventListener('resize', function() {
      if (window.innerWidth >= 768) {
        var nav = document.getElementById('mobile-nav');
        var overlay = document.getElementById('mobile-overlay');
        nav.classList.add('translate-x-[-100%]');
        nav.classList.remove('translate-x-0');
        overlay.classList.add('hidden');
        document.body.style.overflow = '';
      }
    });
  `

  const copyScript = `
    document.querySelectorAll('pre').forEach(function(pre) {
      var code = pre.querySelector('code');
      if (!code) return;
      var btn = document.createElement('button');
      btn.className = 'absolute top-2 right-2 p-1.5 rounded-md bg-white/10 text-gray-400 hover:text-white hover:bg-white/20 transition-colors opacity-0 group-hover:opacity-100 focus:opacity-100';
      btn.setAttribute('aria-label', 'Copy code');
      btn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>';
      btn.addEventListener('click', function() {
        navigator.clipboard.writeText(code.textContent).then(function() {
          btn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>';
          setTimeout(function() { btn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>'; }, 2000);
        });
      });
      pre.classList.add('relative', 'group');
      pre.appendChild(btn);
    });
  `

  const highlightScript = `
    document.addEventListener('DOMContentLoaded', function() {
      hljs.highlightAll();
    });
  `

  return html`
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/highlight.min.js"></script>
    <script src="https://unpkg.com/highlightjs-zig@1.0.2/dist/zig.min.js"></script>
    <script dangerouslySetInnerHTML=${{ __html: mobileMenuScript }} />
    <script dangerouslySetInnerHTML=${{ __html: copyScript }} />
    <script dangerouslySetInnerHTML=${{ __html: highlightScript }} />
  `
}

const Header = () => {
  return html`
    <header class="sticky top-0 z-50 border-b border-gray-200 dark:border-gray-800 bg-white/80 dark:bg-gray-900/80 backdrop-blur-md">
      <div class="max-w-7xl mx-auto px-4 md:px-6 h-14 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <button
            onclick="toggleMobileMenu()"
            class="md:hidden w-9 h-9 flex items-center justify-center rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
            aria-label="Toggle menu"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"/></svg>
          </button>
          <a href="${cx.BASE_PATH}/" class="flex items-center gap-2.5 text-gray-900 dark:text-white no-underline font-bold text-lg tracking-tight">
            <span class="inline-flex items-center justify-center w-8 h-8 rounded-lg bg-blue-500 text-white text-sm font-bold">T</span>
            Tokamak
          </a>
        </div>
        <div class="flex items-center gap-3">
          <a href="${cx.BASE_PATH}/api.html" class="text-sm text-gray-500 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white no-underline transition-colors">API</a>
          <a href="https://github.com/cztomsik/tokamak" class="text-sm text-gray-500 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white no-underline transition-colors" target="_blank" rel="noopener noreferrer">Source</a>
          <button
            onclick="toggleTheme()"
            class="w-9 h-9 flex items-center justify-center rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
            aria-label="Toggle dark mode"
          >
            <svg class="w-5 h-5 hidden dark:block" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z"/></svg>
            <svg class="w-5 h-5 block dark:hidden" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z"/></svg>
          </button>
        </div>
      </div>
    </header>
  `
}

const Layout = ({ title, children }) => {
  return html`
    <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>${title} - Tokamak</title>
        <${HeadScripts} />
        <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
        <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/styles/github-dark.min.css" />
        <style type="text/tailwindcss" dangerouslySetInnerHTML=${{ __html: STYLES }} />
      </head>
      <body class="font-sans leading-relaxed text-gray-900 bg-white dark:text-gray-200 dark:bg-gray-900">
        <${Header} />
        <div class="flex min-h-[calc(100vh-3.5rem)]">
          <${Nav} />
          <main class="max-w-4xl xl:max-w-5xl 2xl:max-w-6xl">${children}</main>
        </div>
        <${BodyScripts} />
      </body>
    </html>
  `
}

const Link = ({ href, children }) => {
  const isActive = cx.path === href.replace(/^\//, '').replace(/\.html$/, '')
  const activeClass = isActive
    ? 'bg-blue-500/10 text-blue-500 dark:text-blue-400 font-medium'
    : 'text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800/50'

  return html`<a href="${cx.BASE_PATH}${href}" class="no-underline block px-3 py-1.5 rounded-lg text-sm transition-colors ${activeClass}" onclick="if(window.innerWidth<768)toggleMobileMenu()">${children}</a>`
}

const Nav = () => {
  const sections = Object.entries(cx.SECTIONS).map(([section, config]) => {
    const sectionPages = cx.pages.filter(p => p.section === section)
    if (!sectionPages.length) return null

    return html`
      <details class="group mb-1" open>
        <summary class="font-semibold cursor-pointer py-1 text-xs uppercase tracking-wider text-gray-400 dark:text-gray-500 list-none select-none [&::-webkit-details-marker]:hidden flex items-center">
          <svg class="w-3.5 h-3.5 mr-1 transition-transform group-open:rotate-90" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/></svg>
          ${config.title}
        </summary>
        <ul class="mt-1.5 space-y-0.5">
          ${sectionPages.map(page => {
            const label = page.title === 'Index' ? config.title : page.title
            const pagePath = `${section}/${page.slug}`
            return html`<li><${Link} href="/${pagePath}.html">${label}<//></li>`
          })}
        </ul>
      </details>
    `
  })

  return html`
    <div id="mobile-overlay" class="fixed inset-0 bg-black/40 z-40 hidden md:hidden" onclick="toggleMobileMenu()"></div>
    <nav
      id="mobile-nav"
      class="fixed inset-y-0 left-0 z-50 w-72 max-w-[85vw] p-4 md:p-6 border-r border-gray-200 dark:border-gray-800 bg-gray-50 dark:bg-gray-900 translate-x-[-100%] md:translate-x-0 md:static md:sticky md:top-14 md:h-[calc(100vh-3.5rem)] md:w-64 lg:w-72 overflow-y-auto shrink-0 transition-transform duration-200 ease-in-out"
    >
      ${sections}
      <div class="mt-4 pt-4 border-t border-gray-200 dark:border-gray-800">
        <${Link} href="/api.html">API Reference<//>
      </div>
    </nav>
  `
}

const Page = ({ markdown }) => {
  const contentHtml = marked.parse(markdown)
  return html`<div dangerouslySetInnerHTML=${{ __html: contentHtml }} />`
}

const ApiItem = ({ item }) => {
  const docHtml = item.doc ? marked.parse(item.doc) : null

  switch (item.kind) {
    case 'fn':
      return html`
        <div class="api-item fn">
          <div class="api-decl">pub fn <strong>${item.name}</strong>(${item.params}) ${item.ret}</div>
          ${docHtml && html`<div class="api-doc" dangerouslySetInnerHTML=${{ __html: docHtml }} />`}
        </div>
      `
    case 'export':
      return html`
        <div class="api-item const">
          <div class="api-decl">pub const <strong>${item.name}</strong> = ${item.value}</div>
          ${docHtml && html`<div class="api-doc" dangerouslySetInnerHTML=${{ __html: docHtml }} />`}
        </div>
      `
    default:
      return html`
        <div class="api-item ${item.kind}">
          <div class="api-decl">
            pub const <strong>${item.name}</strong> = ${item.kind}${item.params ?? ''} {
            <div class="pl-8 empty:hidden">${item.fields.join(',\n')}</div>
            }
          </div>
          ${docHtml && html`<div class="api-doc" dangerouslySetInnerHTML=${{ __html: docHtml }} />`}
        </div>
      `
  }
}

const ApiTocItem = ({ file, items }) => {
  const relativePath = relative(cx.SRC_DIR, file)
  const anchorId = makeAnchorId(relativePath)

  return html`
    <li class="py-0.5 break-inside-avoid">
      <a href="#${anchorId}" class="text-blue-500 hover:text-blue-600 no-underline hover:underline font-mono text-sm">${relativePath}</a>
      <span class="badge bg-gray-200 dark:bg-gray-700 text-gray-600 dark:text-gray-300">${items.length}</span>
    </li>
  `
}

const ApiToc = ({ fileData }) => {
  const searchScript = `
    document.getElementById('api-search').addEventListener('input', function(e) {
      const query = e.target.value.toLowerCase();
      document.querySelectorAll('#api-toc li').forEach(li => {
        const text = li.textContent.toLowerCase();
        li.style.display = (query && !text.includes(query)) ? 'none' : '';
      });
    });
  `

  return html`
    <div class="bg-gray-50 dark:bg-gray-800/50 border border-gray-200 dark:border-gray-800 p-5 rounded-xl mb-8">
      <h2 class="mt-0 mb-3 border-0 text-lg">Table of Contents</h2>
      <div class="relative">
        <svg class="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/></svg>
        <input
          type="text"
          id="api-search"
          placeholder="Filter files..."
          autocomplete="off"
          class="w-full pl-9 pr-3 py-2 bg-white dark:bg-gray-900 border border-gray-300 dark:border-gray-700 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-500 transition-all"
        />
      </div>
      <ul id="api-toc" class="list-none p-0 m-0 columns-2 md:columns-3 gap-4 max-h-72 overflow-y-auto mt-4">
        ${fileData.map(({ file, items }) => html`<${ApiTocItem} file=${file} items=${items} />`)}
      </ul>
    </div>
    <script dangerouslySetInnerHTML=${{ __html: searchScript }} />
  `
}

const ApiDocs = ({ fileData }) => {
  const totalItems = fileData.reduce((sum, { items }) => sum + items.length, 0)

  return html`
    <h1>API Reference</h1>
    <p>Auto-generated from source. ${fileData.length} files, ${totalItems} public items.</p>
    <${ApiToc} fileData=${fileData} />
    ${fileData.map(({ file, items }) => {
      const relativePath = relative(cx.SRC_DIR, file)
      const anchorId = makeAnchorId(relativePath)
      return html`
        <section id="${anchorId}">
          <h2>${relativePath}</h2>
          ${items.map(item => html`<${ApiItem} item=${item} />`)}
        </section>
      `
    })}
  `
}

// --- Utility Functions ---

const parseZigFile = filePath => {
  console.log('---', filePath)
  const content = readFileSync(filePath, 'utf-8')
  const ast = parse(content)
  const items = []

  const flatten = (nodes, prefix = '') => {
    for (const node of nodes) {
      const name = prefix ? `${prefix}.${node.name}` : node.name
      items.push({ ...node, name })
      if (node.children) flatten(node.children, name)
    }
  }
  flatten(ast)

  return items
}

const makeAnchorId = _.kebabCase

const processIncludes = markdown =>
  markdown.replace(/```(\w*)\n@include\s+([^\n#]+)(#L(\d+)-L(\d+))?\n```/g, (_, lang, filePath, _range, startLine, endLine) => {
    const fullPath = join(process.cwd(), filePath.trim())

    if (!existsSync(fullPath)) {
      console.warn(`Warning: Include file not found: ${filePath}`)
      return `\`\`\`${lang}\n// File not found: ${filePath}\n\`\`\``
    }

    let content = readFileSync(fullPath, 'utf-8')

    if (startLine && endLine) {
      const lines = content.split('\n')
      const start = parseInt(startLine, 10) - 1
      const end = parseInt(endLine, 10)
      content = lines.slice(start, end).join('\n')
    }

    return `\`\`\`${lang}\n${content}\n\`\`\``
  })

const renderLink = ({ href, title, text }) => {
  if (href.endsWith('.md')) {
    href = href.replace(/\.md$/, '.html')
  }

  if (href.startsWith('/')) {
    href = cx.BASE_PATH + href
  }

  return `<a href="${href}"${title ? ` title="${title}"` : ''}>${text}</a>`
}

const renderBlockquote = function ({ tokens }) {
  const body = this.parser.parse(tokens)
  const match = body.match(/^<p><strong>(Tip|Warning):<\/strong>/)
  const className = match ? ` class="${match[1].toLowerCase()}"` : ''
  return `<blockquote${className}>\n${body}</blockquote>\n`
}

const renderCode = ({ text, lang }) => {
  const langClass = lang ? ` class="language-${lang}"` : ''
  return `<pre><code${langClass}>${text}</code></pre>\n`
}

const getTitleFromContent = content => content.match(/^#\s+(.+)$/m)?.[1] ?? null

const slugToTitle = slug => _.startCase(slug.replace(/_/g, ' '))

// --- Marked Instance ---

const marked = new Marked({
  hooks: { preprocess: processIncludes },
  renderer: { link: renderLink, blockquote: renderBlockquote, code: renderCode },
})

// --- Build Process ---

const buildPage = (path, title, content) => {
  cx.path = path
  const res = '<!DOCTYPE html>\n' + renderToString(html`<${Layout} title=${title}>${content}<//>`)
  const filePath = path ? join(cx.DIST_DIR, path + '.html') : join(cx.DIST_DIR, 'index.html')
  mkdirSync(join(filePath, '..'), { recursive: true })
  writeFileSync(filePath, res)
  console.log(`Built: ${path || 'index'}`)
}

const build = () => {
  // Clean dist
  if (existsSync(cx.DIST_DIR)) {
    rmSync(cx.DIST_DIR, { recursive: true })
  }
  mkdirSync(cx.DIST_DIR)

  // Copy public assets
  if (existsSync(join(cx.DOCS_DIR, 'public'))) {
    cpSync(join(cx.DOCS_DIR, 'public'), cx.DIST_DIR, { recursive: true })
  }

  // Collect all pages
  cx.pages = _.sortBy(
    globSync(`${cx.DOCS_DIR}/{${Object.keys(cx.SECTIONS).join(',')}}/*.md`).map(filepath => {
      const section = basename(join(filepath, '..'))
      const slug = basename(filepath, '.md')
      const content = readFileSync(filepath, 'utf-8')

      return {
        section,
        slug,
        filepath,
        title: getTitleFromContent(content) || slugToTitle(slug),
        order: cx.SECTIONS[section].order.indexOf(slug),
      }
    }),
    'order'
  )

  // Build section pages
  for (const page of cx.pages) {
    const content = readFileSync(page.filepath, 'utf-8')
    buildPage(`${page.section}/${page.slug}`, page.title, html`<${Page} markdown=${content} />`)
  }

  // Build home page
  if (existsSync(join(cx.DOCS_DIR, 'index.md'))) {
    const content = readFileSync(join(cx.DOCS_DIR, 'index.md'), 'utf-8')
    buildPage('', 'Tokamak', html`<${Page} markdown=${content} />`)
  }

  // Build API docs
  const files = globSync('**/*.zig', { cwd: cx.SRC_DIR })
    .map(f => join(cx.SRC_DIR, f))
    .sort()
  const fileData = files
    .map(file => ({
      file,
      items: parseZigFile(file),
    }))
    .filter(({ items }) => items.length > 0)

  buildPage('api', 'API Reference', html`<${ApiDocs} fileData=${fileData} />`)

  console.log(`\nDone! Built ${cx.pages.length + 2} pages.`)
}

// Run when executed directly
if (process.argv[1].endsWith('build_docs.js')) {
  build()
}
