/* Concord explainer: theme, copy buttons, term popovers and the animated loop figure. No dependencies. */
(function () {
  'use strict';

  var SVG_NS = 'http://www.w3.org/2000/svg';
  var root = document.documentElement;
  var reduceQuery = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  function reduced() { return !!(reduceQuery && reduceQuery.matches); }
  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }
  function ease(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }

  var store = {
    get: function (k) { try { return window.localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { window.localStorage.setItem(k, v); } catch (e) { /* storage unavailable: the choice lasts for this page only */ } }
  };

  /* ---------------- Theme ---------------- */

  var THEME_KEY = 'concord-theme';
  var themeBtn = document.querySelector('.theme-toggle');
  var darkQuery = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  function currentTheme() {
    var forced = root.getAttribute('data-theme');
    if (forced === 'light' || forced === 'dark') return forced;
    return darkQuery && darkQuery.matches ? 'dark' : 'light';
  }
  function syncThemeButton() {
    if (!themeBtn) return;
    var cur = currentTheme();
    themeBtn.setAttribute('data-current', cur);
    var label = cur === 'dark' ? 'Switch to the light theme' : 'Switch to the dark theme';
    themeBtn.setAttribute('aria-label', label);
    themeBtn.setAttribute('title', label);
  }
  if (themeBtn) {
    themeBtn.addEventListener('click', function () {
      var next = currentTheme() === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      store.set(THEME_KEY, next);
      syncThemeButton();
    });
    if (darkQuery && darkQuery.addEventListener) darkQuery.addEventListener('change', syncThemeButton);
    syncThemeButton();
  }

  /* ---------------- Reading time ---------------- */

  var rt = document.getElementById('reading-time');
  var mainEl = document.getElementById('main');
  if (rt && mainEl) {
    var clone = mainEl.cloneNode(true);
    Array.prototype.forEach.call(clone.querySelectorAll('pre, figure, noscript'), function (n) { n.parentNode.removeChild(n); });
    var words = (clone.textContent || '').trim().split(/\s+/).length;
    rt.textContent = String(Math.max(1, Math.round(words / 230)));
  }

  /* ---------------- Copy buttons ---------------- */

  var live = document.getElementById('live');
  function announce(msg) {
    if (!live) return;
    live.textContent = '';
    window.setTimeout(function () { live.textContent = msg; }, 30);
  }
  function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.top = '0';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).then(function () { return true; }, function () { return fallbackCopy(text); });
    }
    return Promise.resolve(fallbackCopy(text));
  }
  Array.prototype.forEach.call(document.querySelectorAll('[data-copy-from]'), function (btn) {
    var label = btn.querySelector('.label');
    btn.addEventListener('click', function () {
      var src = document.getElementById(btn.getAttribute('data-copy-from'));
      if (!src) return;
      copyText(src.textContent.replace(/\s+$/, '')).then(function (ok) {
        btn.classList.toggle('copied', ok);
        if (label) label.textContent = ok ? 'Copied' : 'Select and copy';
        announce(ok ? 'Copied to the clipboard' : 'Copy failed: select the text and copy it');
        window.setTimeout(function () {
          btn.classList.remove('copied');
          if (label) label.textContent = 'Copy';
        }, 1800);
      });
    });
  });

  /* ---------------- Principles: expand all ---------------- */

  var expandAll = document.getElementById('expand-all');
  if (expandAll) {
    var details = document.querySelectorAll('.principle');
    var syncExpand = function () {
      var allOpen = Array.prototype.every.call(details, function (d) { return d.open; });
      expandAll.textContent = allOpen ? 'Collapse all' : 'Expand all';
      expandAll.setAttribute('aria-expanded', allOpen ? 'true' : 'false');
    };
    expandAll.addEventListener('click', function () {
      var open = expandAll.getAttribute('aria-expanded') !== 'true';
      Array.prototype.forEach.call(details, function (d) { d.open = open; });
      syncExpand();
    });
    Array.prototype.forEach.call(details, function (d) { d.addEventListener('toggle', syncExpand); });
    syncExpand();
  }

  /* ================================================================
     The loop figure
     ================================================================ */

  var ROLE_NAME = { planner: 'Who writes: the planner', exec: 'Who writes: a low-cost model', judge: 'Who judges: an independent agent',
    disp: 'Who judges: the dispatcher', you: 'You decide', stop: 'Refusal' };

  function chip(text, kind) { return '<span class="chip' + (kind ? ' c-' + kind : '') + '">' + text + '</span>'; }

  var NODES = {
    plan: { n: 1, role: 'planner', title: 'Plan', sub: ['phases, Files:, tests', 'or a split plan'], section: 'step-plan',
      tip: 'The planner writes PLAN_<ticket>.md: per phase its executor, risk, files and acceptance commands.' },
    questions: { n: 2, role: 'you', title: 'Questions', sub: ['at most five,', 'each with a default'], section: 'step-questions', you: true,
      tip: 'At most five blocking questions, each with a default. You answer them or let the defaults stand.' },
    verifier: { n: 3, role: 'judge', title: 'Verifier', sub: ['an independent agent', 'APPROVE binds the text'], section: 'step-verifier',
      tip: 'An agent that did not write the plan challenges it. Its APPROVE holds only for the text it read.' },
    go: { n: 4, role: 'you', title: 'Your go', sub: ['one go/no-go on', 'lanes, ETA and cuts'], section: 'step-go', you: true,
      tip: 'Your decision on the lanes, the computed ETA and the verifier’s cuts.' },
    tests: { n: 5, role: 'planner', title: 'Tests fail first', sub: ['written in their own run', 'checked red'], section: 'step-tests',
      tip: 'Tests that fail on the current code, checked to fail for the stated reason before any implementation.' },
    implement: { n: 6, role: 'impl', title: 'Implement', section: 'step-implement',
      sub: { execute: ['the planner writes', 'in a recorded run'], delegate: ['low-cost model writes', 'in declared files only'] },
      tip: { execute: 'Execute mode: the planning session writes the phase inside a recorded --begin/--end run.',
        delegate: 'Delegate mode: a low-cost model writes the phase inside its Files: and Follow-through:.' } },
    check: { n: 7, role: 'disp', title: 'Check', sub: ['acceptance on a copy', 'of the candidate'], section: 'step-check',
      tip: 'The dispatcher runs the acceptance commands on a copy of the candidate and records the results.' },
    review: { n: 8, role: 'judge', title: 'Review', sub: ['tier set by risk', 'fix, then delta review'], section: 'step-review',
      tip: 'A full review at the risk tier, then a cheap delta review that closes each fixed finding.' },
    report: { n: 9, role: 'disp', title: 'Report', sub: ['from recorded data', 'overrides first'], section: 'step-report',
      tip: 'The test report, written from recorded data once every run has a verdict. Overrides come first.' },
    commit: { n: 10, role: 'you', title: 'Your commit', sub: ['you commit and merge', 'Concord never commits'], section: 'step-commit', you: true,
      tip: 'You commit and merge. Concord never commits, pushes or changes branches in your checkout.' },
    split: { role: 'planner', title: 'Split plan', sub: ['child tickets, one go', 'each runs this loop'], section: 'step-plan', aux: true,
      tip: 'A ticket whose parts can land and be reviewed apart becomes child tickets, verified and approved once.' },
    redrun: { role: 'stop', title: 'Not run · exit 6', sub: ['acceptance passes', 'before the change'], section: 'step-tests', fail: true,
      tip: 'Delegate mode: a phase whose acceptance already passes is not started (exit 6).' },
    reject: { role: 'stop', title: 'Rejected · not graded', sub: ['an edit outside the scope', 'no candidate, no PASS'], section: 'step-check', fail: true,
      tip: 'A change outside Files: and Follow-through: rejects the run; a PASS on it exits 7.' }
  };
  var MAIN_ORDER = ['plan', 'questions', 'verifier', 'go', 'tests', 'implement', 'check', 'review', 'report', 'commit'];
  var ROLE_NODES = {
    write: ['plan', 'tests', 'implement', 'split'],
    judge: ['verifier', 'check', 'review', 'report'],
    you: ['questions', 'go', 'commit']
  };

  var TEXT = {
    plan: '<strong>Plan.</strong> The planner reads the code once and writes ' + chip('PLAN_&lt;ticket&gt;.md') +
      ': Done when, a Test plan, and per phase its executor, ' + chip('Risk:') + ', ' + chip('Files:') + ' and ' + chip('Follow-through:') +
      '. A ticket whose parts can land apart becomes a ' + chip('split plan') + ' of child tickets.',
    questions: '<strong>Questions.</strong> The planner asks at most five blocking questions, each with a default. ' +
      chip('You', 'you') + ' answer them, or let the defaults stand.',
    verifier: '<strong>Independent verifier.</strong> ' + chip('plan-verifier', 'judge') +
      ', an agent that did not write the plan, checks its claims against the code. Its ' + chip('APPROVE', 'judge') +
      ' holds only for the exact text it read; without it, every run exits 11.',
    go: '<strong>Your go.</strong> ' + chip('One go/no-go', 'you') +
      ' on the lanes, the computed ETA and the verifier’s cuts. A later change to a phase’s work comes back to you for that phase’s go.',
    tests: '<strong>Tests that fail first.</strong> Tests for each changed behavior are written in their own run, and the planner checks that each one ' +
      chip('fails', 'stop') + ' for the stated reason before any implementation starts.',
    implement: {
      execute: '<strong>Implement, execute mode.</strong> The planning session writes the phase inside a recorded ' + chip('--begin') + ' / ' +
        chip('--end') + ' run, with the same backup, scope report and checks as any other run.',
      delegate: '<strong>Implement, delegate mode.</strong> ' + chip('A low-cost model', 'exec') + ' writes the bulky phase, free tier first, inside its ' +
        chip('Files:') + ' and ' + chip('Follow-through:') + '. The planner still writes what costs less to write than to specify.'
    },
    check: '<strong>Check.</strong> The ' + chip('dispatcher', 'disp') + ', not the writer, runs the acceptance commands on a copy of the ' +
      chip('candidate', 'disp') + ' and writes the evidence report. A ' + chip('PASS', 'disp') + ' needs the expected result of every command.',
    review: '<strong>Review by risk tier.</strong> A reviewer that did not write the change reads it: a flash model at ' + chip('low', 'judge') +
      ', Opus 5.5 at ' + chip('medium', 'judge') + ', Opus 5.5 plus a flash model of another family at ' + chip('high', 'judge') +
      '. Fixes then get a cheap delta review.',
    report: '<strong>Report.</strong> ' + chip('--report', 'disp') +
      ' writes the test report from recorded data once every run has a verdict, and closes the plan to new runs. It opens with the ' +
      chip('overrides', 'plain') + '.',
    commit: '<strong>Your commit.</strong> ' + chip('You commit', 'you') + ' and merge. Concord never commits, pushes or changes branches in your checkout.',
    redrun: {
      delegate: '<strong>Refused before it starts.</strong> The acceptance already passes before any change, so the test does not test the phase: the dispatcher prints ' +
        chip('NOT RUN', 'stop') + ' and exits 6. Fix the test, or mark the command (characterization).',
      execute: '<strong>Warned before it starts.</strong> In execute mode the session run starts anyway with a ' + chip('BASELINE WARNING', 'stop') +
        '; in delegate mode the dispatcher refuses to start the run and exits 6.'
    },
    reject: '<strong>Rejected.</strong> The run changed a file outside its write scope, so it is ' + chip('REJECTED (not graded)', 'stop') +
      ': there is no candidate and a PASS exits 7. The FAIL takes cause EXECUTOR; after a cleanup, ' + chip('--grade', 'disp') + ' grades the checkout again.'
  };

  var STEP_LIST = [
    { node: 'plan', via: null, also: ['split'] },
    { node: 'questions', via: 'e1' },
    { node: 'verifier', via: 'e2' },
    { node: 'go', via: 'e3' },
    { node: 'tests', via: 'e4' },
    { node: 'implement', via: 'e5' },
    { node: 'check', via: 'e6' },
    { node: 'review', via: 'e7', loop: true },
    { node: 'report', via: 'e8' },
    { node: 'commit', via: 'e9' }
  ];
  var FAIL_LIST = [
    { node: 'plan', via: null, also: ['split'] },
    { node: 'questions', via: 'e1' },
    { node: 'verifier', via: 'e2' },
    { node: 'go', via: 'e3' },
    { node: 'tests', via: 'e4' },
    { node: 'redrun', via: 'f1' },
    { node: 'implement', via: 'f1b' },
    { node: 'reject', via: 'f2' },
    { node: 'check', via: 'f2b' },
    { node: 'review', via: 'e7', loop: true },
    { node: 'report', via: 'e8' },
    { node: 'commit', via: 'e9' }
  ];
  var EDGE_ROLE = { e1: 'you', e2: 'judge', e3: 'you', e4: 'planner', e5: 'impl', e6: 'disp', e7: 'judge', e8: 'disp', e9: 'you',
    f1: 'stop', f1b: 'impl', f2: 'stop', f2b: 'disp', loop: 'judge', split: 'planner' };
  var FAIL_EDGES = { f1: 1, f1b: 1, f2: 1, f2b: 1 };

  /* Geometry. Nodes are [x, y] with the layout's size, or [x, y, w, h]. Edges are built from the node boxes. */
  function box(L, id) {
    var p = L.nodes[id];
    if (!p) return null;
    var w = p[2] || L.size[0], h = p[3] || L.size[1];
    return { x: p[0], y: p[1], w: w, h: h, r: p[0] + w, b: p[1] + h, cx: p[0] + w / 2, cy: p[1] + h / 2 };
  }
  function hRight(a, b) { return 'M' + a.r + ',' + a.cy + ' H' + (b.x - 3); }
  function hLeft(a, b) { return 'M' + a.x + ',' + a.cy + ' H' + (b.r + 3); }
  function vDown(a, b) { return 'M' + a.cx + ',' + a.b + ' V' + (b.y - 3); }
  function vUp(a, b) { return 'M' + a.cx + ',' + a.y + ' V' + (b.b + 3); }

  var LAYOUTS = {
    wide: {
      vb: [960, 604], vbPlain: 522, size: [156, 96], fs: { title: 15.5, sub: 12.5, auxTitle: 13.5, auxSub: 11.5 }, badge: { off: 15, r: 10 },
      nodes: {
        plan: [26, 56], questions: [214, 56], verifier: [402, 56], go: [590, 56], tests: [778, 56],
        implement: [778, 344], check: [590, 344], review: [402, 344], report: [214, 344], commit: [26, 344],
        split: [140, 198, 200, 62], redrun: [596, 198, 214, 62], reject: [700, 530, 234, 62]
      },
      regions: [
        { x: 10, y: 10, w: 940, h: 162, label: 'BEFORE ANY CODE', note: 'plan, challenge, approve' },
        { x: 10, y: 300, w: 940, h: 212, label: 'BUILD AND JUDGE', note: 'write, check, review, record' }
      ],
      edges: function (L) {
        var B = function (id) { return box(L, id); };
        return {
          e1: hRight(B('plan'), B('questions')), e2: hRight(B('questions'), B('verifier')),
          e3: hRight(B('verifier'), B('go')), e4: hRight(B('go'), B('tests')),
          e5: vDown(B('tests'), B('implement')),
          e6: hLeft(B('implement'), B('check')), e7: hLeft(B('check'), B('review')),
          e8: hLeft(B('review'), B('report')), e9: hLeft(B('report'), B('commit')),
          ret: vUp(B('commit'), B('plan')),
          split: 'M160,' + B('plan').b + ' V' + (B('split').y - 3),
          f1: 'M' + B('tests').cx + ',' + B('tests').b + ' V' + B('redrun').cy + ' H' + (B('redrun').r + 3),
          f1b: 'M' + B('redrun').cx + ',' + B('redrun').b + ' C' + B('redrun').cx + ',306 800,296 800,' + (B('implement').y - 3),
          f2: 'M' + B('implement').cx + ',' + B('implement').b + ' V' + (B('reject').y - 3),
          f2b: 'M' + B('reject').x + ',' + B('reject').cy + ' C' + B('check').cx + ',' + B('reject').cy + ' ' + B('check').cx + ',520 ' + B('check').cx + ',' + (B('check').b + 3),
          loop: 'M536,' + B('review').b + ' C536,494 424,494 424,' + (B('review').b + 3)
        };
      },
      labels: [
        { x: 94, y: 252, text: 'next ticket', anchor: 'end' },
        { x: 480, y: 506, text: 'fix, then delta review', anchor: 'middle' },
        { x: 656, y: 548, text: 'clean up, then --grade', anchor: 'end', fail: true }
      ]
    },
    narrow: {
      vb: [400, 646], vbPlain: 544, size: [168, 78], fs: { title: 15, sub: 12.5, auxTitle: 13, auxSub: 11.5 }, badge: { off: 14, r: 9.5 },
      nodes: {
        plan: [12, 52], questions: [12, 152], verifier: [12, 252], go: [12, 352], tests: [12, 452],
        implement: [220, 452], check: [220, 352], review: [220, 252], report: [220, 152], commit: [220, 52],
        redrun: [12, 570, 168, 64], reject: [220, 570, 168, 64]
      },
      regions: [],
      edges: function (L) {
        var B = function (id) { return box(L, id); };
        return {
          e1: vDown(B('plan'), B('questions')), e2: vDown(B('questions'), B('verifier')),
          e3: vDown(B('verifier'), B('go')), e4: vDown(B('go'), B('tests')),
          e5: hRight(B('tests'), B('implement')),
          e6: vUp(B('implement'), B('check')), e7: vUp(B('check'), B('review')),
          e8: vUp(B('review'), B('report')), e9: vUp(B('report'), B('commit')),
          ret: 'M' + B('commit').cx + ',' + B('commit').y + ' C' + B('commit').cx + ',22 ' + B('plan').cx + ',22 ' + B('plan').cx + ',' + (B('plan').y - 3),
          f1: vDown(B('tests'), B('redrun')),
          f1b: 'M' + B('redrun').r + ',' + B('redrun').cy + ' C214,' + B('redrun').cy + ' 244,572 244,' + (B('implement').b + 3),
          f2: vDown(B('implement'), B('reject')),
          f2b: 'M' + B('reject').r + ',' + B('reject').cy + ' C399,' + B('reject').cy + ' 399,' + B('check').cy + ' ' + (B('check').r + 3) + ',' + B('check').cy,
          loop: 'M' + B('review').x + ',278 C198,278 198,304 ' + (B('review').x - 3) + ',304'
        };
      },
      labels: [
        { x: 200, y: 17, text: 'next ticket', anchor: 'middle' }
      ]
    }
  };

  var figEl = document.getElementById('loop');
  if (figEl) initLoop(figEl);

  function initLoop(fig) {
    var stage = fig.querySelector('.loop-stage');
    var svg = fig.querySelector('.loop-svg');
    var range = fig.querySelector('.scrub input');
    var ticksEl = fig.querySelector('.ticks');
    var narration = fig.querySelector('.narration');
    var narKicker = fig.querySelector('.nar-kicker');
    var narText = fig.querySelector('.nar-text');
    var playBtn = fig.querySelector('[data-action="play"]');
    var playLabel = playBtn.querySelector('.label');
    var tip = fig.querySelector('.tip');
    var modeBtns = fig.querySelectorAll('[data-mode]');
    var failBtn = fig.querySelector('[data-action="fail"]');
    if (!stage || !svg || !range) return;

    var mode = 'delegate';
    var showFail = false;
    var layoutName = null;
    var steps = [], starts = [], total = 0;
    var time = 0, playing = false, lastNow = 0, raf = 0, tween = null, scrubbing = false, endHold = 0;
    var shownIndex = -1;
    var started = false, userPaused = false, autoPaused = false;
    var nodeEls = {}, progs = {}, token = null, ghost = null, loopProg = null, startPoint = null;
    var hlIds = null, hlTimer = 0;

    var TRAVEL = 0.85, DWELL = 4.4;

    function roleOf(id) { var r = NODES[id].role; return r === 'impl' ? (mode === 'execute' ? 'planner' : 'exec') : r; }
    function edgeRole(id) { var r = EDGE_ROLE[id] || 'planner'; return r === 'impl' ? (mode === 'execute' ? 'planner' : 'exec') : r; }
    function nodeSub(id) { var s = NODES[id].sub; return Array.isArray(s) ? s : s[mode]; }
    function nodeTip(id) { var t = NODES[id].tip; return typeof t === 'string' ? t : t[mode]; }
    function stepText(id) { var t = TEXT[id]; return typeof t === 'string' ? t : t[mode]; }

    /* ---- Timeline ---- */
    function buildSteps() {
      var list = showFail ? FAIL_LIST : STEP_LIST;
      steps = list.map(function (s, i) {
        var o = { node: s.node, via: s.via, also: s.also || [], loop: !!s.loop };
        o.travel = i === 0 ? 0 : TRAVEL;
        o.dwell = s.loop ? 5.6 : (NODES[s.node].fail ? 5.2 : DWELL);
        return o;
      });
      starts = [];
      var acc = 0;
      steps.forEach(function (s) { starts.push(acc); acc += s.travel + s.dwell; });
      total = acc;
    }
    function locate(t) {
      t = clamp(t, 0, total);
      var i = steps.length - 1;
      for (var k = 0; k < steps.length; k++) {
        if (t < starts[k] + steps[k].travel + steps[k].dwell) { i = k; break; }
      }
      var s = steps[i], local = t - starts[i];
      if (local < s.travel) return { i: i, phase: 'travel', t: local / s.travel };
      return { i: i, phase: 'dwell', t: s.dwell ? clamp((local - s.travel) / s.dwell, 0, 1) : 1 };
    }
    function arrival(i) { return starts[i] + steps[i].travel + 0.001; }
    function indexOfNode(id) {
      for (var i = 0; i < steps.length; i++) if (steps[i].node === id) return i;
      return -1;
    }

    /* ---- SVG construction ---- */
    function el(name, attrs, parent) {
      var e = document.createElementNS(SVG_NS, name);
      if (attrs) Object.keys(attrs).forEach(function (k) { e.setAttribute(k, attrs[k]); });
      if (parent) parent.appendChild(e);
      return e;
    }
    function text(parent, x, y, str, cls, size, anchor) {
      var t = el('text', { x: x, y: y, 'class': cls, 'text-anchor': anchor || 'middle' }, parent);
      if (size) t.setAttribute('font-size', size);
      t.textContent = str;
      return t;
    }

    function build() {
      var L = LAYOUTS[layoutName];
      while (svg.firstChild) svg.removeChild(svg.firstChild);
      setViewBox();
      svg.classList.toggle('show-fail', showFail);
      stage.classList.toggle('is-narrow', layoutName === 'narrow');
      nodeEls = {}; progs = {};

      var title = el('title', { id: 'loop-svg-title' }, svg);
      title.textContent = 'The Concord loop: plan, questions, verifier, your go, tests that fail first, implement, check, review, report, your commit.';

      var defs = el('defs', null, svg);
      ['base', 'planner', 'exec', 'judge', 'disp', 'you', 'stop'].forEach(function (k) {
        var m = el('marker', { id: 'lm-' + k, viewBox: '0 0 10 10', refX: '8.6', refY: '5', markerWidth: '9', markerHeight: '9',
          markerUnits: 'userSpaceOnUse', orient: 'auto' }, defs);
        el('path', { d: 'M0,0.8 L10,5 L0,9.2 Z', 'class': 'marker-' + k }, m);
      });

      var gRegions = el('g', { 'aria-hidden': 'true' }, svg);
      L.regions.forEach(function (r) {
        var g = el('g', { 'class': 'region' }, gRegions);
        el('rect', { x: r.x, y: r.y, width: r.w, height: r.h, rx: 18 }, g);
        var t = el('text', { x: r.x + r.w / 2, y: r.y + 26, 'text-anchor': 'middle' }, g);
        var a = el('tspan', { 'class': 'region-label' }, t);
        a.textContent = r.label;
        var b = el('tspan', { 'class': 'region-note', dx: '10' }, t);
        b.textContent = r.note;
      });

      var paths = L.edges(L);
      var gEdges = el('g', { 'aria-hidden': 'true' }, svg);
      Object.keys(paths).forEach(function (id) {
        var cls = 'edge';
        if (FAIL_EDGES[id]) cls += ' fail fail-part';
        if (id === 'ret' || id === 'split') cls += ' dashed';
        el('path', { d: paths[id], 'class': cls, 'marker-end': 'url(#lm-' + (FAIL_EDGES[id] ? 'stop' : 'base') + ')' }, gEdges);
      });
      Object.keys(paths).forEach(function (id) {
        if (id === 'ret') return;
        var role = edgeRole(id);
        var p = el('path', { d: paths[id], 'class': 'prog r-' + role + (FAIL_EDGES[id] ? ' fail-part' : '') }, gEdges);
        var len = p.getTotalLength();
        p.setAttribute('stroke-dasharray', len + ' ' + len);
        p.setAttribute('stroke-dashoffset', String(len));
        p.style.visibility = 'hidden';
        var end = p.getPointAtLength(len);
        progs[id] = { el: p, len: len, f: 0, role: role, end: { x: end.x, y: end.y } };
      });
      loopProg = progs.loop || null;
      if (paths.ret) {
        var tmp = el('path', { d: paths.ret }, svg);
        var rl = tmp.getTotalLength();
        var sp = tmp.getPointAtLength(rl);
        startPoint = { x: sp.x, y: sp.y };
        svg.removeChild(tmp);
      }

      var gLabels = el('g', { 'aria-hidden': 'true' }, svg);
      L.labels.forEach(function (lb) {
        text(gLabels, lb.x, lb.y, lb.text, 'edge-label' + (lb.fail ? ' fail fail-part' : ''), null, lb.anchor);
      });

      var gNodes = el('g', { 'class': 'nodes' }, svg);
      var order = MAIN_ORDER.concat(['split', 'redrun', 'reject']);
      order.forEach(function (id) {
        var b = box(L, id);
        if (!b) return;
        nodeEls[id] = buildNode(gNodes, L, id, b);
      });

      ghost = el('circle', { r: 5, 'class': 'ghost', 'aria-hidden': 'true' }, svg);
      ghost.style.visibility = 'hidden';
      token = el('g', { 'class': 'token', 'aria-hidden': 'true' }, svg);
      el('circle', { r: 13, 'class': 'token-halo' }, token);
      el('circle', { r: 6.5, 'class': 'token-core' }, token);

      syncFailFocus();
      applyHighlight();
    }

    function buildNode(parent, L, id, b) {
      var d = NODES[id];
      var aux = d.aux || d.fail;
      var g = el('g', { 'class': 'node r-' + roleOf(id) + (d.aux ? ' is-aux' : '') + (d.fail ? ' fail-part' : ''),
        'data-node': id, tabindex: '0', role: 'button' }, parent);
      var subs = nodeSub(id);
      var label = (d.n ? 'Step ' + d.n + ', ' : '') + d.title + ': ' + subs.join(' ') + '. Opens its explanation.';
      g.setAttribute('aria-label', label);

      el('rect', { 'class': 'halo', x: b.x - 7, y: b.y - 7, width: b.w + 14, height: b.h + 14, rx: 18 }, g);
      if (d.you) el('rect', { 'class': 'gate', x: b.x - 4, y: b.y - 4, width: b.w + 8, height: b.h + 8, rx: 15 }, g);
      el('rect', { 'class': 'body', x: b.x, y: b.y, width: b.w, height: b.h, rx: 12 }, g);
      el('rect', { 'class': 'ring', x: b.x - 4, y: b.y - 4, width: b.w + 8, height: b.h + 8, rx: 15 }, g);

      var ts = aux ? L.fs.auxTitle : L.fs.title;
      var ss = aux ? L.fs.auxSub : L.fs.sub;
      var gap = ss * 1.38;
      var block = ts * 0.74 + 6 + ss + (subs.length - 1) * gap + ss * 0.22;
      var top = b.y + (b.h - block) / 2;
      var base = top + ts * 0.74;
      text(g, b.cx, base, d.title, 'title', ts);
      subs.forEach(function (s, i) { text(g, b.cx, base + 6 + ss + i * gap, s, 'sub', ss); });

      if (d.n) {
        var bg = el('g', { 'class': 'badge' }, g);
        el('circle', { cx: b.x + L.badge.off, cy: b.y + L.badge.off, r: L.badge.r }, bg);
        text(bg, b.x + L.badge.off, b.y + L.badge.off + 4, String(d.n), '', null, 'middle');
      }
      if (d.you) {
        var tg = el('g', { 'class': 'you-tag' }, g);
        el('rect', { x: b.r - 50, y: b.y - 9, width: 40, height: 18, rx: 9 }, tg);
        text(tg, b.r - 30, b.y + 4, 'YOU', '', null, 'middle');
      }

      g.addEventListener('mouseenter', function () { showTip(id); });
      g.addEventListener('mouseleave', hideTip);
      g.addEventListener('focus', function () { showTip(id); });
      g.addEventListener('blur', hideTip);
      g.addEventListener('click', function () { jumpTo(id); });
      g.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar') {
          e.preventDefault();
          e.stopPropagation();
          jumpTo(id);
        }
      });
      return g;
    }

    function setViewBox() {
      var L = LAYOUTS[layoutName];
      svg.setAttribute('viewBox', '0 0 ' + L.vb[0] + ' ' + (showFail ? L.vb[1] : L.vbPlain));
    }

    function syncFailFocus() {
      ['redrun', 'reject'].forEach(function (id) {
        var g = nodeEls[id];
        if (!g) return;
        g.setAttribute('tabindex', showFail ? '0' : '-1');
        if (showFail) g.removeAttribute('aria-hidden'); else g.setAttribute('aria-hidden', 'true');
      });
    }

    /* ---- Rendering ---- */
    function setProg(id, f) {
      var p = progs[id];
      if (!p) return;
      f = clamp(f, 0, 1);
      if (Math.abs(p.f - f) < 0.0005) return;
      p.f = f;
      p.el.style.visibility = f <= 0 ? 'hidden' : 'visible';
      p.el.setAttribute('stroke-dashoffset', String(p.len * (1 - f)));
      if (f >= 1) p.el.setAttribute('marker-end', 'url(#lm-' + p.role + ')');
      else p.el.removeAttribute('marker-end');
    }
    function pointOn(id, f) {
      var p = progs[id];
      if (!p) return null;
      var pt = p.el.getPointAtLength(p.len * clamp(f, 0, 1));
      return { x: pt.x, y: pt.y };
    }
    function restPoint(i) {
      var s = steps[i];
      if (s.via && progs[s.via]) return progs[s.via].end;
      return startPoint || { x: 0, y: 0 };
    }

    function render(force) {
      if (!steps.length || !token) return;
      if (force) shownIndex = -1;
      var loc = locate(time);
      if (loc.i !== shownIndex) { shownIndex = loc.i; showStep(loc.i); }
      var motion = !reduced();

      var used = {};
      steps.forEach(function (s, j) {
        if (!s.via) return;
        used[s.via] = 1;
        var f = j < loc.i ? 1 : (j > loc.i ? 0 : (loc.phase === 'travel' ? (motion ? ease(loc.t) : 1) : 1));
        setProg(s.via, f);
      });
      Object.keys(progs).forEach(function (id) { if (!used[id] && id !== 'loop' && id !== 'split') setProg(id, 0); });

      var s = steps[loc.i];
      var reviewIdx = indexOfNode('review');
      var loopF = 0;
      if (loc.i > reviewIdx) loopF = 1;
      else if (loc.i === reviewIdx && loc.phase === 'dwell') loopF = clamp((loc.t - 0.12) / 0.56, 0, 1);
      setProg('loop', motion ? loopF : (loopF > 0 ? 1 : 0));
      setProg('split', loc.i === 0 && loc.phase === 'dwell' ? (motion ? clamp(loc.t / 0.3, 0, 1) : 1) : (loc.i > 0 ? 1 : 0));

      var pt = (loc.phase === 'travel' && s.via && motion) ? pointOn(s.via, ease(loc.t)) : restPoint(loc.i);
      if (pt) token.setAttribute('transform', 'translate(' + pt.x.toFixed(2) + ',' + pt.y.toFixed(2) + ')');
      token.style.setProperty('--tc', 'var(--' + roleOf(s.node) + ')');

      if (loopProg && motion && loc.i === reviewIdx && loopF > 0 && loopF < 1) {
        var gp = pointOn('loop', ease(loopF));
        ghost.setAttribute('cx', gp.x.toFixed(2));
        ghost.setAttribute('cy', gp.y.toFixed(2));
        ghost.style.visibility = 'visible';
      } else {
        ghost.style.visibility = 'hidden';
      }

      if (!scrubbing) range.value = String(Math.round((clamp(time, 0, total) / total) * 1000));
      range.style.setProperty('--p', ((clamp(time, 0, total) / total) * 100).toFixed(2) + '%');
    }

    function stepName(i) {
      var s = steps[i], d = NODES[s.node];
      if (d.n) return 'Step ' + d.n + ' of 10';
      if (s.node === 'redrun') return mode === 'execute' ? 'Warning, then the run starts' : 'Refusal before the run';
      return 'Rejection after the run';
    }
    function showStep(i) {
      var s = steps[i], d = NODES[s.node];
      narKicker.textContent = d.n ? stepName(i) + ' · ' + ROLE_NAME[roleOf(s.node)] : stepName(i);
      narText.innerHTML = stepText(s.node);
      narration.setAttribute('data-role', roleOf(s.node));
      range.setAttribute('aria-valuetext', stepName(i) + ', ' + d.title);
      Object.keys(nodeEls).forEach(function (id) {
        var g = nodeEls[id];
        var idx = indexOfNode(id);
        if (idx < 0) {
          for (var k = 0; k < steps.length; k++) if (steps[k].also.indexOf(id) >= 0) { idx = k; break; }
        }
        g.classList.remove('past', 'active', 'future');
        if (idx < 0) return;
        g.classList.add(idx < i ? 'past' : (idx === i || s.also.indexOf(id) >= 0 ? 'active' : 'future'));
      });
      Array.prototype.forEach.call(ticksEl.children, function (t, k) { t.classList.toggle('done', k <= i); });
    }

    function buildTicks() {
      while (ticksEl.firstChild) ticksEl.removeChild(ticksEl.firstChild);
      steps.forEach(function (s, i) {
        var t = document.createElement('span');
        var role = roleOf(s.node);
        t.className = 'tick' + (role === 'you' ? ' t-you' : role === 'stop' ? ' t-stop' : '');
        t.style.left = ((arrival(i) / total) * 100).toFixed(3) + '%';
        ticksEl.appendChild(t);
      });
    }

    /* ---- Playback ---- */
    function frame(now) {
      raf = 0;
      var dt = lastNow ? Math.min(0.1, (now - lastNow) / 1000) : 0;
      lastNow = now;
      if (tween) {
        var k = clamp((now - tween.t0) / tween.dur, 0, 1);
        time = tween.from + (tween.to - tween.from) * ease(k);
        if (k >= 1) {
          tween = null;
          setLive();
          render(true);
        }
      } else if (playing && !scrubbing) {
        if (time >= total) {
          endHold += dt;
          if (endHold > 1.8) { endHold = 0; time = 0; }
        } else {
          time = Math.min(total, time + dt);
        }
      }
      render();
      if (playing || tween) raf = window.requestAnimationFrame(frame);
      else lastNow = 0;
    }
    function kick() {
      if (!raf) { lastNow = 0; raf = window.requestAnimationFrame(frame); }
    }
    function setLive() {
      narration.setAttribute('aria-live', playing || tween ? 'off' : 'polite');
    }
    function setPlaying(on) {
      playing = on;
      playLabel.textContent = on ? 'Pause' : 'Play';
      playBtn.setAttribute('aria-label', on ? 'Pause the animation' : 'Play the animation');
      playBtn.classList.toggle('is-playing', on);
      setLive();
      if (on) {
        if (time >= total) time = 0;
        endHold = 0;
        kick();
      }
    }
    function userToggle() {
      if (playing) { setPlaying(false); userPaused = true; }
      else { userPaused = false; autoPaused = false; setPlaying(true); }
    }
    function seek(target, animate) {
      target = clamp(target, 0, total);
      endHold = 0;
      if (animate && !reduced()) {
        tween = { from: time, to: target, t0: window.performance.now(), dur: clamp(260 + Math.abs(target - time) * 40, 260, 720) };
        setLive();
        kick();
      } else {
        tween = null;
        time = target;
        render();
      }
    }
    function stepBy(dir) {
      var loc = locate(time);
      var target = loc.i + dir;
      if (loc.phase === 'travel') target = dir > 0 ? loc.i : loc.i - 1;
      target = clamp(target, 0, steps.length - 1);
      if (playing) { setPlaying(false); userPaused = true; }
      seek(arrival(target), true);
    }
    function seekToNode(id, animate) {
      var idx = indexOfNode(id);
      if (idx >= 0) seek(arrival(idx), animate);
    }

    /* ---- Highlight from terms and cards ---- */
    function applyHighlight() {
      var on = !!(hlIds && hlIds.length);
      svg.classList.toggle('has-hl', on);
      Object.keys(nodeEls).forEach(function (id) {
        nodeEls[id].classList.toggle('hl', on && hlIds.indexOf(id) >= 0);
      });
    }
    function setHighlight(ids, ms) {
      window.clearTimeout(hlTimer);
      hlIds = ids && ids.length ? ids.slice() : null;
      applyHighlight();
      if (hlIds && ms) hlTimer = window.setTimeout(function () { hlIds = null; applyHighlight(); }, ms);
    }

    /* ---- Tooltip and navigation ---- */
    function showTip(id) {
      var g = nodeEls[id];
      if (!g || !tip) return;
      var d = NODES[id];
      tip.innerHTML = '';
      var name = document.createElement('span');
      name.className = 'tip-name';
      name.textContent = (d.n ? d.n + '. ' : '') + d.title;
      tip.appendChild(name);
      tip.appendChild(document.createTextNode(nodeTip(id)));
      tip.style.setProperty('--c', 'var(--' + roleOf(id) + ')');
      tip.hidden = false;
      var host = fig.getBoundingClientRect();
      var r = g.querySelector('.body').getBoundingClientRect();
      var tw = tip.offsetWidth, th = tip.offsetHeight;
      var x = clamp(r.left - host.left + r.width / 2 - tw / 2, 8, host.width - tw - 8);
      var y = r.top - host.top - th - 10;
      if (y < 6) y = r.bottom - host.top + 10;
      tip.style.left = x + 'px';
      tip.style.top = y + 'px';
    }
    function hideTip() { if (tip) tip.hidden = true; }

    function jumpTo(id) {
      var sec = document.getElementById(NODES[id].section);
      if (!sec) return;
      hideTip();
      sec.scrollIntoView({ behavior: reduced() ? 'auto' : 'smooth', block: 'start' });
      var h = sec.querySelector('h3');
      if (h) {
        h.setAttribute('tabindex', '-1');
        try { h.focus({ preventScroll: true }); } catch (e) { h.focus(); }
        h.classList.add('flash');
        window.setTimeout(function () { h.classList.remove('flash'); }, 1800);
      }
    }

    function showInFigure(ids, stepNode) {
      hideTip();
      stage.scrollIntoView({ behavior: reduced() ? 'auto' : 'smooth', block: 'center' });
      if (stepNode) {
        if (playing) { setPlaying(false); userPaused = true; }
        seekToNode(stepNode, true);
      }
      setHighlight(ids, 2800);
      try { stage.focus({ preventScroll: true }); } catch (e) { stage.focus(); }
    }

    /* ---- Layout ---- */
    function pickLayout() {
      var w = stage.clientWidth;
      var next = w < 720 ? 'narrow' : 'wide';
      if (next !== layoutName) {
        layoutName = next;
        build();
        render(true);
      }
    }

    /* ---- Wiring ---- */
    buildSteps();
    buildTicks();
    pickLayout();
    if (window.ResizeObserver) new window.ResizeObserver(pickLayout).observe(stage);
    else window.addEventListener('resize', pickLayout);

    playBtn.addEventListener('click', userToggle);
    fig.querySelector('[data-action="restart"]').addEventListener('click', function () {
      tween = null;
      time = 0;
      endHold = 0;
      userPaused = false;
      render(true);
      setPlaying(true);
    });
    fig.querySelector('[data-action="prev"]').addEventListener('click', function () { stepBy(-1); });
    fig.querySelector('[data-action="next"]').addEventListener('click', function () { stepBy(1); });

    range.addEventListener('pointerdown', function () { scrubbing = true; tween = null; });
    window.addEventListener('pointerup', function () { if (scrubbing) { scrubbing = false; lastNow = 0; } });
    window.addEventListener('pointercancel', function () { scrubbing = false; lastNow = 0; });
    range.addEventListener('input', function () {
      tween = null;
      endHold = 0;
      time = (Number(range.value) / 1000) * total;
      render();
    });
    range.addEventListener('change', function () { scrubbing = false; lastNow = 0; });

    fig.addEventListener('keydown', function (e) {
      var t = e.target;
      var isRange = t === range;
      var isButton = !isRange && t.closest && t.closest('button, a');
      if (e.key === ' ' || e.key === 'Spacebar') {
        if (isButton) return;
        e.preventDefault();
        userToggle();
      } else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
        e.preventDefault();
        stepBy(e.key === 'ArrowRight' ? 1 : -1);
      } else if ((e.key === 'Home' || e.key === 'End') && (isRange || t === stage)) {
        e.preventDefault();
        if (playing) { setPlaying(false); userPaused = true; }
        seek(e.key === 'Home' ? 0 : arrival(steps.length - 1), true);
      }
    });

    Array.prototype.forEach.call(modeBtns, function (btn) {
      btn.addEventListener('click', function () {
        mode = btn.getAttribute('data-mode');
        Array.prototype.forEach.call(modeBtns, function (b) { b.setAttribute('aria-pressed', b === btn ? 'true' : 'false'); });
        build();
        render(true);
      });
    });

    failBtn.addEventListener('click', function () {
      var current = steps[locate(time).i].node;
      showFail = !showFail;
      failBtn.setAttribute('aria-checked', showFail ? 'true' : 'false');
      if (!showFail && NODES[current].fail) current = current === 'redrun' ? 'implement' : 'check';
      buildSteps();
      buildTicks();
      svg.classList.toggle('show-fail', showFail);
      setViewBox();
      syncFailFocus();
      tween = null;
      if (showFail && (current === 'implement' || current === 'check')) current = current === 'implement' ? 'redrun' : 'reject';
      time = arrival(Math.max(0, indexOfNode(current)));
      render(true);
    });

    if (reduceQuery && reduceQuery.addEventListener) reduceQuery.addEventListener('change', function () { render(true); });

    if ('IntersectionObserver' in window) {
      var io = new window.IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          var visible = en.isIntersecting && en.intersectionRatio >= 0.3;
          if (visible) {
            if (!started) {
              started = true;
              if (!reduced() && !userPaused) setPlaying(true);
            } else if (autoPaused && !userPaused) {
              autoPaused = false;
              setPlaying(true);
            }
          } else if (playing) {
            setPlaying(false);
            autoPaused = true;
          }
        });
      }, { threshold: [0, 0.3] });
      io.observe(stage);
    }
    window.addEventListener('scroll', hideTip, { passive: true });

    /* ---- Links into the figure from the article ---- */
    Array.prototype.forEach.call(document.querySelectorAll('[data-fig-step]'), function (btn) {
      btn.addEventListener('click', function () {
        var id = btn.getAttribute('data-fig-step');
        showInFigure([id], id);
      });
    });
    Array.prototype.forEach.call(document.querySelectorAll('[data-fig-role]'), function (btn) {
      btn.addEventListener('click', function () { showInFigure(ROLE_NODES[btn.getAttribute('data-fig-role')]); });
    });
    Array.prototype.forEach.call(document.querySelectorAll('.role-card[data-role]'), function (card) {
      var ids = ROLE_NODES[card.getAttribute('data-role')];
      card.addEventListener('mouseenter', function () { setHighlight(ids); });
      card.addEventListener('mouseleave', function () { setHighlight(null); });
    });

    window.ConcordLoop = { highlight: setHighlight, show: showInFigure };
    render(true);
  }

  /* ================================================================
     Terms: a definition on hover, focus or tap; the matching parts of the figure light up.
     ================================================================ */

  var TERMS = {
    harness: { name: 'Harness', def: 'The system around a model that lets it act as an agent: its prompts, tools, skills and orchestration.', nodes: [] },
    governance: { name: 'Governance', def: 'What keeps a person accountable for what the agents ship: who decides, what counts as evidence and what a verdict means.', nodes: ['go', 'commit'] },
    dispatcher: { name: 'Dispatcher', def: 'concord.py, a standard-library Python script. It gates each run on an approved plan, checks scope, runs the acceptance commands and records the verdicts.', nodes: ['check', 'report'] },
    verifier: { name: 'Plan verifier', def: 'An agent that did not write the plan. It checks the plan against the code and answers CUT, MERGE and FIX items; its APPROVE holds only for the exact text it read.', nodes: ['verifier'] },
    'plan-read': { name: 'Plan read', def: 'The approval-relevant text of the plan, which --lint writes under a name taken from its hash. The verifier reads this file and quotes the hash.', nodes: ['verifier'] },
    go: { name: 'Go/no-go', def: 'Your decision on the lanes, the computed ETA and the verifier’s cuts. The planning session stops for it before the phases run.', nodes: ['go'] },
    'red-run': { name: 'Red run', def: 'The acceptance commands, run on a copy of the untouched tree before the writer starts. They must fail; a delegated phase whose acceptance already passes is not run (exit 6).', nodes: ['tests', 'redrun'] },
    scope: { name: 'Write scope', def: 'A phase’s Files: and Follow-through: lists together. A change outside them rejects the run.', nodes: ['implement', 'reject'] },
    candidate: { name: 'Candidate', def: 'The checkout as the writer left it. The acceptance commands run on a copy of it, and a PASS needs the checkout to still hold it.', nodes: ['check'] },
    acceptance: { name: 'Acceptance commands', def: 'Fast offline commands listed in each phase. They must fail before the change and pass after it, unless marked (characterization).', nodes: ['tests', 'check'] },
    tier: { name: 'Risk tier', def: 'The phase’s Risk: line: low, medium (the default) or high. It decides who reviews the change.', nodes: ['review'] },
    delta: { name: 'Delta review', def: 'A cheap review of a fix only. It closes each finding it shows fixed; a change it cannot tie to a finding needs a review at its own tier.', nodes: ['review'] },
    overrides: { name: 'Overrides', def: 'The first section of the test report: each forced PASS beside its failed commands, each waiver and owner go-ahead, each PASS whose phase a later revision changed.', nodes: ['report'] },
    ledger: { name: 'Ledger', def: 'The record of every run and verdict with its cause (runs.jsonl), and of every review finding.', nodes: ['report'] },
    executor: { name: 'Executor', def: 'The model and harness that write a delegated phase, such as a free DeepSeek Flash model on OpenCode. It reads the shared executor contract first.', nodes: ['implement'] },
    'execute-mode': { name: 'Execute mode', def: '/concord:run execute: the planning session writes every phase inside recorded --begin/--end runs.', nodes: ['implement'] },
    'delegate-mode': { name: 'Delegate mode', def: '/concord:run delegate: each phase goes to the executor the plan assigns, low-cost models first for the bulky ones.', nodes: ['implement'] }
  };

  var pop = document.getElementById('term-pop');
  var popName = pop && pop.querySelector('.pop-name');
  var popDef = pop && pop.querySelector('.pop-def');
  var popShow = pop && pop.querySelector('.pop-show');
  var popFor = null, pinned = false, hideTimer = 0, posRaf = 0;

  function placePop() {
    posRaf = 0;
    if (!popFor || pop.hidden) return;
    var r = popFor.getBoundingClientRect();
    if (r.bottom < 0 || r.top > window.innerHeight) { closePop(); return; }
    var pw = pop.offsetWidth, ph = pop.offsetHeight;
    var x = clamp(r.left + r.width / 2 - pw / 2, 12, window.innerWidth - pw - 12);
    var y = r.bottom + 10;
    if (y + ph > window.innerHeight - 8 && r.top - ph - 10 > 8) y = r.top - ph - 10;
    pop.style.left = x + 'px';
    pop.style.top = y + 'px';
  }
  function openPop(btn, pin) {
    var term = TERMS[btn.getAttribute('data-term')];
    if (!term) return;
    window.clearTimeout(hideTimer);
    if (popFor && popFor !== btn) popFor.setAttribute('aria-expanded', 'false');
    popFor = btn;
    pinned = !!pin;
    popName.textContent = term.name;
    popDef.textContent = term.def;
    popShow.hidden = !term.nodes.length;
    if (btn.nextSibling !== pop) btn.parentNode.insertBefore(pop, btn.nextSibling);
    pop.hidden = false;
    btn.setAttribute('aria-expanded', 'true');
    placePop();
    if (window.ConcordLoop) window.ConcordLoop.highlight(term.nodes);
  }
  function closePop() {
    window.clearTimeout(hideTimer);
    if (!pop || pop.hidden) return;
    pop.hidden = true;
    pinned = false;
    if (popFor) popFor.setAttribute('aria-expanded', 'false');
    popFor = null;
    if (window.ConcordLoop) window.ConcordLoop.highlight(null);
  }
  function scheduleHide() {
    if (pinned) return;
    window.clearTimeout(hideTimer);
    hideTimer = window.setTimeout(closePop, 180);
  }

  if (pop) {
    Array.prototype.forEach.call(document.querySelectorAll('.term[data-term]'), function (btn) {
      btn.setAttribute('aria-expanded', 'false');
      btn.setAttribute('aria-controls', 'term-pop');
      btn.addEventListener('mouseenter', function () { if (!pinned) openPop(btn, false); });
      btn.addEventListener('mouseleave', scheduleHide);
      btn.addEventListener('focus', function () { if (!(pinned && popFor === btn)) openPop(btn, false); });
      btn.addEventListener('blur', function (e) {
        if (e.relatedTarget && pop.contains(e.relatedTarget)) return;
        if (e.relatedTarget) closePop(); else scheduleHide();
      });
      btn.addEventListener('click', function (e) {
        e.stopPropagation();
        if (popFor === btn && pinned) closePop();
        else openPop(btn, true);
      });
    });
    pop.addEventListener('mouseenter', function () { window.clearTimeout(hideTimer); });
    pop.addEventListener('mouseleave', scheduleHide);
    pop.addEventListener('click', function (e) { e.stopPropagation(); });
    pop.addEventListener('focusout', function (e) {
      if (e.relatedTarget && (pop.contains(e.relatedTarget) || e.relatedTarget === popFor)) return;
      if (e.relatedTarget) closePop();
    });
    popShow.addEventListener('click', function () {
      var term = popFor && TERMS[popFor.getAttribute('data-term')];
      closePop();
      if (term && window.ConcordLoop) window.ConcordLoop.show(term.nodes);
    });
    document.addEventListener('click', function () { if (pinned) closePop(); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && popFor) {
        var back = popFor;
        closePop();
        back.focus();
      }
    });
    var onMove = function () { if (!posRaf && popFor) posRaf = window.requestAnimationFrame(placePop); };
    window.addEventListener('scroll', onMove, { passive: true });
    window.addEventListener('resize', onMove);
  }
})();
