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
      order: [
        'getting-started',
        'server',
        'routing',
        'dependency-injection',
        'middlewares',
        'examples',
        'terminal',
        'time',
      ],
    },
    examples: {
      title: 'Examples',
      order: ['hello', 'hello_app', 'hello_cli', 'hello_ai', 'blog', 'todos_orm_sqlite', 'webview_app', 'clown-commander'],
    },
  },
  pages: [],
}

// --- Components ---

const STYLES = `
  @theme {
    --color-tip-bg: #f0f7ff;
    --color-tip-border: #3451b2;
    --color-warning-bg: #fff8e6;
    --color-warning-border: #e6a700;
    --color-tip-bg-dark: #1a2433;
    --color-warning-bg-dark: #2d2a1a;
  }

  @layer components {
    main {
      @apply flex-1 max-w-4xl xl:max-w-6xl 2xl:max-w-7xl p-6 md:p-8;
      h1, h2, h3, h4 { @apply mt-6 mb-2 leading-tight font-semibold; }
      h1 { @apply text-3xl mt-0; }
      h2 { @apply text-2xl border-b border-gray-200 dark:border-gray-700 pb-1; }
      h3 { @apply text-xl; }
      p { @apply my-4; }
      a { @apply text-blue-600 dark:text-blue-400; }
      code { @apply font-mono text-sm bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 rounded; }
      pre { @apply bg-gray-100 dark:bg-gray-800 p-4 rounded-md max-h-[60vh] overflow-auto my-4; }
      pre code { @apply bg-transparent p-0; }
      ul { @apply my-4 pl-6 list-disc; }
      ol { @apply my-4 pl-6 list-decimal; }
      li { @apply my-1; }
      blockquote { @apply p-4 rounded-md my-4 border-l-4 bg-gray-100 dark:bg-gray-800 border-gray-300 dark:border-gray-600; }
      blockquote.tip { @apply bg-tip-bg dark:bg-tip-bg-dark border-tip-border; }
      blockquote.warning { @apply bg-warning-bg dark:bg-warning-bg-dark border-warning-border; }
      blockquote p { @apply my-2 first:mt-0 last:mb-0; }
      blockquote pre { @apply my-2; }
    }

    /* Shared classes / daisy-style components */
    .btn { @apply inline-block px-6 py-3 rounded-md no-underline font-medium; }
    .btn.brand { @apply bg-blue-600 text-white hover:bg-blue-700; }
    .btn.alt { @apply border border-gray-200 dark:border-gray-700 text-gray-900 dark:text-gray-100 hover:border-gray-400; }
    .badge { @apply inline-block text-xs px-1.5 py-0.5 rounded ml-1 text-white; }

    /* API docs styles */
    .api-item { @apply flex flex-col border-l-2 my-4; }
    .api-item.fn { @apply border-blue-500; }
    .api-item.struct { @apply border-red-400; }
    .api-item.enum { @apply border-yellow-500; }
    .api-item.union { @apply border-purple-400; }
    .api-item.const { @apply border-green-500; }
    .api-doc { @apply px-4 }
    .api-doc * { @apply bg-transparent text-sm/5 text-gray-600 dark:text-gray-300 border-none list-disc }
    .api-doc :is(h1, h2, h3, h4) { @apply p-0 my-0; }
    .api-decl { @apply bg-gray-100 dark:bg-gray-800 w-full overflow-x-auto whitespace-pre text-sm font-mono px-4 py-2; scrollbar-width: none; }
  }
`

const Layout = ({ title, children }) => {
  return html`
    <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>${title} - Tokamak</title>
        <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
        <style type="text/tailwindcss">
          ${STYLES}
        </style>
      </head>
      <body class="font-sans leading-relaxed text-gray-900 bg-white dark:text-gray-200 dark:bg-gray-900">
        <div class="flex min-h-screen flex-col md:flex-row">
          <${Nav} />
          <main>${children}</main>
        </div>
      </body>
    </html>
  `
}

const Nav = () => {
  const linkClasses = 'text-gray-500 dark:text-gray-400 no-underline hover:text-blue-600 dark:hover:text-blue-400'

  const sections = Object.entries(cx.SECTIONS).map(([section, config]) => {
    const sectionPages = cx.pages.filter(p => p.section === section)
    if (!sectionPages.length) return null

    return html`
      <details class="group mb-4" open>
        <summary class="font-semibold cursor-pointer py-1 list-none [&::-webkit-details-marker]:hidden">
          <span class="text-gray-500 group-open:hidden">▸ </span>
          <span class="text-gray-500 hidden group-open:inline">▾ </span>
          ${config.title}
        </summary>
        <ul class="mt-2 ml-4 flex flex-wrap gap-x-4 md:block">
          ${sectionPages.map(page => {
            const label = page.title === 'Index' ? config.title : page.title
            return html`<li><a href="${cx.BASE_PATH}/${section}/${page.slug}/" class="${linkClasses}">${label}</a></li>`
          })}
        </ul>
      </details>
    `
  })

  return html`
    <nav
      class="w-full md:w-64 p-6 border-b md:border-b-0 md:border-r border-gray-200 dark:border-gray-700 md:sticky md:top-0 md:h-screen overflow-y-auto shrink-0"
    >
      <a href="${cx.BASE_PATH}/" class="font-bold text-xl text-gray-900 dark:text-gray-100 no-underline block mb-6"
        >Tokamak</a
      >
      ${sections}
      <a href="${cx.BASE_PATH}/api/" class="${linkClasses}">API Reference</a>
    </nav>
  `
}

const Page = ({ contentHtml }) => {
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
      <a href="#${anchorId}" class="text-blue-600 dark:text-blue-400 no-underline hover:underline">${relativePath}</a>
      <span class="badge bg-gray-400 dark:bg-gray-900">${items.length}</span>
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
    <div class="bg-gray-100 dark:bg-gray-800 p-4 rounded-lg mb-8">
      <h2 class="mt-0 mb-2 border-0 text-lg">Table of Contents</h2>
      <input
        type="text"
        id="api-search"
        placeholder="Filter files..."
        autocomplete="off"
        class="w-full p-2 mb-3 bg-white dark:bg-gray-900 border border-gray-300 dark:border-gray-600 rounded text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
      />
      <ul id="api-toc" class="list-none p-0 m-0 columns-2 md:columns-3 gap-4 max-h-64 overflow-y-auto">
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

const styleBlockquotes = html =>
  html.replace(/<blockquote>\s*<p><strong>(Tip|Warning):<\/strong>/g, (_, type) =>
    `<blockquote class="${type.toLowerCase()}"><p><strong>${type}:</strong>`
  )

const processIncludes = markdown =>
  markdown.replace(
    /```(\w*)\n@include\s+([^\n#]+)(#L(\d+)-L(\d+))?\n```/g,
    (_, lang, filePath, _range, startLine, endLine) => {
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
    }
  )

const renderLink = ({ href, title, text }) => {
  if (href.startsWith('./') && href.endsWith('.md')) {
    href = '../' + href.slice(2).replace(/\.md$/, '/')
  } else if (href.endsWith('.md')) {
    href = href.replace(/\.md$/, '/')
  }

  if (href.startsWith('/')) {
    href = cx.BASE_PATH + href
    if (!href.endsWith('/') && !href.includes('.')) {
      href += '/'
    }
  }

  return `<a href="${href}"${title ? ` title="${title}"` : ''}>${text}</a>`
}

const getTitleFromContent = content => content.match(/^#\s+(.+)$/m)?.[1] ?? null

const slugToTitle = slug => _.startCase(slug.replace(/_/g, ' '))

// --- Marked Instance ---

const marked = new Marked({
  hooks: { preprocess: processIncludes, postprocess: styleBlockquotes },
  renderer: { link: renderLink }
})

// --- Render Helpers ---

const renderPage = (title, content) => '<!DOCTYPE html>\n' + renderToString(html`<${Layout} title=${title}>${content}<//>`)

// --- Build Process ---

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

    const contentHtml = marked.parse(content)

    const finalHtml = renderPage(page.title, html`<${Page} contentHtml=${contentHtml} />`)

    const outDir = join(cx.DIST_DIR, page.section, page.slug)
    mkdirSync(outDir, { recursive: true })
    writeFileSync(join(outDir, 'index.html'), finalHtml)
    console.log(`Built: ${page.section}/${page.slug}`)
  }

  // Build home page
  if (existsSync(join(cx.DOCS_DIR, 'index.md'))) {
    const content = readFileSync(join(cx.DOCS_DIR, 'index.md'), 'utf-8')
    const contentHtml = marked.parse(content)

    const finalHtml = renderPage('Tokamak', html`<${Page} contentHtml=${contentHtml} />`)

    writeFileSync(join(cx.DIST_DIR, 'index.html'), finalHtml)
    console.log('Built: index')
  }

  // Build API docs
  const files = globSync('**/*.zig', { cwd: cx.SRC_DIR }).map(f => join(cx.SRC_DIR, f)).sort()
  const fileData = files
    .map(file => ({
      file,
      items: parseZigFile(file),
    }))
    .filter(({ items }) => items.length > 0)

  const apiHtml = renderPage('API Reference', html`<${ApiDocs} fileData=${fileData} />`)

  const apiDir = join(cx.DIST_DIR, 'api')
  mkdirSync(apiDir, { recursive: true })
  writeFileSync(join(apiDir, 'index.html'), apiHtml)
  console.log('Built: api')

  console.log(`\nDone! Built ${cx.pages.length + 2} pages.`)
}

// Run when executed directly
if (process.argv[1].endsWith('build_docs.js')) {
  build()
}
