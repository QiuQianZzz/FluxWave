import { defineConfig } from 'vitepress'

const zh = {
  label: '简体中文',
  lang: 'zh-CN',
  title: 'FluxWave',
  description: '跨平台聚合音乐播放器，基于 Flutter 构建，主打沉浸式播放体验',
  themeConfig: {
    nav: [
      { text: '指南', link: '/guide/', activeMatch: '^/guide/' },
      { text: '开发文档', link: '/development/overview', activeMatch: '^/development/' },
    ],
    sidebar: {
      '/guide/': [
        {
          text: '用户指南',
          items: [
            { text: '快速开始', link: '/guide/' },
            { text: '播放音乐', link: '/guide/playback' },
            { text: '歌词与播放页体验', link: '/guide/lyrics' },
            { text: '收藏与记录', link: '/guide/collection' },
            { text: '设置与账号', link: '/guide/settings' },
            { text: '隐私与数据', link: '/guide/privacy' },
            { text: '常见问题', link: '/guide/troubleshooting' },
          ],
        },
      ],
      '/development/': [
        {
          text: '开发文档',
          items: [
            { text: '项目概览', link: '/development/overview' },
            { text: '架构要点', link: '/development/architecture' },
            { text: '加解密实现', link: '/development/crypto' },
            { text: '测试', link: '/development/testing' },
            { text: '贡献指南', link: '/development/contributing' },
          ],
        },
      ],
    },
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
          modal: {
            noResultsText: '未找到相关结果',
            resetButtonTitle: '清除查询',
            footer: {
              selectText: '选择',
              navigateText: '切换',
              closeText: '关闭',
            },
          },
        },
      },
    },
    socialLinks: [{ icon: 'github', link: 'https://github.com/QiuQianZzz/FluxWave' }],
    lastUpdated: { text: '最近更新' },
    outline: { label: '本页目录', level: [2, 3] },
    docFooter: { prev: '上一页', next: '下一页' },
    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '菜单',
    darkModeSwitchLabel: '深色模式',
    lightModeSwitchLabel: '浅色模式',
  },
}

export default defineConfig(zh)