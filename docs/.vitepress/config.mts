import { defineConfig } from 'vitepress'

export default defineConfig({
  title: "Tokamak",
  description: "A server-side framework for Zig",
  base: '/tokamak/',
  ignoreDeadLinks: [
    // Ignore localhost URLs in examples - these are valid URLs users visit when running examples
    /^http:\/\/localhost:\d+/
  ],

  themeConfig: {
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Examples', link: '/guide/examples' },
      { text: 'Reference', link: '/monitoring' }
    ],

    sidebar: {
      '/guide/': [
        {
          text: 'Guide',
          items: [
            { text: 'Getting Started', link: '/guide/getting-started' },
            { text: 'Server', link: '/guide/server' },
            { text: 'Routing', link: '/guide/routing' },
            { text: 'Dependency Injection', link: '/guide/dependency-injection' },
            { text: 'Middlewares', link: '/guide/middlewares' }
          ]
        }
      ],
      '/examples/': [
        {
          text: 'Examples',
          items: [
            { text: 'Overview', link: '/guide/examples' },
            { text: 'hello', link: '/examples/hello' },
            { text: 'hello_app', link: '/examples/hello_app' },
            { text: 'blog', link: '/examples/blog' },
            { text: 'todos_orm_sqlite', link: '/examples/todos_orm_sqlite' },
            { text: 'hello_cli', link: '/examples/hello_cli' },
            { text: 'clown-commander', link: '/examples/clown-commander' },
            { text: 'webview_app', link: '/examples/webview_app' },
            { text: 'hello_ai', link: '/examples/hello_ai' }
          ]
        }
      ],
      '/': [
        {
          text: 'Reference',
          items: [
            { text: 'Server', link: '/server' },
            { text: 'Routing', link: '/routing' },
            { text: 'Dependency Injection', link: '/dependency-injection' },
            { text: 'Process Monitoring', link: '/monitoring' },
            { text: 'CLI', link: '/cli' },
            { text: 'TUI', link: '/tui' }
          ]
        }
      ]
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/cztomsik/tokamak' }
    ]
  }
})
