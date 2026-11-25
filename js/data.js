/*
  COUNTREX DATA: loads tournaments and events from Supabase for the public pages, and handles "Join tournament".
  Put this file in your js folder, next to supabase.js. Pages load it right after js/supabase.js.
  Needs in Supabase: 001, 002, 003, 004 and 005_public.sql.

  window.cxData.cache.tours   [{ id, n, g, p, lim, end, fee, prize, pr, rules, bet, cover, joined, status }]
  window.cxData.cache.events  [{ id, n, t, p, lim, end, prize }]
  window.cxData.refresh()     reloads both lists, returns a Promise
  window.cxData.join(id, { toast, redraw })   asks the player to confirm, then joins through the database
*/
(function () {
  "use strict";
  var GN = { codm: "Call of Duty: Mobile", eafc: "EA SPORTS FC", efootball: "eFootball" };
  var D = window.cxData = { cache: { tours: [], events: [] }, loaded: false };
  var sb = function () { return typeof supabaseClient !== "undefined" ? supabaseClient : null };
  var esc = function (s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] }) };
  function ghs(n) { n = Number(n || 0) / 100; return "GHS " + (n % 1 === 0 ? n.toLocaleString("en-GB") : n.toFixed(2)) }

  // a small shared style for the cover picture on a tournament card
  var st = document.createElement("style");
  st.textContent = ".tcv{display:block;width:100%;aspect-ratio:16/9;object-fit:cover;border-radius:14px;margin:0 0 12px;background:rgba(127,127,127,.18)}" +
    "#cxjoin{border:0;border-radius:20px;padding:22px;width:min(380px,calc(100% - 28px));background:#fff;color:#1A0B2E;font-family:inherit}" +
    "#cxjoin::backdrop{background:rgba(10,4,20,.6)}#cxjoin h3{font-size:19px;margin:0 0 8px}#cxjoin p{margin:0 0 8px;line-height:1.45;font-size:15px}" +
    "#cxjoin .cxw{font-weight:700}#cxjoin .cxbad{color:#C0213F}#cxjoin .cxa{display:flex;gap:10px;justify-content:flex-end;margin-top:14px}" +
    "#cxjoin button{font:inherit;font-weight:700;border-radius:12px;padding:11px 18px;border:1px solid #DDD4EA;background:#F6F2FB;color:#1A0B2E;cursor:pointer}" +
    "#cxjoin button.cxgo{background:#5E3C88;border-color:#5E3C88;color:#fff}#cxjoin button:disabled{opacity:.5;cursor:not-allowed}" +
    "html[data-theme=dark] #cxjoin{background:#21113A;color:#fff}html[data-theme=dark] #cxjoin button{background:#2B1950;border-color:#3B2862;color:#fff}" +
    "html[data-theme=dark] #cxjoin button.cxgo{background:#8A68C2;border-color:#8A68C2}";
  document.head.appendChild(st);

  st.textContent += ".cxcode{margin:12px 0 0;padding:12px 14px;border-radius:14px;background:rgba(127,127,127,.14);display:flex;align-items:center;justify-content:space-between;gap:10px}.cxcode small{display:block;opacity:.7;font-size:12px}.cxcode b{font-size:16px;word-break:break-all}.cxcode button{font:inherit;font-weight:700;border:0;border-radius:10px;padding:9px 14px;background:#5E3C88;color:#fff;cursor:pointer;flex:none}";
  D.codeBox = function (code) { return code ? '<div class="cxcode"><div><small>Tournament ID — paste this in the game</small><b>' + esc(code) + '</b></div><button type="button" data-cxcopy="' + esc(code) + '">Copy</button></div>' : "" };
  document.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest("[data-cxcopy]"); if (!b) return; var t = b.getAttribute("data-cxcopy");
    var done = function () { b.textContent = "Copied ✓"; setTimeout(function () { b.textContent = "Copy" }, 1800) };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(done, function () { prompt("Copy this ID:", t) }); else prompt("Copy this ID:", t);
  });

  D.session = async function () { try { return sb() ? (await sb().auth.getSession()).data.session : null } catch (e) { return null } };

  D.refresh = async function () {
    var c = sb(); if (!c) return D.cache;
    try {
      var r = await Promise.all([
        c.from("tournaments").select("id,game_key,name,rules,player_limit,entry_fee,prize_pool,betting_enabled,join_closes_at,status,cover_url").neq("status", "draft").neq("status", "cancelled").order("join_closes_at"),
        c.from("events").select("*").order("starts_at"),
        c.rpc("public_counts"), D.session()
      ]);
      if (r[0].error) throw r[0].error;
      var counts = {}; ((r[2] && r[2].data) || []).forEach(function (x) { counts[x.kind + ":" + x.id] = Number(x.n) || 0 });
      var s = r[3], mine = {};
      if (s) { var m = await c.from("tournament_entries").select("tournament_id").eq("user_id", s.user.id); ((m && m.data) || []).forEach(function (x) { mine[x.tournament_id] = true }) }
      var codes = {};
      if (s && Object.keys(mine).length) { try { var cr = await c.from("tournament_codes").select("tournament_id,code"); ((cr && cr.data) || []).forEach(function (x) { codes[x.tournament_id] = x.code }) } catch (e) { } }
      var mineE = {};
      if (s) { var me = await c.from("event_entries").select("event_id").eq("user_id", s.user.id); ((me && me.data) || []).forEach(function (x) { mineE[x.event_id] = true }) }
      var liveIds = (r[0].data || []).filter(function (t) { return t.status === "live" }).map(function (t) { return t.id }), prog = {};
      if (liveIds.length) { var f = await c.from("fixtures").select("tournament_id,status").in("tournament_id", liveIds); ((f && f.data) || []).forEach(function (x) { var p = prog[x.tournament_id] = prog[x.tournament_id] || { all: 0, done: 0 }; p.all++; if (x.status === "done") p.done++ }) }
      D.cache.tours = (r[0].data || []).map(function (t) {
        var p = prog[t.id], pr = t.status === "live" ? Math.max(1, p && p.all ? Math.round(p.done / p.all * 100) : 1) : 0;
        return { id: t.id, n: t.name, g: GN[t.game_key] || t.game_key, p: counts["tournament:" + t.id] || 0, lim: t.player_limit,
          end: t.status === "open" ? new Date(t.join_closes_at).getTime() : 0,          // registration is only open while the status is "open"
          fee: t.entry_fee > 0 ? ghs(t.entry_fee) : "Free", prize: t.prize_pool > 0 ? ghs(t.prize_pool) : "", feeMinor: t.entry_fee, pr: pr,
          rules: t.rules || "", bet: !!t.betting_enabled, cover: t.cover_url || "", joined: !!mine[t.id], code: mine[t.id] ? (codes[t.id] || "") : "", status: t.status };
      });
      D.cache.events = (r[1].data || []).map(function (e) {
        return { id: e.id, n: e.name, t: e.category, p: counts["event:" + e.id] || 0, lim: e.join_limit || 0, end: new Date(e.starts_at).getTime(), prize: e.prize || "", cover: e.cover_url || "", joined: !!mineE[e.id] };
      });
      D.loaded = true;
    } catch (e) { console.error(e) }
    return D.cache;
  };

  function why(e) {
    var m = String((e && e.message) || "").toLowerCase();
    if (m.indexOf("registration closed") > -1) return "Registration is closed for this tournament.";
    if (m.indexOf("event is full") > -1) return "This event is full.";
    if (m.indexOf("tournament full") > -1) return "This tournament is full.";
    if (m.indexOf("insufficient balance") > -1) return "Not enough money in your wallet.";
    if (m.indexOf("duplicate key") > -1 || m.indexOf("already") > -1) return "You already joined this tournament.";
    if (m.indexOf("account not active") > -1) return "Your account cannot join tournaments right now.";
    if (m.indexOf("too many requests") > -1) return "Slow down a little and try again in a minute.";
    return "Could not join. Please try again.";
  }

  D.join = async function (id, o) {
    o = o || {}; var say = o.toast || function () { };
    var t = D.cache.tours.filter(function (x) { return x.id === id })[0]; if (!t) return;
    var s = await D.session();
    if (!s) { location.href = "login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() || "index.html"); return }
    var bal = null;
    try { var w = await sb().from("wallets").select("balance").eq("user_id", s.user.id).maybeSingle(); if (w && w.data) bal = w.data.balance } catch (e) { }
    var need = t.feeMinor || 0, short = need > 0 && bal != null && bal < need;
    var d = document.getElementById("cxjoin"); if (d) d.remove();
    d = document.createElement("dialog"); d.id = "cxjoin";
    d.innerHTML = "<h3>Join " + esc(t.n) + "?</h3><p>" + (need > 0 ? "<span class=\"cxw\">" + esc(ghs(need)) + "</span> will be taken from your wallet." : "This tournament is free to enter.") + "</p>" +
      (bal != null && need > 0 ? "<p>Your wallet: <span class=\"cxw\">" + esc(ghs(bal)) + "</span></p>" : "") + (short ? "<p class=\"cxbad\">You do not have enough money. Add money to your wallet first.</p>" : "") +
      "<div class=\"cxa\"><button type=\"button\" id=\"cxno\">Cancel</button><button type=\"button\" class=\"cxgo\" id=\"cxyes\"" + (short ? " disabled" : "") + ">Join" + (need > 0 ? " and pay" : "") + "</button></div>";
    document.body.appendChild(d); d.showModal();
    d.querySelector("#cxno").onclick = function () { d.close() };
    d.addEventListener("close", function () { d.remove() });
    d.querySelector("#cxyes").onclick = async function () {
      var b = this; b.disabled = true;
      var r = await sb().rpc("join_tournament", { p_tournament: id });
      d.close();
      if (r.error) {
        if (/login required|jwt/i.test(r.error.message || "")) { location.href = "login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() || "index.html"); return }
        say(why(r.error)); await D.refresh(); if (o.redraw) o.redraw(); return;
      }
      say("You joined " + t.n + "!"); await D.refresh(); if (o.redraw) o.redraw();
    };
  };

  // Join an EVENT (free, no wallet): confirm, then add the player's own row to event_entries (the database enforces the seat limit)
  D.joinEvent = async function (id, o) {
    o = o || {}; var say = o.toast || function () { };
    var ev = D.cache.events.filter(function (x) { return x.id === id })[0]; if (!ev) return;
    var s = await D.session();
    if (!s) { location.href = "login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() || "index.html"); return }
    var d = document.getElementById("cxjoin"); if (d) d.remove();
    d = document.createElement("dialog"); d.id = "cxjoin";
    d.innerHTML = "<h3>Join " + esc(ev.n) + "?</h3><p>This event is free to join.</p><div class=\"cxa\"><button type=\"button\" id=\"cxno\">Cancel</button><button type=\"button\" class=\"cxgo\" id=\"cxyes\">Join</button></div>";
    document.body.appendChild(d); d.showModal();
    d.querySelector("#cxno").onclick = function () { d.close() };
    d.addEventListener("close", function () { d.remove() });
    d.querySelector("#cxyes").onclick = async function () {
      this.disabled = true;
      var r = await sb().from("event_entries").insert({ event_id: id, user_id: s.user.id });
      d.close();
      if (r.error) { say(why(r.error)); await D.refresh(); if (o.redraw) o.redraw(); return }
      say("You joined " + ev.n + "!"); await D.refresh(); if (o.redraw) o.redraw();
    };
  };
})();
