// 大屏 App Worker 脚手架（M1/M2）—— agent 复制到
//   users/<uid>/workspace/.apps/<appId>/<version>.js
// 按需修改：数据表结构、接口、页面。
// 约定：配置由 app_sync 生成，本文件无需改 capnp；
//       页面资产放同目录 www/（disk 绑定，改文件即时生效）；
//       共享前端资产走 /lib/...（平台 app-libs）；
//       应用内接口走 /svc/*（health/spec/events）；
//       实时推送 /svc/events（SSE：前端 EventSource，内部 WebSocket 桥接 Hub DO Hibernation）。
import { DurableObject } from "cloudflare:workers";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".md": "text/markdown; charset=utf-8",
};

// ---------------- 数据层（DO + SQLite，enableSql） ----------------
// 每个 app/版本一个独立 DO 命名空间（config 由 app_sync 生成）。
// 快照模式：数据库只存一行 spec（id="spec"），生成/定时同步/修改都更新这一行。
export class AppStore extends DurableObject {
  constructor(state, env) {
    super(state, env);
    this.sql = state.storage.sql;
  }

  init() {
    // 按业务修改表结构（版本升级 = 新版本文件 + 新数据目录，不迁移旧表）
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS items (" +
        "id TEXT PRIMARY KEY, " +
        "value TEXT NOT NULL, " +
        "ts INTEGER NOT NULL)"
    );
  }

  // 大屏 spec（完整声明式配置）：items 表唯一行 id="spec"（value=JSON 字符串）
  // 前端加载时 GET /svc/spec 取 spec 渲染；更新后经 SSE 广播，前端重拉重渲染。
  getSpec() {
    const row = [...this.sql.exec(
      "SELECT id, value, ts FROM items WHERE id = ?", "spec")][0];
    if (!row) return null;
    try {
      return JSON.parse(row.value);
    } catch (_) {
      return null;
    }
  }

  putSpec(spec) {
    this.sql.exec(
      "INSERT OR REPLACE INTO items (id, value, ts) VALUES (?, ?, ?)",
      "spec",
      JSON.stringify(spec),
      Date.now()
    );
    return this.getSpec();
  }
}

// ---------------- 实时推送（DO WebSocket Hibernation，内部桥接） ----------------
// 浏览器不直接连 WebSocket；/svc/events（SSE）由本 worker 持流，
// 内部再经 WebSocket 连到 Hub DO（可 Hibernation）。数据变更后
// Hub.broadcast 发给所有内部连接，worker 转成 SSE 事件推给前端。
export class Hub extends DurableObject {
  constructor(state, env) {
    super(state, env);
    this.ctx = state;
  }
  async fetch(request) {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }
  broadcast(data) {
    const msg = JSON.stringify(data);
    let n = 0;
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(msg);
        n++;
      } catch (_) {}
    }
    return { sent: n };
  }
}

// ---------------- HTTP 层 ----------------
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const version = request.headers.get("X-App-Version") || "v1";

    if (url.pathname === "/svc/health") {
      return json({ app: "app", version, ok: true });
    }

    // 实时推送（SSE）：EventSource("/svc/events") → 内部 WebSocket 桥 → Hub DO
    if (url.pathname === "/svc/events") {
      const stub = env.Hub.get(env.Hub.idFromName("default"));
      const wsReq = new Request(url.toString(), {
        headers: { Upgrade: "websocket" },
      });
      const wsResp = await stub.fetch(wsReq);
      if (wsResp.status !== 101 || !wsResp.webSocket) {
        return json({ error: "hub unavailable" }, 502);
      }

      const ws = wsResp.webSocket;
      ws.accept();
      const encoder = new TextEncoder();
      let closed = false;
      let heartbeat = null;

      const closeAll = () => {
        if (closed) return;
        closed = true;
        if (heartbeat) clearInterval(heartbeat);
        try { ws.close(); } catch (_) {}
      };

      // 客户端断开（Response 流 cancel）时关闭内部 WebSocket，避免 Hub 上累积死连接
      const stream = new ReadableStream({
        start(controller) {
          const enqueue = (text) => {
            if (closed) return;
            try {
              controller.enqueue(encoder.encode(text));
            } catch (_) {
              closeAll();
            }
          };
          // 连接就绪事件 + 心跳注释行（保持代理/浏览器连接不超时）
          enqueue('event: ready\ndata: {"ok":true}\n\n');
          heartbeat = setInterval(() => enqueue(": ping\n\n"), 25000);
          ws.addEventListener("message", (e) => {
            // SSE 事件名跟随广播类型（当前只有 spec），前端按事件名精确订阅
            let name = "message";
            try {
              const msg = JSON.parse(e.data);
              if (msg && typeof msg.type === "string") name = msg.type;
            } catch (_) {}
            enqueue(`event: ${name}\ndata: ${e.data}\n\n`);
          });
          const finish = () => {
            if (closed) return;
            closed = true;
            if (heartbeat) clearInterval(heartbeat);
            try { controller.close(); } catch (_) {}
            try { ws.close(); } catch (_) {}
          };
          ws.addEventListener("close", finish);
          ws.addEventListener("error", finish);
        },
        cancel() {
          closeAll();
        },
      });

      return new Response(stream, {
        status: 200,
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache, no-transform",
          Connection: "keep-alive",
          "X-Accel-Buffering": "no",
        },
      });
    }

    // 共享前端资产（平台 app-libs，经 disk 绑定；路径 /lib/...）
    if (url.pathname.startsWith("/lib/")) {
      const p = "/" + url.pathname.slice("/lib/".length);
      const res = await env.lib.fetch("http://lib" + p);
      if (res.status === 404) return new Response("not found", { status: 404 });
      const ext = url.pathname.slice(url.pathname.lastIndexOf(".")).toLowerCase();
      return new Response(res.body, {
        headers: { "content-type": MIME[ext] || "application/octet-stream", "cache-control": "no-store" },
      });
    }

    // 静态资产（www/ 内除 index 外的文件，如图片/上传文件；disk 绑定 www/）
    if (!url.pathname.startsWith("/svc/") && !url.pathname.startsWith("/index") && url.pathname !== "/") {
      const ext = url.pathname.slice(url.pathname.lastIndexOf(".")).toLowerCase();
      if (ext && MIME[ext]) {
        const res = await env.files.fetch("http://files" + url.pathname);
        if (res.status !== 404) {
          return new Response(res.body, {
            headers: { "content-type": MIME[ext], "cache-control": "no-store" },
          });
        }
      }
    }

    // 页面（disk 绑定 www/）
    if (url.pathname === "/" || url.pathname.startsWith("/index")) {
      const res = await env.files.fetch("http://files/index.html");
      return new Response(res.body, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }

    const store = env.AppStore.get(env.AppStore.idFromName("default"));
    store.init();
    const hub = () => env.Hub.get(env.Hub.idFromName("default"));

    // 大屏 spec：GET 读取（前端加载时拉取渲染）；POST 写入（agent/定时任务生成后入库）
    if (url.pathname === "/svc/spec" && request.method === "GET") {
      return json({ version, spec: await store.getSpec() });
    }

    if (url.pathname === "/svc/spec" && request.method === "POST") {
      const body = await request.json().catch(() => null);
      if (!body) {
        return json({ error: "body must be JSON" }, 400);
      }
      const spec = body && body.spec !== undefined ? body.spec : body;
      if (!spec || typeof spec !== "object" || Array.isArray(spec)) {
        return json({ error: "spec must be a JSON object" }, 400);
      }
      if (!spec.name || !spec.title) {
        return json({ error: "spec requires name and title" }, 400);
      }
      if (JSON.stringify(spec).length > 2 * 1024 * 1024) {
        return json({ error: "spec too large" }, 400);
      }
      await store.putSpec(spec);
      await hub().broadcast({ type: "spec", reason: "update", ts: Date.now() });
      return json({ version, spec: await store.getSpec() });
    }

    return json({ error: "not found" }, 404);
  },
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}
