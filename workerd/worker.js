// dagu-gate 控制面 + App Worker 路由（M1）
//
// 控制面：
//   /u/{uid}              -> 校验 uid，写 ws_user Cookie，302 到 /
//   /api/v1/health        -> 健康检查 JSON
//   /api/v1/webhooks/*    -> 校验 Bearer token，原样透传 dagu
//   /api/v1/restart/{uid} -> 注入 user_start token 后转发 dagu
//
// 数据面（App Worker 路由）：
//   /app-proxy/<port>[/...] -> 读 ws_user Cookie 得到 uid，读
//   users/<uid>/workspace/.apps/apps.json（注册表，每请求读，可加缓存），
//   按端口找到 app 与版本（?version= 显式指定或 defaultVersion），
//   通过 service binding 分发到对应 App Worker。
//
// 绑定（见 app_sync 生成的 config.capnp）：
//   env.dagu    -> dagu 管理服务（ExternalServer）
//   env.tokens  -> .webhook-tokens 目录（只读 disk）
//   env.registry-> users 根目录（只读 disk，读 <uid>/workspace/.apps/apps.json）
//   env["app-<uid>-<appId>-<version>"] -> App Worker service

const UID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const ENTRY_RE = /^\/u\/([A-Za-z0-9_.-]+)(\/.*)?$/;
const RESTART_RE = /^\/api\/v1\/restart\/([A-Za-z0-9_.-]+)$/;
const WEBHOOK_RE = /^\/api\/v1\/webhooks\/([A-Za-z0-9_-]+)$/;
const APPPROXY_RE = /^\/app-proxy\/([0-9]+)(\/.*)?$/;
const APPS_SYNC_RE = /^\/api\/v1\/apps\/sync$/;
const APPS_REFRESH_RE = /^\/api\/v1\/apps\/([A-Za-z0-9_-]+)\/refresh$/;
const APPS_DELETE_RE = /^\/api\/v1\/apps\/([A-Za-z0-9_-]+)$/;
const APPS_SELECT_RE = /^\/api\/v1\/apps\/selected$/;
const APPS_APPLY_WWW_RE = /^\/api\/v1\/apps\/apply-www$/;
const APPS_APPLY_META_RE = /^\/api\/v1\/apps\/apply-meta$/;

const TOKEN_FILES = {
  user_create: "user_create.token",
  user_delete: "user_delete.token",
  user_start: "user_start.token",
  app_sync: "app_sync.token",
  app_delete: "app_delete.token",
  app_select: "app_select.token",
  app_apply: "app_apply.token",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // 0) App Worker 路由
    const am = path.match(APPPROXY_RE);
    if (am) return routeApp(request, env, url, am);

    // 1) /u/{uid} 入口：写 Cookie -> 302 到 /
    if (path.startsWith("/u/")) {
      const m = path.match(ENTRY_RE);
      if (!m || !UID_RE.test(m[1])) {
        console.log(`workerd: 400 /u/ invalid path=${path}`);
        return json({ code: "bad_request", message: "invalid uid" }, 400);
      }
      const uid = m[1];
      console.log(`workerd: 302 /u/${uid}`);
      return new Response(null, {
        status: 302,
        headers: {
          Location: "/",
          "Set-Cookie": `ws_user=${uid}; Path=/; SameSite=Lax; HttpOnly`,
        },
      });
    }

    // 2) 健康检查
    if (path === "/api/v1/health") {
      console.log("workerd: 200 /api/v1/health");
      return json({ status: "healthy", timestamp: new Date().toISOString() });
    }

    // 2.5) 大屏列表页（当前用户的 .apps 注册表）
    if (path === "/apps" || path === "/apps/") {
      return appsPage(request, env);
    }

    // 2.6) 生成物门户页与静态资产
    if (path === "/workspace" || path === "/workspace/") {
      return portalPage(request, env);
    }
    if (path.startsWith("/portal/")) {
      return portalAsset(request, env);
    }

    // 3) 内部路由：启动页触发容器恢复
    if (path.startsWith("/api/v1/restart/")) {
      const m = path.match(RESTART_RE);
      if (!m || !UID_RE.test(m[1])) {
        console.log(`workerd: 400 restart path=${path}`);
        return json({ code: "bad_request", message: "invalid uid" }, 400);
      }
      const uid = m[1];
      console.log(`workerd: restart uid=${uid} -> dagu user_start`);
      return forwardToDagu(env, "user_start", request);
    }

    // 3.5) 内部路由：agent 发布 App（注入 app_sync token，无需外部密钥）
    if (path.startsWith("/api/v1/apps/sync")) {
      const m = path.match(APPS_SYNC_RE);
      if (!m) return json({ code: "bad_request", message: "invalid path" }, 400);
      const uid = readCookie(request.headers.get("Cookie") || "", "ws_user");
      if (!uid || !UID_RE.test(uid)) {
        return json({ code: "unauthorized", message: "missing ws_user cookie" }, 401);
      }
      console.log(`workerd: apps/sync uid=${uid} -> dagu app_sync`);
      const body = JSON.stringify({ payload: { uid } });
      const injected = new Request("http://internal" + path, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
      });
      return forwardToDagu(env, "app_sync", injected);
    }

    // 3.55) 内部路由：修改现有大屏（平台强制目标 = .selected，agent 不能自选）
    if (path === "/api/v1/apps/apply-www" && request.method === "POST") {
      return appsApply(request, env, "www");
    }
    if (path === "/api/v1/apps/apply-meta" && request.method === "POST") {
      return appsApply(request, env, "meta");
    }

    // 3.6) 内部路由：app_sync_data 定时同步写回（POST /api/v1/apps/<appId>/refresh）
    if (path.startsWith("/api/v1/apps/")) {
      if (path === "/api/v1/apps/selected" && request.method === "PUT") {
        return appsSelect(request, env);
      }
      if (request.method === "DELETE") {
        const m = path.match(APPS_DELETE_RE);
        if (!m) return json({ code: "bad_request", message: "invalid path" }, 400);
        return appsDelete(request, env, m);
      }
      const m = path.match(APPS_REFRESH_RE);
      if (!m) return json({ code: "bad_request", message: "invalid path" }, 400);
      return appsRefresh(request, env, url, m);
    }

    // 3.7) 生成物清单（门户页数据源）
    if (path === "/api/v1/apps" && request.method === "GET") {
      return appsList(request, env);
    }



    // 4) 门户 webhook：校验 token 后原样透传
    const m = path.match(WEBHOOK_RE);
    if (m) {
      const name = m[1];
      if (!TOKEN_FILES[name]) {
        console.log(`workerd: 404 webhook ${name}`);
        return json({ code: "not_found", message: "unknown webhook" }, 404);
      }
      const auth = request.headers.get("Authorization") || "";
      const token = auth.replace(/^Bearer\s+/i, "").trim();
      const expected = (await readToken(env, name)).trim();
      if (!token || token !== expected) {
        console.log(`workerd: 401 webhook ${name}`);
        return json({ code: "unauthorized", message: "invalid webhook token" }, 401);
      }
      console.log(`workerd: forward webhook ${name}`);
      return env.dagu.fetch(request);
    }

    // 5) 其余路径
    console.log(`workerd: 404 ${request.method} ${path}`);
    return json({ code: "not_found", message: "not found" }, 404);
  },
};

// ==================== App Worker 路由 ====================
async function routeApp(request, env, url, m) {
  const port = m[1];
  const rest = m[2] || "/";
  const uid = readCookie(request.headers.get("Cookie") || "", "ws_user");
  if (!uid || !UID_RE.test(uid)) {
    return json({ code: "unauthorized", message: "missing ws_user cookie" }, 401);
  }

  const manifest = await loadManifest(env, uid);
  if (manifest === null) {
    return json({ code: "not_found", message: `no apps registry for ${uid}` }, 404);
  }
  if (manifest === undefined) {
    return json({ code: "internal_error", message: "registry read failed" }, 500);
  }

  const app = (manifest.apps || []).find(a => String(a.port) === port);
  if (!app) return json({ code: "not_found", message: `unknown app port ${port}` }, 404);
  const version = url.searchParams.get("version") || app.defaultVersion;
  const v = app.versions && app.versions[version];
  if (!v) return json({ code: "not_found", message: `unknown version ${version}` }, 404);

  const svc = serviceName(uid, app.id, version);
  const target = env[svc];
  if (!target) return json({ code: "internal_error", message: `service ${svc} not bound` }, 503);

  const u = new URL(request.url);
  u.searchParams.delete("version");
  const next = new Request("http://internal" + rest + u.search, request);
  next.headers.set("X-App-Id", app.id);
  next.headers.set("X-App-Version", version);
  return target.fetch(next);
}

// 大屏列表页：列出当前 uid 的所有 app（含版本与链接）
async function appsPage(request, env) {
  const uid = readCookie(request.headers.get("Cookie") || "", "ws_user");
  if (!uid || !UID_RE.test(uid)) {
    return json({ code: "unauthorized", message: "missing ws_user cookie" }, 401);
  }
  const manifest = await loadManifest(env, uid);
  const apps = manifest && manifest.apps ? manifest.apps : [];
  const rows = apps
    .map(a => {
      const versions = Object.keys(a.versions || {});
      const links = versions
        .map(v => `<a href="/app-proxy/${a.port}/?version=${v}">${v}</a>`)
        .join(" · ");
      return `<li><b>${escapeHtml(a.id)}</b>（端口 ${a.port}，默认 ${escapeHtml(a.defaultVersion || "")}）— ${links}
        <button onclick="del('${escapeHtml(a.id)}')">删除</button></li>`;
    })
    .join("\n");
  const html = `<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>我的大屏</title>
<style>body{font-family:sans-serif;background:#0f1115;color:#e6e6e6;padding:32px}
a{color:#4c8dff;margin-right:8px}li{margin:10px 0}button{background:#ff4d4f;color:#fff;border:0;border-radius:4px;padding:2px 10px;cursor:pointer}</style></head>
<body><h1>我的大屏（${escapeHtml(uid)}）</h1><ul>${rows || "<li>暂无大屏</li>"}</ul></body></html>`;
  const script = `<script>
async function del(id){ if(!confirm('确定删除 '+id+' 吗？')) return; await fetch('/api/v1/apps/'+encodeURIComponent(id),{method:'DELETE'}); location.reload(); }
</script>`;
  return new Response(html.replace("</h1><ul>", '</h1><p><a href="/workspace" style="color:#4c8dff">进入工作台</a></p><ul>').replace("</body>", script + "</body>"), {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}

// 生成物门户页：左固定可折叠对话 + 右生成物画廊/切换展示
async function portalPage(request, env) {
  const uid = readCookie(request.headers.get("Cookie") || "", "ws_user");
  if (!uid || !UID_RE.test(uid)) {
    return json({ code: "unauthorized", message: "missing ws_user cookie" }, 401);
  }
  const res = await env.portal.fetch("http://portal/index.html");
  if (!res.ok) return json({ code: "internal_error", message: "portal not found" }, 500);
  return new Response(res.body, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}

// 门户静态资产（/portal/* → portal 目录）
async function portalAsset(request, env) {
  const p = "/" + request.url.split("/portal/")[1] || "/";
  const res = await env.portal.fetch("http://portal" + p);
  if (res.status === 404) return new Response("not found", { status: 404 });
  const ext = p.slice(p.lastIndexOf(".")).toLowerCase();
  const mime = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
  };
  return new Response(res.body, {
    headers: { "content-type": mime[ext] || "application/octet-stream", "cache-control": "no-store" },
  });
}

// 生成物清单（门户数据源；含轻量探活状态，不含 token）
async function appsList(request, env) {
  const uid = readCookie(request.headers.get("Cookie") || "", "ws_user");
  if (!uid || !UID_RE.test(uid)) {
    return json({ code: "unauthorized", message: "missing ws_user cookie" }, 401);
  }
  const manifest = await loadManifest(env, uid);
  const apps = manifest && manifest.apps ? manifest.apps : [];
  const lastPublish = (manifest && manifest._meta && manifest._meta.lastPublish) || 0;
  const out = [];
  for (const a of apps) {
    const dv = a.defaultVersion || Object.keys(a.versions || {})[0] || "v1";
    const status = await probeApp(env, uid, a.id, dv);
    const rev = await appRev(env, uid, a.id);
    out.push({
      id: a.id,
      title: a.title || a.id,
      description: a.description || "",
      createdAt: a.createdAt || null,
      type: a.type || "dashboard",
      port: a.port,
      defaultVersion: dv,
      versions: Object.keys(a.versions || {}),
      status,
      rev,
    });
  }
  const ts = v => (typeof v === "number" ? v : Date.parse(v || "") || 0);
  out.sort((x, y) => ts(y.createdAt) - ts(x.createdAt));
  return json({ uid, lastPublish, apps: out });
}

async function probeApp(env, uid, appId, version) {
  const target = env[serviceName(uid, appId, version)];
  if (!target) return "not_published";
  try {
    const res = await target.fetch("http://internal/api/health", { signal: AbortSignal.timeout(2000) });
    return res.ok ? "running" : "error";
  } catch (_) {
    return "error";
  }
}

// 页面内容版本：由 www/index.html 内容算出轻量哈希，门户据此在"改页面文件不发布"时
// 也能自动刷新预览（发布 → lastPublish 变化；页面直改 → rev 变化）
async function appRev(env, uid, appId) {
  try {
    const res = await env.registry.fetch(
      `http://registry/${uid}/workspace/.apps/${appId}/www/index.html`
    );
    if (!res.ok) return 0;
    const b = new Uint8Array(await res.arrayBuffer());
    if (!b.length) return 0;
    let h = 0;
    const step = Math.max(1, Math.floor(b.length / 64));
    for (let i = 0; i < b.length; i += step) h = (h * 31 + b[i]) >>> 0;
    return b.length + ":" + h;
  } catch (_) {
    return 0;
  }
}

// 数据同步写回：转发 POST /api/refresh 到 app 默认版本（或 ?version= 指定）
async function appsRefresh(request, env, url, m) {
  const appId = m[1];
  const uid = readCookie(request.headers.get("Cookie") || "", "ws_user");
  if (!uid || !UID_RE.test(uid)) {
    return json({ code: "unauthorized", message: "missing ws_user cookie" }, 401);
  }
  const manifest = await loadManifest(env, uid);
  if (manifest === null) return json({ code: "not_found", message: "no apps registry" }, 404);
  const app = (manifest.apps || []).find(a => a.id === appId);
  if (!app) return json({ code: "not_found", message: `unknown app ${appId}` }, 404);
  const version = url.searchParams.get("version") || app.defaultVersion;
  const v = app.versions && app.versions[version];
  if (!v) return json({ code: "not_found", message: `unknown version ${version}` }, 404);
  const target = env[serviceName(uid, appId, version)];
  if (!target) return json({ code: "internal_error", message: "service not bound" }, 503);
  const headers = { "Content-Type": "application/json", "X-App-Id": appId, "X-App-Version": version };
  const appToken = request.headers.get("X-App-Token");
  if (appToken) headers["X-App-Token"] = appToken;
  const next = new Request("http://internal/api/refresh", { method: "POST", headers, body: await request.text() });
  return target.fetch(next);
}

// 删除 app：注入 app_delete token 转发 dagu（摘除/归档/重建配置）
async function appsDelete(request, env, m) {
  const appId = m[1];
  const uid = readCookie(request.headers.get("Cookie") || "", "ws_user");
  if (!uid || !UID_RE.test(uid)) {
    return json({ code: "unauthorized", message: "missing ws_user cookie" }, 401);
  }
  const body = JSON.stringify({ payload: { uid, appId } });
  const injected = new Request("http://internal" + request.url.replace(/^https?:\/\/[^/]+/, ""), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
  return forwardToDagu(env, "app_delete", injected);
}

// 记录当前选中生成物（供 agent 上下文感知）
async function appsSelect(request, env) {
  const uid = readCookie(request.headers.get("Cookie") || "", "ws_user");
  if (!uid || !UID_RE.test(uid)) {
    return json({ code: "unauthorized", message: "missing ws_user cookie" }, 401);
  }
  let appId = "";
  try {
    const body = await request.json();
    appId = (body && body.id) || "";
  } catch (_) {}
  if (!appId || !/^[A-Za-z0-9_-]{1,64}$/.test(appId)) {
    return json({ code: "bad_request", message: "invalid app id" }, 400);
  }
  const injected = new Request("http://internal/api/v1/apps/selected", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ payload: { uid, appId } }),
  });
  return forwardToDagu(env, "app_select", injected);
}

// 修改现有大屏：平台强制目标 = .selected（agent 不能自选）。
//  - mode=www : 把用户工作区 temp/modify-www.html 应用到选中 app 的 www/index.html
//  - mode=meta: 更新选中 app 的 apps.json title/description
// 用户显式点名其他 app 时，agent 应先把 .selected 写为目标 app，再调用本接口。
async function appsApply(request, env, mode) {
  const uid = readCookie(request.headers.get("Cookie") || "", "ws_user");
  if (!uid || !UID_RE.test(uid)) {
    return json({ code: "unauthorized", message: "missing ws_user cookie" }, 401);
  }
  let body = {};
  try {
    body = await request.json();
  } catch (_) {}
  const sel = await readSelected(env, uid);
  if (!sel || !sel.id) {
    return json({ code: "bad_request", message: "no selected app (.selected)" }, 400);
  }
  const appId = String(sel.id);
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(appId)) {
    return json({ code: "bad_request", message: "invalid selected app" }, 400);
  }
  const payload = { uid, appId, mode };
  if (mode === "meta") {
    payload.title = String(body.title || "").slice(0, 200);
    payload.description = String(body.description || "").slice(0, 500);
  }
  console.log(`workerd: apps/apply-${mode} uid=${uid} target=${appId} -> dagu app_apply`);
  const injected = new Request("http://internal/api/v1/apps/apply-" + mode, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ payload }),
  });
  return forwardToDagu(env, "app_apply", injected);
}

// 读当前选中标记：users/<uid>/workspace/.apps/.selected
async function readSelected(env, uid) {
  try {
    const res = await env.registry.fetch(`http://registry/${uid}/workspace/.apps/.selected`);
    if (!res.ok) return null;
    return JSON.parse(await res.text());
  } catch (_) {
    return null;
  }
}

// 读注册表（每请求读；生产可加 mtime 缓存，版本切换仍零 config）
// 返回：manifest / null（无注册表）/ undefined（读取失败）
async function loadManifest(env, uid) {
  const res = await env.registry.fetch(`http://registry/${uid}/workspace/.apps/apps.json`);
  if (res.status === 404) return null;
  if (!res.ok) {
    console.log(`workerd: registry read failed status=${res.status} uid=${uid}`);
    return undefined;
  }
  try {
    return JSON.parse(await res.text());
  } catch (_) {
    return undefined;
  }
}

// 服务名派生规则必须与 app_sync 一致：app-<uid>-<appId>-<version>
function serviceName(uid, appId, version) {
  return `app-${uid}-${appId}-${version}`;
}

function readCookie(header, name) {
  for (const part of header.split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
  }
  return "";
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[c]);
}

// ==================== 控制面辅助 ====================
async function forwardToDagu(env, dagName, request) {
  const rawBody = await request.text();
  try {
    JSON.parse(rawBody);
  } catch (_) {
    console.log(`workerd: 400 webhook ${dagName} invalid JSON body`);
    return json({ code: "bad_request", message: "invalid JSON body" }, 400);
  }
  const token = (await readToken(env, dagName)).trim();
  const upstream = new Request(`http://dagu/api/v1/webhooks/${dagName}`, {
    method: request.method,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: rawBody,
  });
  return env.dagu.fetch(upstream);
}

async function readToken(env, name) {
  const res = await env.tokens.fetch(`http://dummy/${TOKEN_FILES[name]}`);
  if (!res.ok) return "";
  return await res.text();
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
