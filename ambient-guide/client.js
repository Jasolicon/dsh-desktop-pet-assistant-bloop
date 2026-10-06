// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * dsh-ambient-guide —— 客户端模块（可视化 / 可交互控制条）
 *
 * 只在输入框上方画一条控制条，把点击变成 Host 命令；所有逻辑都在 Host（index.js）。
 *
 * 三个必须照做的事实（都从发行包里核出来的，不是猜的）：
 *   1. `conversation.composer.dock` 是 `kind: list, scope: session`，它的 standardProps 里有
 *      **`sessionId: SessionId`**，但**没有** `session` 对象 —— 所以只能靠 sessionId 找会话。
 *   2. 主题令牌的真实名字是 `--dsw-alias-label-primary` / `--dsw-alias-border-l2` /
 *      `--dsw-alias-state-error-primary` 这一族。用错名字会落到回退色，深色主题下文字直接隐形。
 *   3. 只有 `inject: ['slots']` 是安全的；多声明服务会让这个入口整个不激活（实测踩过，
 *      应用会启动失败）。其它服务一律在**点击时**用 ctx.get 惰性取 —— apply 阶段服务可能还没起来。
 *
 * 纪律：不 require 任何 Harness Client 包；不写 document；组件无状态；任何失败都降级成说明文字。
 */
(function registerAmbientGuideClient() {
  const loader = typeof window !== 'undefined' ? window.__ModuleLoader__ : undefined;
  if (!loader || typeof loader.load !== 'function') return;

  loader.load({
    id: 'dsh-ambient-guide',
    factory(require) {
      const React = require('react');
      const h = React.createElement;

      // 真实令牌名（见文件头事实 2）。全部带 inherit 兜底：取不到就跟随宿主文字颜色，绝不隐形。
      const T = {
        label: 'var(--dsw-alias-label-secondary, inherit)',
        labelStrong: 'var(--dsw-alias-label-primary, inherit)',
        border: 'var(--dsw-alias-border-l2, currentColor)',
        danger: 'var(--dsw-alias-state-error-primary, inherit)',
        surface: 'var(--dsw-alias-bg-layer-2, transparent)',
      };

      function describe(error) {
        if (!error) return '命令执行失败';
        if (typeof error === 'string') return error;
        return error.message || error.reason || '命令执行失败';
      }

      /** 会话标识：这个槽给的是 sessionId，其余作为兜底。 */
      function findSessionId(props) {
        if (!props) return null;
        const candidates = [
          props.sessionId,
          props.agentId,
          props.session && props.session.sessionId,
          props.session && props.session.id,
          props.agent && props.agent.id,
          props.conversation && props.conversation.sessionId,
        ];
        for (const candidate of candidates) {
          if (typeof candidate === 'string' && candidate) return candidate;
        }
        return null;
      }

      /** 有的槽会直接给一个带 command() 的会话对象；有就用，省一次远程调用。 */
      function findSelfContainedRunner(props) {
        const candidates = [
          props && props.session,
          props && props.conversation && props.conversation.session,
          props && props.state && props.state.session,
        ];
        for (const candidate of candidates) {
          if (candidate && typeof candidate.command === 'function') return candidate;
        }
        return null;
      }

      /**
       * 惰性解析命令通道。apply 阶段服务可能还没注册，所以必须等到点击时再取。
       * 依次尝试 remote.commands 与 remote.commands 两条常见挂载方式。
       */
      function resolveRemoteCommands(ctx) {
        if (!ctx || typeof ctx.get !== 'function') return null;
        try {
          const direct = ctx.get('remote.commands');
          if (direct && typeof direct.execute === 'function') return direct;
        } catch {
          /* 继续尝试 */
        }
        try {
          const remote = ctx.get('remote');
          if (remote && remote.commands && typeof remote.commands.execute === 'function') return remote.commands;
        } catch {
          /* 放弃 */
        }
        return null;
      }

      function check(result) {
        if (result && result.ok === false) throw new Error(describe(result.error));
        return result;
      }

      /** 返回 { ok, reason, run }。两条路都不通时 ok:false —— UI 置灰并说明原因，绝不抛。 */
      function makeRunner(props, ctx) {
        const selfContained = findSelfContainedRunner(props);
        if (selfContained) {
          return {
            ok: true,
            run: (line) => Promise.resolve().then(() => selfContained.command(line)).then(check),
          };
        }

        const sessionId = findSessionId(props);
        if (!sessionId) {
          const keys = props ? Object.keys(props).slice(0, 14).join(', ') : '(无 props)';
          return { ok: false, reason: `props 里没有 sessionId（收到的键：${keys}）`, run: () => Promise.resolve() };
        }

        // 渲染时先解析一次，好让按钮的可用状态是准的；点击时再解析一次，容忍晚注册。
        const remoteAtRender = resolveRemoteCommands(ctx);
        if (!remoteAtRender) {
          return { ok: false, reason: '命令通道不可用（ctx 里取不到 remote.commands）', run: () => Promise.resolve() };
        }
        return {
          ok: true,
          run: (line) => {
            const remote = resolveRemoteCommands(ctx) || remoteAtRender;
            return Promise.resolve().then(() => remote.execute(sessionId, line, [])).then(check);
          },
        };
      }

      function buttonStyle() {
        return {
          padding: '2px 9px',
          fontSize: '12px',
          lineHeight: '18px',
          fontFamily: 'inherit',
          color: T.labelStrong,
          background: T.surface,
          border: `1px solid ${T.border}`,
          borderRadius: '6px',
          cursor: 'pointer',
          whiteSpace: 'nowrap',
        };
      }

      function Panel(props) {
        const runner = makeRunner(props, props && props.__ambientCtx);
        const disabled = !runner.ok;

        const fire = (line) => () => {
          try {
            Promise.resolve(runner.run(line)).catch((error) => {
              if (typeof console !== 'undefined' && console.warn) {
                console.warn('[ambient-guide] 命令失败：', describe(error), line);
              }
            });
          } catch (error) {
            if (typeof console !== 'undefined' && console.warn) {
              console.warn('[ambient-guide] 命令失败：', describe(error), line);
            }
          }
        };

        const button = (label, line) =>
          h(
            'button',
            {
              type: 'button',
              key: label,
              disabled,
              title: disabled ? runner.reason : line,
              onClick: disabled ? undefined : fire(line),
              style: disabled ? { ...buttonStyle(), cursor: 'not-allowed', opacity: 0.45 } : buttonStyle(),
            },
            label,
          );

        return h(
          'div',
          {
            'data-ambient-guide': 'panel',
            style: {
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
              flexWrap: 'wrap',
              padding: '2px 8px',
              fontSize: '12px',
              lineHeight: '18px',
              color: T.label,
              userSelect: 'none',
            },
          },
          h('span', { style: { fontWeight: 600, color: T.labelStrong } }, '随时指导'),
          button('它知道什么', '/ambient status'),
          button('说一句', '/ambient speak'),
          button('自动开', '/ambient auto on'),
          button('自动关', '/ambient auto off'),
          disabled ? h('span', { style: { color: T.danger } }, `控制条不可用：${runner.reason}`) : null,
        );
      }

      return {
        // 只声明 slots：声明未激活的服务会让这个入口整个不激活（实测踩过）。
        inject: ['slots'],
        apply(ctx) {
          if (!ctx || !ctx.slots || typeof ctx.slots.inject !== 'function') return;

          // 把 ctx 本身递进去，命令通道在点击时才解析（apply 阶段服务可能还没起来）。
          const BoundPanel = (props) => h(Panel, { ...props, __ambientCtx: ctx });

          try {
            ctx.slots.inject('conversation.composer.dock', () =>
              ctx.slots.register(
                { name: 'conversation.composer.dock', id: 'ambient-guide-panel', order: 50 },
                BoundPanel,
              ),
            );
          } catch (error) {
            if (typeof console !== 'undefined' && console.warn) {
              console.warn('[ambient-guide] 控制条未注册：', describe(error));
            }
          }
        },
      };
    },
  });
})();
