// dagu-gate 控制面逻辑服务（workerd）
//
// 接收 Caddy 转发的控制面请求并做业务判断：
//   /u/{uid}              -> 校验 uid，写 ws_user Cookie，302 到 /
//   /api/v1/health        -> 健康检查 JSON
//   /api/v1/webhooks/*    -> 校验 Bearer token，原样透传给 dagu
//   /api/v1/restart/{uid} -> 内部路由，注入 token 后转发 dagu user_start
// 其余路径返回 404。
//
// 绑定（见 config.capnp）：
//   env.dagu   -> dagu 管理服务（ExternalServer）
//   env.tokens -> .webhook-tokens 目录（只读，disk 绑定）

const UID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const ENTRY_RE = /^\/u\/([A-Za-z0-9_.-]+)(\/.*)?$/;
const RESTART_RE = /^\/api\/v1\/restart\/([A-Za-z0-9_.-]+)$/;
const WEBHOOK_RE = /^\/api\/v1\/webhooks\/([A-Za-z0-9_-]+)$/;

const TOKEN_FILES = {
  user_create: "user_create.token",
  user_delete: "user_delete.token",
  user_start: "user_start.token",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

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

// 转发到 dagu：restart 需要把路径改成 webhook 并注入 token。
// 转发前先校验 JSON：当前 dagu 构建对空/非法 JSON 会 panic（返回 500），
// 这里在 workerd 层直接返回 400，避免坏请求到达 dagu。
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

// 从 .webhook-tokens/ 只读读取 token（disk 绑定暴露为 HTTP 接口）
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
