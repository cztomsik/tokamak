import { defineConfig } from 'vitepress'

export default defineConfig({
  title: "Tokamak",
  description: "A server-side framework for Zig",
  base: '/tokamak/',

  themeConfig: {
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Guide', link: '/guide/getting-started' }
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Server', link: '/guide/server' },
          { text: 'Routing', link: '/guide/routing' },
          { text: 'Dependency Injection', link: '/guide/dependency-injection' },
          { text: 'Middlewares', link: '/guide/middlewares' },
          { text: 'Process Monitoring', link: '/guide/monitoring' },
          { text: 'CLI', link: '/guide/cli' },
          { text: 'TUI', link: '/guide/tui' }
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/cztomsik/tokamak' }
    ]
  }
})
