/* dairee.skifi.co: the landing page. The phone in the hero ticks off the
   morning round, the feature cards come in as they scroll into view, and the
   wall board counts up while it is on screen. */
document.documentElement.classList.add("js");

(function () {
  "use strict";
  var MEN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  var MSH = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  var DSH = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  var reduce = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;

  function $(s, r) { return (r || document).querySelector(s); }
  function $$(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }
  /* 18.5 L, 19 L */
  function litres(n) {
    var r = Math.round(n * 10) / 10;
    return (r % 1 === 0 ? String(r) : r.toFixed(1)) + " L";
  }
  function count(el, from, to, ms) {
    if (reduce) { el.textContent = litres(to); return; }
    var t0 = performance.now();
    (function step(now) {
      var k = Math.min(1, (now - t0) / ms), e = 1 - Math.pow(1 - k, 3);
      el.textContent = litres(Math.round((from + (to - from) * e) * 2) / 2);
      if (k < 1) requestAnimationFrame(step);
    })(t0);
  }
  function seen(el, fn, threshold) {
    if (!("IntersectionObserver" in window)) { fn(true); return; }
    new IntersectionObserver(function (es) { es.forEach(function (e) { fn(e.isIntersecting, e); }); }, { threshold: threshold || 0.2 }).observe(el);
  }
  function ready(fn) { if (document.readyState !== "loading") fn(); else document.addEventListener("DOMContentLoaded", fn); }

  /* Runs a plan of [ms, fn] steps in a loop while the element is on screen. */
  function loop(el, plan, length) {
    var t = 0, next = 0, on = false, last = 0;
    seen(el, function (v) { on = v; }, 0.25);
    (function frame(ts) {
      var dt = last ? Math.min(100, ts - last) : 0;
      last = ts;
      if (on && !document.hidden) {
        t += dt;
        while (next < plan.length && t >= plan[next][0]) { plan[next][1](); next++; }
        if (t >= length) { t = 0; next = 0; }
      }
      requestAnimationFrame(frame);
    })(performance.now());
  }

  ready(function () {
    /* the dates on the screens are today's */
    var now = new Date();
    function short(d) { return d.getDate() + " " + MSH[d.getMonth()]; }
    function back(n) { var d = new Date(now); d.setDate(d.getDate() - n); return d; }
    $$("[data-today]").forEach(function (el) { el.textContent = short(now); });
    $$("[data-month]").forEach(function (el) { el.textContent = MEN[now.getMonth()] + " " + now.getFullYear(); });
    $$("[data-long]").forEach(function (el) { el.textContent = DAYS[now.getDay()] + " " + now.getDate() + " " + MEN[now.getMonth()]; });
    $$("[data-d]").forEach(function (el) {
      var v = el.getAttribute("data-d"), d = back(parseInt(v, 10));
      var slot = v === "0" || /m$/.test(v) ? "morning" : "evening";
      el.textContent = DSH[d.getDay()] + " " + short(d) + ", " + slot;
    });

    /* on phones a slim bar with "Open Dairee" shows once the hero is gone,
       and steps aside when the last call is on screen */
    var bar = $("#getbar"), heroEl = $(".hero"), getEl = $("#get");
    if (bar && heroEl && getEl && "IntersectionObserver" in window) {
      var heroIn = true, getIn = false;
      var upd = function () {
        var on = !heroIn && !getIn;
        bar.classList.toggle("on", on);
        bar.setAttribute("aria-hidden", on ? "false" : "true");
        $("a", bar).tabIndex = on ? 0 : -1;
      };
      new IntersectionObserver(function (es) { heroIn = es[0].isIntersecting; upd(); }, { threshold: 0 }).observe($(".hero__get", heroEl) || heroEl);
      new IntersectionObserver(function (es) { getIn = es[0].isIntersecting; upd(); }, { threshold: 0.1 }).observe(getEl);
    }

    /* the bar at the top gets a line once the page moves */
    var nav = $("#nav");
    function onScroll() { nav.classList.toggle("is-stuck", window.scrollY > 8); }
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();

    /* sections come in as they are scrolled to */
    var io = "IntersectionObserver" in window ? new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); onIn(e.target); } });
    }, { threshold: 0.18, rootMargin: "0px 0px -6% 0px" }) : null;
    $$(".reveal").forEach(function (el) { if (io) io.observe(el); else { el.classList.add("in"); onIn(el); } });

    function onIn(el) {
      if (el.classList.contains("card--big")) bigCard(el);
      if ($("#vOff", el)) offline($("#vOff", el));
      if ($("#perm", el)) perm($("#perm", el));
    }

    /* the big feature card: two more doors */
    function bigCard(card) {
      var amt = $(".vround__amt", card), fill = $(".vround__bar i", card), a = $(".vrow--a", card), b = $(".vrow--b", card);
      [[a, 18.5, 19, 74, 1100], [b, 19, 21.5, 84, 1900]].forEach(function (s) {
        setTimeout(function () {
          s[0].classList.add("is-on", "just");
          count(amt, s[1], s[2], 700);
          fill.style.width = s[3] + "%";
        }, reduce ? 0 : s[4]);
      });
    }

    /* no signal: the waiting ticks go out */
    function offline(box) {
      var w = $("[data-w]", box);
      setTimeout(function () {
        box.classList.add("sent");
        w.textContent = "Signal back, all sent";
        var u = $(".vwait use", box);
        if (u) u.setAttribute("href", "#i-cloud");
      }, reduce ? 0 : 1800);
    }

    /* the staff card: one more page turned on */
    function perm(card) {
      var row = $("[data-flip]", card);
      setTimeout(function () { row.classList.add("flip"); $(".sw", row).classList.add("on"); }, reduce ? 0 : 1300);
    }

    /* ---------------------------------------------------------- the phone in the hero */
    (function hero() {
      var list = $("#hList");
      if (!list || reduce) return;
      var wrap = list.parentNode;
      var amt = $("#hAmt"), prog = $("#hProg"), doneEl = $("#hDone"), done2 = $("#hDone2"), todo = $("#hTodo"), left = $("#hLeft"), note = $("#hNote"), pack = $("#hPack");
      var lake = $("#gLake"), palm = $("#gPalm");
      var stops = { a: [0.5, lake], b: [2.5, lake], c: [1, palm], d: [1.5, palm], e: [1.5, palm] };
      var BASE = 15, TOTAL = 25.5, DONE = 7, DUE = 13, BOTTLES = 2;
      var state = { l: BASE, n: DONE, b: BOTTLES };

      function show() {
        doneEl.textContent = state.n;
        done2.textContent = state.n;
        todo.textContent = DUE - state.n;
        left.textContent = state.n >= DUE ? "All done" : (DUE - state.n) + " to go";
        prog.style.width = (state.n / DUE * 100).toFixed(1) + "%";
        note.textContent = state.b + " bottles to collect, 1 paused";
      }
      function group(g) {
        var all = $$(".scr__m .scr__tick", g).length, n = $$(".scr__m.is-done", g).length;
        $("[data-g]", g).textContent = n;
        g.classList.toggle("is-done", n === all);
      }
      function tick(k) {
        var row = $('[data-s="' + k + '"]', list), s = stops[k];
        row.classList.add("is-done", "just");
        count(amt, state.l, state.l + s[0], 650);
        state.l += s[0]; state.n += 1; state.b += 1;
        show();
        group(s[1]);
        setTimeout(function () { row.classList.remove("just"); }, 600);
      }
      function scrollOn() {
        var dy = palm.offsetTop - lake.offsetTop - 4;
        list.style.transform = "translateY(" + (-Math.min(dy, Math.max(0, list.scrollHeight - wrap.clientHeight * 0.8))) + "px)";
      }
      function reset() {
        Object.keys(stops).forEach(function (k) { $('[data-s="' + k + '"]', list).classList.remove("is-done"); });
        list.style.transform = "";
        pack.classList.remove("show");
        state = { l: BASE, n: DONE, b: BOTTLES };
        amt.textContent = litres(BASE);
        show();
        group(lake); group(palm);
      }
      loop($(".stage"), [[1600, function () { tick("a"); }], [3000, function () { tick("b"); }], [4300, scrollOn],
        [5300, function () { tick("c"); }], [6600, function () { tick("d"); }], [7900, function () { tick("e"); }],
        [9000, function () { pack.classList.add("show"); }], [15000, reset]], 16000);
    })();

    /* ---------------------------------------------------------- the wall board */
    (function wall() {
      var m = $("#wbM"), fill = $("#wbBar"), l = $("#wbL"), time = $("#wbTime");
      if (!m) return;
      var steps = [[9, 18.5], [10, 19.5], [11, 21], [12, 22.5], [13, 25.5]], i = 0;
      function clock(add) {
        var d = new Date(now); d.setHours(6, 41 + add, 0, 0);
        var h = d.getHours() % 12 || 12;
        return h + ":" + String(d.getMinutes()).padStart(2, "0") + " am";
      }
      function set(k) {
        var s = steps[k], from = steps[Math.max(0, k - 1)][1];
        m.textContent = s[0];
        fill.style.width = (s[0] / 13 * 100).toFixed(1) + "%";
        if (k === 0) l.textContent = litres(s[1]); else count(l, from, s[1], 700);
        time.textContent = clock(k * 2);
      }
      if (reduce) return;
      var plan = [];
      for (var k = 1; k < steps.length; k++) (function (k) { plan.push([k * 2200, function () { set(k); }]); })(k);
      plan.push([steps.length * 2200 + 3000, function () { set(0); }]);
      loop($(".tv"), plan, steps.length * 2200 + 3600);
      set(i);
    })();
  });
})();

/* the 3D pieces around the hero phone drift a little with the pointer */
(function () {
  if (!window.matchMedia || !matchMedia("(pointer: fine)").matches || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  var hero = document.querySelector(".hero");
  if (!hero) return;
  var items = [].slice.call(hero.querySelectorAll(".d3[data-depth]"));
  if (!items.length) return;
  var raf = 0, x = 0, y = 0;
  hero.addEventListener("pointermove", function (e) {
    var r = hero.getBoundingClientRect();
    x = (e.clientX - r.left) / r.width - 0.5;
    y = (e.clientY - r.top) / r.height - 0.5;
    if (raf) return;
    raf = requestAnimationFrame(function () {
      raf = 0;
      items.forEach(function (el) {
        var d = parseFloat(el.getAttribute("data-depth")) || 1;
        el.style.transform = "translate3d(" + (-x * d * 12).toFixed(1) + "px," + (-y * d * 12).toFixed(1) + "px,0)";
      });
    });
  });
  hero.addEventListener("pointerleave", function () {
    items.forEach(function (el) { el.style.transform = ""; });
  });
})();
