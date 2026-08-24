// 大屏 App Worker 脚手架（M1/M2）—— agent 复制到
//   users/<uid>/workspace/.apps/<appId>/<version>.js
// 按需修改：数据表结构、接口、页面。
// 约定：配置由 app_sync 生成，本文件无需改 capnp；
//       页面资产放同目录 www/（disk 绑定，改文件即时生效）；
//       共享前端资产走 /lib/...（平台 app-libs）；
//       实时推送走 /api/ws（DO WebSocket Hibernation，跨请求广播）。
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

  list() {
    return [...this.sql.exec("SELECT id, value, ts FROM items ORDER BY ts DESC")];
  }

  get(id) {
    return [...this.sql.exec("SELECT id, value, ts FROM items WHERE id = ?", id)][0] || null;
  }

  put(id, value) {
    this.sql.exec(
      "INSERT OR REPLACE INTO items (id, value, ts) VALUES (?, ?, ?)",
      id,
      String(value),
      Date.now()
    );
    return this.get(id);
  }

  del(id) {
    this.sql.exec("DELETE FROM items WHERE id = ?", id);
    return { ok: true };
  }

  // 种子/刷新数据：POST /api/refresh {"items":[{id,value,ts?},...]}
  replaceAll(rows) {
    this.sql.exec("DELETE FROM items");
    for (const r of rows || []) {
      this.sql.exec(
        "INSERT OR REPLACE INTO items (id, value, ts) VALUES (?, ?, ?)",
        String(r.id),
        String(r.value ?? ""),
        r.ts ?? Date.now()
      );
    }
    return this.list();
  }
}

// ---------------- 实时推送（DO WebSocket Hibernation） ----------------
// PUT/删除/refresh 后经 Hub.broadcast 向所有连接发送，前端收到即刷新。
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
    const TOKEN = (env.config && env.config.token) || "";
    const authed = () => !TOKEN || request.headers.get("X-App-Token") === TOKEN;

    if (url.pathname === "/api/health") {
      return json({ app: "app", version, ok: true });
    }

    // WebSocket 推送（M2）：升级到 Hub DO（Hibernation）
    if (url.pathname === "/api/ws") {
      if (TOKEN && url.searchParams.get("token") !== TOKEN) {
        return json({ error: "unauthorized" }, 401);
      }
      return env.Hub.get(env.Hub.idFromName("default")).fetch(request);
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
    if (!url.pathname.startsWith("/api/") && !url.pathname.startsWith("/index") && url.pathname !== "/") {
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
      let body = await res.text();
      if (TOKEN) {
        body = body.replace(
          "</head>",
          `<script>window.APP_TOKEN=${JSON.stringify(TOKEN)};</script></head>`
        );
      }
      return new Response(body, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }

    const store = env.AppStore.get(env.AppStore.idFromName("default"));
    store.init();
    const hub = () => env.Hub.get(env.Hub.idFromName("default"));

    if (url.pathname === "/api/data" && request.method === "GET") {
      if (!authed()) return json({ error: "unauthorized" }, 401);
      return json({ version, items: await store.list() });
    }

    if (url.pathname === "/api/refresh" && request.method === "POST") {
      if (!authed()) return json({ error: "unauthorized" }, 401);
      const body = await request.json();
      const items = await store.replaceAll(body.items);
      await hub().broadcast({ type: "data", reason: "refresh", rows: items.length });
      return json({ version, items });
    }

    const dm = url.pathname.match(/^\/api\/data\/([^/]+)$/);
    if (dm) {
      if (!authed()) return json({ error: "unauthorized" }, 401);
      const id = decodeURIComponent(dm[1]);
      switch (request.method) {
        case "GET":
          return json(await store.get(id));
        case "PUT":
        case "POST": {
          const b = await request.json();
          const saved = await store.put(id, b.value ?? b);
          await hub().broadcast({ type: "data", reason: "put", id });
          return json(saved);
        }
        case "DELETE": {
          const r = await store.del(id);
          await hub().broadcast({ type: "data", reason: "delete", id });
          return json(r);
        }
        default:
          return json({ error: "method not allowed" }, 405);
      }
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
