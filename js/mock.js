/* =====================================================================
   체험 모드 (config.js 에 Supabase 정보가 없을 때만 써요)
   - supabase.sql 의 함수들을 브라우저 안에서 똑같이 흉내 내요
   - 예시 학생 기록이 들어 있고, 이 브라우저에만 저장돼요
   - 체험용 관리자 비밀번호: admin1234
   ===================================================================== */
'use strict';
(function () {
  const KEY = 'quizDemoDB_v4', ADMIN_PW = 'admin1234';
  let db = null, ready = null;
  const fail = m => { throw new QuizError(m, true); };
  const clone = x => (x === undefined ? null : JSON.parse(JSON.stringify(x)));
  const save = () => { try { localStorage.setItem(KEY, JSON.stringify(db)); } catch (e) {} };
  const norm = s => String(s ?? '').toLowerCase().replace(/[\s'"`]/g, '');
  const setEq = (a, b) => { const x = [...new Set(a.map(String))].sort(), y = [...new Set(b.map(String))].sort(); return x.length === y.length && x.every((v, i) => v === y[i]); };
  const listEq = (a, b) => { const x = a.map(String).sort(), y = b.map(String).sort(); return x.length === y.length && x.every((v, i) => v === y[i]); };
  const stageOf = a => (a === '파이썬' ? 0 : a === 'AI' ? 1 : 2);

  /* ---------- 문제 다루기 (supabase.sql 과 같은 규칙) ---------- */
  function view(t, b) {
    const v = clone(b); ['answer', 'answers', 'why', 'hint', 'spot', 'spotLabel'].forEach(k => delete v[k]);
    v.hasHint = !!(b.hint && String(b.hint).length);
    if (t === 'mc' || t === 'multi') v.options = shuffle(b.options);
    if (t === 'order') v.blocks = shuffle(b.blocks);
    if (t === 'fill') v.chips = shuffle(b.chips);
    if (t === 'match') { delete v.pairs; v.left = shuffle(b.pairs.map(p => p[0])); v.right = shuffle(b.pairs.map(p => p[1])); }
    if (t === 'sort') v.items = shuffle(b.items.map(p => p[0]));
    return v;
  }
  function grade(t, b, a) {
    try {
      if (a === null || a === undefined) return false;
      switch (t) {
        case 'ox': case 'imgox': return a === b.answer;
        case 'mc': return a === b.options[b.answer];
        case 'multi': return setEq(a, b.answers.map(i => b.options[i]));
        case 'input': return b.answer.some(x => norm(x) === norm(a));
        case 'fill': return JSON.stringify(a) === JSON.stringify(b.answer);
        case 'order': return JSON.stringify(a) === JSON.stringify(b.blocks);
        case 'match': return a.length === b.pairs.length && listEq(a.map(p => p[0] + '\u001f' + p[1]), b.pairs.map(p => p[0] + '\u001f' + p[1]));
        case 'sort': return a.length === b.items.length && listEq(a.map(p => p[0] + '\u001f' + p[1]), b.items.map(p => p[0] + '\u001f' + p[1]));
        case 'bug': case 'imgpick': return Number(a) === Number(b.answer);
        case 'imgspot': { const [x, y, w, h] = b.spot; return a.x >= x && a.x <= x + w && a.y >= y && a.y <= y + h; }
      }
    } catch (e) {}
    return false;
  }
  function key(t, b) {
    switch (t) {
      case 'mc': return b.options[b.answer];
      case 'multi': return b.answers.map(i => b.options[i]);
      case 'input': return b.answer[0];
      case 'order': return b.blocks;
      case 'match': return b.pairs;
      case 'sort': return b.items;
      case 'imgspot': return b.spot;
      default: return b.answer;
    }
  }
  function answerText(t, b) {
    switch (t) {
      case 'ox': case 'imgox': return b.answer;
      case 'mc': return b.options[b.answer];
      case 'multi': return b.answers.map(i => b.options[i]).join(', ');
      case 'input': return b.answer[0];
      case 'fill': return b.answer.join('  /  ');
      case 'order': return b.blocks.map(x => x.trim()).join('  →  ');
      case 'match': return b.pairs.map(p => `${p[0]}  →  ${p[1]}`).join('\n');
      case 'sort': return b.buckets.map((k, i) => `${k}: ${b.items.filter(it => Number(it[1]) === i).map(it => it[0]).join(', ')}`).join('\n');
      case 'bug': return String(b.lines[b.answer]).trim();
      case 'imgpick': return 'AB'[b.answer] + ' 사진';
      case 'imgspot': return b.spotLabel || '표시된 곳';
    }
    return '';
  }
  function checkBody(t, b) {
    const len = x => (Array.isArray(x) ? x.length : 0), uniq = x => new Set(x.map(String)).size === x.length;
    if (!String(b.q || '').trim()) fail('문제 글을 적어 주세요.');
    switch (t) {
      case 'ox': case 'imgox': if (!['O', 'X'].includes(b.answer)) fail('정답을 O 또는 X로 골라 주세요.'); break;
      case 'mc': case 'multi':
        if (len(b.options) < 2) fail('보기를 2개 이상 적어 주세요.');
        if (!uniq(b.options)) fail('보기 글자가 서로 달라야 해요.');
        if (t === 'mc' && !(b.answer >= 0 && b.answer < b.options.length)) fail('정답 보기를 골라 주세요.');
        if (t === 'multi' && !len(b.answers)) fail('정답 보기를 하나 이상 골라 주세요.');
        break;
      case 'input': if (!len(b.answer)) fail('인정할 정답을 하나 이상 적어 주세요.'); break;
      case 'fill': {
        const n = (String(b.code || '').match(/\{\d\}/g) || []).length;
        if (!n) fail('빈칸 자리에 {0}, {1} 처럼 적어 주세요.');
        if (len(b.answer) !== n) fail('빈칸 수와 정답 수가 같아야 해요.');
        if (b.answer.some(x => !(b.chips || []).includes(x))) fail('정답은 블록 목록에도 들어 있어야 해요.');
        if (!uniq(b.chips)) fail('블록 글자가 서로 달라야 해요.');
        break;
      }
      case 'order': if (len(b.blocks) < 2) fail('블록을 2개 이상 적어 주세요.'); if (!uniq(b.blocks)) fail('블록 글자가 서로 달라야 해요.'); break;
      case 'match': if (len(b.pairs) < 2) fail('짝을 2개 이상 적어 주세요.'); if (!uniq(b.pairs.map(p => p[0])) || !uniq(b.pairs.map(p => p[1]))) fail('짝 글자가 서로 달라야 해요.'); break;
      case 'sort': if (len(b.buckets) !== 2) fail('분류 이름을 2개 적어 주세요.'); if (len(b.items) < 2) fail('분류할 항목을 2개 이상 적어 주세요.'); break;
      case 'bug': if (len(b.lines) < 2) fail('줄을 2개 이상 적어 주세요.'); if (!(b.answer >= 0 && b.answer < b.lines.length)) fail('정답 줄을 골라 주세요.'); break;
      case 'imgspot': if (!b.img) fail('그림 주소를 적어 주세요.'); if (len(b.spot) !== 4) fail('그림에서 정답 영역을 지정해 주세요.'); break;
      case 'imgpick': if (len(b.imgs) !== 2) fail('그림 주소 2개를 적어 주세요.'); break;
    }
    if (t === 'imgox' && !b.img) fail('그림 주소를 적어 주세요.');
  }

  /* ---------- 예시 학생 ---------- */
  function rng(a) { return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
  const FAM = '김이박최정강조윤장임한오서신권황안송류홍', GIVEN = ['민준', '서준', '도윤', '예준', '시우', '하준', '주원', '지호', '지후', '준우', '서연', '서윤', '지우', '하은', '민서', '현우', '건우', '우진', '선우', '유준', '연우', '은우', '정우', '승현', '지민', '수아', '태윤', '민재', '현준', '동현'];
  const GROUPS = [[1, 3, 27, 13.1], [2, 1, 24, 12.7], [1, 1, 26, 12.5], [3, 2, 18, 12.1], [2, 5, 22, 11.7], [1, 2, 19, 11.0], [3, 4, 3, 13.9], [2, 7, 2, 10.4], [1, 9, 21, 11.4], [3, 10, 16, 11.9], [1, 12, 14, 12.3], [2, 11, 9, 11.2]];
  function fake(r, g, c, num, mean, finished) {
    const z = (r() + r() + r() - 1.5) * 2.8, right = Math.max(3, Math.min(15, Math.round(mean + z)));
    const time = Math.round(r() < .08 ? 170 + r() * 130 : Math.max(200, Math.min(880, 560 - right * 16 + r() * 300)));
    const hints = right === 15 ? (r() < .5 ? 0 : 1 + Math.floor(r() * 3)) : Math.floor(r() * 4);
    const combo = right === 15 ? 15 : Math.max(1, Math.min(right, Math.round(right * (0.35 + 0.6 * r()))));
    const sr = [0, 0, 0]; for (let k = 0; k < right; k++) { let s; do { s = Math.floor(r() * 3); } while (sr[s] >= 5); sr[s]++; }
    const w = [0.8 + r() * 0.4, 0.8 + r() * 0.4, 0.8 + r() * 0.4], ws = w[0] + w[1] + w[2];
    return {
      id: db.nextA++, token: 'demo-' + Math.random().toString(36).slice(2), grade: g, cls: c, num,
      name: FAM[Math.floor(r() * FAM.length)] + GIVEN[Math.floor(r() * GIVEN.length)],
      started: finished - time * 1000, finished, right, total: 15, score: Math.round(right * 100 / 15), time, hints, combo,
      bestQ: Math.round((1.6 + r() * 7) * 10) / 10, clutch: r() < .25 ? Math.round((0.4 + r() * 4.5) * 10) / 10 : Math.round((8 + r() * 40) * 10) / 10,
      sr, st: w.map(x => Math.round(time * x / ws)), flawless: right === 15 && hints === 0, items: [],
    };
  }
  async function init() {
    try { db = JSON.parse(localStorage.getItem(KEY)); } catch (e) { db = null; }
    if (db && db.v === 4) return;
    let qs;
    try { qs = await (await fetch('data/questions.json')).json(); } catch (e) { fail('체험용 문제 파일(data/questions.json)을 불러오지 못했어요.'); }
    db = { v: 4, settings: { title: 'AI·코딩 퀴즈 챌린지', school: '온양고등학교', isOpen: true, tierMode: 'hybrid', limit: 60 }, classes: { 1: 12, 2: 11, 3: 11 }, questions: qs, nextQ: Math.max(...qs.map(q => q.id)) + 1, attempts: [], nextA: 1 };
    const r = rng(20261125), t0 = Date.now() - 40 * 60 * 1000;
    GROUPS.forEach(([g, c, n, mean]) => { for (let i = 0; i < n; i++) db.attempts.push(fake(r, g, c, 40 - i, mean, t0 + Math.floor(r() * 35 * 60 * 1000))); });   // 예시 학생은 40번부터 거꾸로
    save();
  }
  function simulateJoin() {
    const extra = db.attempts.filter(a => String(a.token).startsWith('demo-live')).length;
    if (extra >= 150 || Math.random() < .35) return;
    const add = Math.random() < .3 ? 2 : 1;
    for (let k = 0; k < add; k++) {
      const [g, c, , mean] = GROUPS[Math.floor(Math.random() * GROUPS.length)];
      const used = new Set(db.attempts.filter(a => a.grade === g && a.cls === c).map(a => a.num));
      let num = 40; while (used.has(num) && num >= 1) num--;
      if (num < 1) continue;
      const a = fake(Math.random, g, c, num, mean + 0.6, Date.now()); a.token = 'demo-live-' + a.token; db.attempts.push(a);
    }
    save();
  }

  /* ---------- 함수들 ---------- */
  const settingsJson = () => ({ ...db.settings, classes: { ...db.classes } });
  const findTok = t => db.attempts.find(a => a.token === t) || null;
  const itemResult = it => (it.answered ? { correct: it.correct, timeout: it.timeout, time: it.time, answer: it.answer, key: key(it.snap.type, it.snap.body), answerText: answerText(it.snap.type, it.snap.body), why: it.snap.body.why || '' } : null);
  const stateOf = a => ({
    token: a.token, grade: a.grade, cls: a.cls, num: a.num, name: a.name, done: !!a.finished, settings: settingsJson(),
    items: a.items.map(it => ({ pos: it.pos, area: it.area, topic: it.snap.topic, level: it.snap.level, type: it.snap.type, view: it.view,
      elapsed: it.opened ? (Date.now() - it.opened) / 1000 : null, hint: it.hint ? it.snap.body.hint : null, result: itemResult(it) })),
  });
  const admin = pw => { if (pw !== ADMIN_PW) fail('비밀번호가 맞지 않아요. (체험 모드 비밀번호: admin1234)'); };

  const F = {
    quiz_info: () => settingsJson(),
    quiz_start({ p_grade, p_cls, p_num, p_name }) {
      const name = String(p_name || '').replace(/\s/g, ''), max = db.classes[p_grade];
      if (!max) fail('학년을 다시 골라 주세요.');
      if (!(p_cls >= 1 && p_cls <= max)) fail(`${p_grade}학년은 1~${max}반까지 있어요.`);
      if (!(p_num >= 1 && p_num <= 40)) fail('번호를 다시 골라 주세요.');
      if (name.length < 2 || name.length > 10) fail('이름을 2~10글자로 적어 주세요.');
      let a = db.attempts.find(x => x.grade === p_grade && x.cls === p_cls && x.num === p_num);
      if (!a) {
        if (!db.settings.isOpen) fail('지금은 퀴즈 시간이 아니에요.');
        a = { id: db.nextA++, token: 'tok-' + Math.random().toString(36).slice(2) + Date.now().toString(36), grade: p_grade, cls: p_cls, num: p_num, name, started: Date.now(), finished: null, items: [] };
        let pos = 0;
        for (const ar of AREAS) {
          const pool = db.questions.filter(q => q.active && q.area === ar);
          const chosen = [], need = [0, 3, 1, 1];
          const img = shuffle(pool.filter(q => q.type.startsWith('img')))[0];
          if (img) { chosen.push(img); need[img.level] = Math.max(need[img.level] - 1, 0); }
          for (let lv = 1; lv <= 3; lv++) chosen.push(...shuffle(pool.filter(q => q.level === lv && !chosen.includes(q))).slice(0, need[lv]));
          if (chosen.length < 5) chosen.push(...shuffle(pool.filter(q => !chosen.includes(q))).slice(0, 5 - chosen.length));
          for (const q of shuffle(chosen)) a.items.push({ pos: pos++, qid: q.id, area: q.area, snap: { topic: q.topic, level: q.level, type: q.type, body: clone(q.body) }, view: view(q.type, q.body), opened: null, answered: null, answer: null, correct: null, timeout: null, hint: false, time: null });
        }
        if (!pos) fail('출제할 문제가 없어요. 선생님께 말해 주세요.');
        db.attempts.push(a); save();
      }
      if (a.name !== name) fail(String(a.token).startsWith('demo-') ? '체험 모드: 예시 학생이 쓰는 번호예요. 다른 번호(1~10번 등)를 골라 보세요.' : '이 번호는 다른 이름으로 이미 참여했어요. 선생님께 말해 주세요.');
      return stateOf(a);
    },
    quiz_open({ p_token, p_pos }) {
      const a = findTok(p_token); const it = a && !a.finished && a.items.find(i => i.pos === p_pos);
      if (!it) fail('문제를 찾을 수 없어요. 처음 화면에서 다시 들어와 주세요.');
      if (!it.opened) { it.opened = Date.now(); save(); }
      return { elapsed: (Date.now() - it.opened) / 1000 };
    },
    quiz_hint({ p_token, p_pos }) {
      const a = findTok(p_token); const it = a && a.items.find(i => i.pos === p_pos);
      if (!it) fail('문제를 찾을 수 없어요.');
      if (!it.answered) { it.hint = true; save(); }
      return { hint: it.snap.body.hint || '' };
    },
    quiz_answer({ p_token, p_pos, p_answer }) {
      const a = findTok(p_token); if (!a) fail('참여 정보를 찾을 수 없어요.');
      const it = a.items.find(i => i.pos === p_pos); if (!it) fail('문제를 찾을 수 없어요.');
      if (it.answered || a.finished) return itemResult(it);
      const lim = db.settings.limit, el = (Date.now() - (it.opened || Date.now() - lim * 1000)) / 1000;
      const tout = p_answer === null || p_answer === undefined || el > lim + 3;
      Object.assign(it, { answered: Date.now(), answer: p_answer ?? null, timeout: tout, correct: !tout && grade(it.snap.type, it.snap.body, p_answer), time: Math.round(Math.min(el, lim) * 10) / 10 });
      save(); return itemResult(it);
    },
    quiz_finish({ p_token }) {
      const a = findTok(p_token); if (!a) fail('참여 정보를 찾을 수 없어요.');
      if (a.finished) return { ok: true };
      const lim = db.settings.limit;
      a.items.forEach(it => { if (!it.answered) Object.assign(it, { answered: Date.now(), correct: false, timeout: true, time: lim }); });
      let run = 0, best = 0; a.items.forEach(it => { if (it.correct) { run++; best = Math.max(best, run); } else run = 0; });
      const ok = a.items.filter(i => i.correct);
      Object.assign(a, {
        finished: Date.now(), total: a.items.length, right: ok.length, score: Math.round(ok.length * 100 / a.items.length),
        time: Math.round(a.items.reduce((x, i) => x + i.time, 0)), hints: a.items.filter(i => i.hint).length, combo: best,
        bestQ: ok.length ? Math.min(...ok.map(i => i.time)) : null, clutch: ok.length ? Math.round(Math.min(...ok.map(i => lim - i.time)) * 10) / 10 : null,
        sr: [0, 1, 2].map(s => ok.filter(i => stageOf(i.area) === s).length),
        st: [0, 1, 2].map(s => Math.round(a.items.filter(i => stageOf(i.area) === s).reduce((x, i) => x + i.time, 0))),
      });
      a.flawless = a.right === a.total && a.hints === 0;
      save(); return { ok: true };
    },
    quiz_stats({ p_token, p_ver }) {
      if (window.MockDB.simulate) simulateJoin();
      const done = db.attempts.filter(a => a.finished).sort((x, y) => y.score - x.score || x.time - y.time || x.finished - y.finished);
      const me = db.attempts.find(a => a.token === p_token && a.finished);
      const ver = [done.length, Math.max(0, ...done.map(a => a.finished)), db.attempts.length, JSON.stringify(db.settings), me ? me.id : 0].join('/');
      if (p_ver && p_ver === ver) return { same: true, ver };
      return {
        ver, settings: settingsJson(), playing: db.attempts.filter(a => !a.finished).length,
        cols: ['sid', 'name', 'score', 'right', 'total', 'time', 'hints', 'combo', 'bestQ', 'clutch', 'sr', 'st', 'flawless', 'at', 'mine'],
        rows: done.map(a => [sidOf(a.grade, a.cls, a.num), maskName(a.name), a.score, a.right, a.total, a.time, a.hints, a.combo, a.bestQ, a.clutch, a.sr, a.st, a.flawless, a.finished, !!me && a.id === me.id]),
        me: me ? { name: me.name, grade: me.grade, cls: me.cls, num: me.num } : null,
      };
    },
    quiz_review({ p_token }) { const a = findTok(p_token); return a && a.finished ? stateOf(a) : null; },

    admin_login({ p_pw }) { admin(p_pw); return { ok: true }; },
    admin_data({ p_pw }) {
      admin(p_pw);
      const its = db.attempts.flatMap(a => a.items);
      return {
        settings: settingsJson(),
        questions: db.questions.map(q => { const u = its.filter(i => i.qid === q.id && i.answered); return { ...clone(q), used: its.filter(i => i.qid === q.id).length, rate: u.length ? Math.round(u.filter(i => i.correct).length * 100 / u.length) : null }; }),
        attempts: db.attempts.slice().sort((x, y) => (!!x.finished === !!y.finished ? (y.score ?? -1) - (x.score ?? -1) || (x.time ?? 0) - (y.time ?? 0) : x.finished ? -1 : 1))
          .map(a => ({ id: a.id, grade: a.grade, cls: a.cls, num: a.num, name: a.name, started: new Date(a.started).toISOString(), finished: a.finished ? new Date(a.finished).toISOString() : null, score: a.score ?? null, right: a.right ?? null, total: a.total ?? a.items.length, time: a.time ?? null, hints: a.hints ?? null, combo: a.combo ?? null, flawless: a.flawless ?? null, answered: a.items.filter(i => i.answered).length, items: a.items.length })),
      };
    },
    admin_attempt({ p_pw, p_id }) {
      admin(p_pw); const a = db.attempts.find(x => x.id === p_id);
      return a ? a.items.map(it => ({ pos: it.pos, area: it.area, type: it.snap.type, q: it.snap.body.q, answer: it.answer, answerText: answerText(it.snap.type, it.snap.body), correct: it.correct, timeout: it.timeout, hint: it.hint, time: it.time })) : null;
    },
    admin_save_settings({ p_pw, p }) {
      admin(p_pw); const s = db.settings;
      if (p.title && p.title.trim()) s.title = p.title.trim();
      if (p.school && p.school.trim()) s.school = p.school.trim();
      if (typeof p.isOpen === 'boolean') s.isOpen = p.isOpen;
      if (['count', 'rank', 'hybrid'].includes(p.tierMode)) s.tierMode = p.tierMode;
      if (p.limit) s.limit = Math.max(20, Math.min(180, Number(p.limit)));
      if (p.newPassword) fail('체험 모드에서는 비밀번호를 바꿀 수 없어요.');
      save(); return settingsJson();
    },
    admin_save_question({ p_pw, p }) {
      admin(p_pw);
      if (!AREAS.includes(p.area)) fail('영역을 골라 주세요.');
      if (!(p.level >= 1 && p.level <= 3)) fail('난이도를 골라 주세요.');
      checkBody(p.type, p.body || {});
      const row = { area: p.area, topic: p.topic || '', level: Number(p.level), type: p.type, active: p.active !== false, body: clone(p.body) };
      if (p.id) { const q = db.questions.find(x => x.id === p.id); if (!q) fail('문제를 찾을 수 없어요.'); Object.assign(q, row); }
      else { row.id = db.nextQ++; db.questions.push(row); }
      save(); return { id: p.id || row.id };
    },
    admin_set_active({ p_pw, p_id, p_active }) { admin(p_pw); const q = db.questions.find(x => x.id === p_id); if (q) q.active = !!p_active; save(); return { ok: true }; },
    admin_delete_question({ p_pw, p_id }) { admin(p_pw); db.questions = db.questions.filter(x => x.id !== p_id); save(); return { ok: true }; },
    admin_delete_attempt({ p_pw, p_id }) { admin(p_pw); db.attempts = db.attempts.filter(x => x.id !== p_id); save(); return { ok: true }; },
    admin_reset({ p_pw, p_confirm, p_grade = null, p_cls = null }) {
      admin(p_pw);
      if (p_confirm !== '초기화') fail('확인 글자가 맞지 않아요. 초기화 라고 적어 주세요.');
      if (p_cls != null && p_grade == null) fail('반만 지울 때는 학년도 골라 주세요.');
      const hit = x => (p_grade == null || x.grade === p_grade) && (p_cls == null || x.cls === p_cls);
      const n = db.attempts.filter(hit).length; db.attempts = db.attempts.filter(x => !hit(x)); save();
      return { ok: true, deleted: n };
    },
  };
  function maskName(n) { return n.length < 2 ? n : n.length === 2 ? n[0] + '*' : n[0] + '*'.repeat(n.length - 2) + n[n.length - 1]; }

  window.MockDB = {
    simulate: false,
    async call(fn, args) {
      ready = ready || init(); await ready;
      if (!F[fn]) throw new QuizError('알 수 없는 함수: ' + fn, false);
      try { localStorage.getItem(KEY) && (db = JSON.parse(localStorage.getItem(KEY)) || db); } catch (e) {}   // 다른 탭에서 바뀐 내용 반영
      await wait(60 + Math.random() * 120);
      return clone(F[fn](args || {}));
    },
    reset() { store.del(KEY); db = null; ready = null; },
  };
})();
