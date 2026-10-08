/**
 * dsh-petprobe · Client 半边（浏览器）—— 最小骨架
 *
 * 只做一件事：证明"插件的浏览器半边能被 DSH 加载"（取 `/plugins/dsh-petprobe/client.js` 能拿到，
 * 且页面控制台里能看到下面这行日志）。真要做 UI（设置页/宠物本体）就在这个 apply 里挂 slot。
 */
window.__ModuleLoader__.load({
  id: 'dsh-petprobe',
  factory() {
    return {
      inject: [],
      apply() {
        try {
          console.log('[dsh-petprobe] client 半边加载成功（浏览器侧能跑插件的 JS）');
        } catch {
          /* 控制台打不出来也不能炸 */
        }
      },
    };
  },
});
