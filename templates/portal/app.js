// 智能体工作台：生成物列表 + 切换展示
const $ = id => document.getElementById(id);
const cardsEl = $("cards"), emptyEl = $("empty");
let selected = null; // {id, port, defaultVersion, title, status, rev}
let lastPublish = 0;

async function loadList() {
  let d;
  try {
    d = await fetch("/api/v1/apps", { cache: "no-store" }).then(r => r.json());
  } catch (_) { return; }
  const prevPub = lastPublish;
  lastPublish = d.lastPublish || 0;
  const apps = d.apps || [];
  // agent 修改后自动刷新预览：发布 → lastPublish 变化；直接改页面文件 → rev 变化（首次加载不刷）
  if (selected && prevPub !== 0) {
    const cur = apps.find(a => a.id === selected.id);
    if (lastPublish !== prevPub || (cur && cur.rev !== selected.rev)) {
      if (cur) selected.rev = cur.rev;
      loadFrame();
    }
  }
  cardsEl.innerHTML = "";
  emptyEl.style.display = apps.length ? "none" : "block";

  // 自动选中：当前未选中，或选中的已被删除 → 选最新的；正在看的不打断
  if (!selected || !apps.some(a => a.id === selected.id)) {
    if (apps.length) selectApp(apps[0], false);
    else closePreview();
  }

  for (const a of apps) {
    const c = document.createElement("div");
    c.className = "card" + (selected && selected.id === a.id ? " active" : "");
    c.dataset.id = a.id;
    c.innerHTML =
      "<b>" + esc(a.title) + "</b>" +
      (a.type ? '<span class="type">' + esc(a.type) + "</span>" : "") +
      '<div class="meta">' + esc(a.id) + " · v" + esc(a.defaultVersion) + " · 端口 " + a.port + " · " + esc(statusText(a.status)) + "</div>" +
      (a.description ? '<div class="desc">' + esc(a.description) + "</div>" : "") +
      '<div class="actions">' +
        '<a href="/app-proxy/' + a.port + '/" target="_blank" rel="noopener">新标签</a>' +
        '<button class="del" data-id="' + esc(a.id) + '">删除</button>' +
      "</div>";
    c.onclick = e => {
      if (e.target.closest(".del") || e.target.closest("a")) return;
      selectApp(a, true);
    };
    c.querySelector(".del").onclick = e => { e.stopPropagation(); delApp(a.id); };
    cardsEl.appendChild(c);
  }
}

function selectApp(a, userInitiated) {
  const changed = !selected || selected.id !== a.id || selected.defaultVersion !== a.defaultVersion;
  selected = { id: a.id, port: a.port, defaultVersion: a.defaultVersion, title: a.title, status: a.status, rev: a.rev };
  markActive(a.id);
  // 只允许用户显式点击写 .selected：自动选中（页面加载/多标签页轮询）不写，
  // 避免把用户刚点选的轻应用覆盖成默认值
  if (userInitiated) {
    fetch("/api/v1/apps/selected", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: a.id }),
    }).catch(() => {});
  }
  $("pname").textContent = a.title;
  $("pver").textContent = "v" + a.defaultVersion;
  $("pstatus").textContent = statusText(a.status);
  $("pstatus").className = "badge " + (a.status === "running" ? "running" : "error");
  $("popen").href = "/app-proxy/" + a.port + "/";
  $("previewBar").style.display = "flex";
  if (changed || userInitiated) loadFrame();
}

// 点击即高亮：卡片 .active 绿框不再等 5 秒轮询重渲染
function markActive(id) {
  for (const c of cardsEl.children) {
    c.classList.toggle("active", c.dataset.id === id);
  }
}

function loadFrame() {
  const old = $("frame");
  const n = old.cloneNode(false);
  old.parentNode.replaceChild(n, old); // 销毁旧 iframe，避免残留连接
  n.src = "/app-proxy/" + selected.port + "/?version=" + selected.defaultVersion + "&t=" + Date.now();
}

function closePreview() {
  selected = null;
  $("previewBar").style.display = "none";
  $("frame").src = "about:blank";
}

async function delApp(id) {
  if (!confirm("确定删除生成物 " + id + " 吗？（会归档并可恢复）")) return;
  await fetch("/api/v1/apps/" + encodeURIComponent(id), { method: "DELETE" });
  if (selected && selected.id === id) selected = null;
  loadList();
}

function statusText(s) {
  return s === "running" ? "运行中" : s === "error" ? "异常" : "未发布";
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
}

$("collapseBtn").onclick = () => $("chatPane").classList.toggle("hidden"); // CSS 隐藏，保留会话
// 分界线拖拽：参考 split-pane 做法——pointerdown 捕获指针 + 全屏遮罩盖住 iframe，
// 保证拖拽（尤其往左越过聊天 iframe）期间事件始终归分隔条，丝滑不卡。
const layoutEl = document.querySelector(".layout");
const divider = $("divider");
const shield = $("dragShield");
let dragging = false;
function applyChatPct(pct) {
  const v = Math.min(85, Math.max(15, pct));
  const chat = $("chatPane");
  chat.style.flex = "0 0 " + v + "%";
  chat.style.width = v + "%";
  localStorage.setItem("portal.chatPct", String(v));
}
function startDrag(e) {
  dragging = true;
  divider.classList.add("active");
  layoutEl.classList.add("dragging");
  shield.style.display = "block";
  document.body.style.cursor = "col-resize";
  try { divider.setPointerCapture(e.pointerId); } catch (_) {}
  e.preventDefault();
}
function moveDrag(e) {
  if (!dragging) return;
  const rect = layoutEl.getBoundingClientRect();
  if (!rect.width) return;
  applyChatPct(((e.clientX - rect.left) / rect.width) * 100);
}
function endDrag() {
  if (!dragging) return;
  dragging = false;
  divider.classList.remove("active");
  layoutEl.classList.remove("dragging");
  shield.style.display = "none";
  document.body.style.cursor = "";
}
divider.addEventListener("pointerdown", startDrag);
divider.addEventListener("pointermove", moveDrag);
divider.addEventListener("pointerup", endDrag);
divider.addEventListener("pointercancel", endDrag);
window.addEventListener("pointermove", moveDrag);
window.addEventListener("pointerup", endDrag);
window.addEventListener("pointercancel", endDrag);
shield.addEventListener("pointermove", moveDrag);
shield.addEventListener("pointerup", endDrag);
shield.addEventListener("pointercancel", endDrag);
(function () {
  const p = parseFloat(localStorage.getItem("portal.chatPct"));
  if (p > 0) applyChatPct(p);
})();
$("refreshList").onclick = loadList;
$("pRefresh").onclick = loadFrame;
$("pClose").onclick = closePreview;

loadList();
setInterval(loadList, 5000);
