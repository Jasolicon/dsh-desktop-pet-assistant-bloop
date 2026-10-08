/**
 * dsh-bloop · Client 半边（浏览器）
 *
 * 现在只是骨架：证明插件的浏览器半边能被 DSH 加载。**桌宠的界面本体不需要它** ——
 * 那是引擎自己的 WinForms/Electron 窗口，跑在独立进程里（这也是我们和 dsh-pet 最大的区别：
 * 它是"住在 DSH 页面里/跟着 DSH 开窗"，我们是"独立进程 + 插件只是分发与接口"）。
 *
 * 将来要往这里放的是"和 DSH 界面贴在一起的东西"：设置页入口、状态角标之类。
 */
window.__ModuleLoader__.load({
  id: 'dsh-bloop',
  factory() {
    return {
      inject: [],
      apply() {
        try {
          console.log('[dsh-bloop] client 半边加载成功');
        } catch {
          /* 打不出来也不能炸 */
        }
      },
    };
  },
});
