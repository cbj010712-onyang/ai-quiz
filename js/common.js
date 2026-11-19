/* =====================================================================
   AI·코딩 퀴즈 챌린지 · 공통 코드 (퀴즈 · 대시보드 · 관리자가 함께 써요)
   - 서버 부르기(rpc), 등급, 엠블럼, 칭호, 업적, 순위 계산, 작은 도구
   - config.js 에 Supabase 주소와 키가 없으면 '체험 모드'(mock.js)로 돌아가요
   ===================================================================== */
'use strict';

const CFG = window.QUIZ_CONFIG || {};
const DEMO = !CFG.url || !CFG.key || /여기에/.test(CFG.url + CFG.key);

/* ---------- 서버 부르기 ---------- */
class QuizError extends Error { constructor(msg, user) { super(msg); this.user = user; } }
async function rpc(fn, args = {}, tries = 3) {
  if (DEMO) {
    if (!window.MockDB) throw new QuizError('체험 모드 파일(js/mock.js)을 찾을 수 없어요.', true);
    return window.MockDB.call(fn, args);
  }
  const url = CFG.url.replace(/\/+$/, '') + '/rest/v1/rpc/' + fn;
  const headers = { 'Content-Type': 'application/json', apikey: CFG.key };
  if (CFG.key.startsWith('eyJ')) headers.Authorization = 'Bearer ' + CFG.key;   // 예전 anon 키
  for (let k = 1; ; k++) {
    let res;
    try { res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(args) }); }
    catch (e) { if (k < tries) { await wait(600 * k); continue; } throw new QuizError('인터넷 연결을 확인하고 다시 눌러 주세요.', false); }
    const txt = await res.text();
    let data = null; try { data = txt ? JSON.parse(txt) : null; } catch (e) {}
    if (res.ok) return data;
    if (data && data.code === 'P0001') throw new QuizError(data.message, true);         // 학생에게 보여 줄 안내
    if (res.status >= 500 && k < tries) { await wait(700 * k); continue; }
    throw new QuizError(res.status === 404 ? '서버 함수를 찾을 수 없어요. supabase.sql 을 실행했는지 확인해 주세요.' : '서버와 연결이 잠깐 끊겼어요. 다시 시도해 주세요.', false);
  }
}
const wait = ms => new Promise(r => setTimeout(r, ms));

/* ---------- 작은 도구 ---------- */
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
function shuffle(a) { a = a.slice(); for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; }
const fmtTime = sec => { sec = Math.round(sec || 0); const m = Math.floor(sec / 60), s = sec % 60; return m ? (s ? `${m}분 ${s}초` : `${m}분`) : `${s}초`; };
const stars = n => '★'.repeat(n) + `<span class="off">${'★'.repeat(3 - n)}</span>`;
const sidOf = (g, c, n) => `${g}${String(c).padStart(2, '0')}${String(n).padStart(2, '0')}`;
const store = {
  get(k) { try { return JSON.parse(localStorage.getItem(k)); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} },
  del(k) { try { localStorage.removeItem(k); } catch (e) {} },
};
const REDUCED = matchMedia('(prefers-reduced-motion: reduce)').matches;
function buzz(p) { try { if (navigator.vibrate) navigator.vibrate(p); } catch (e) {} }
function toast(msg) {
  const el = document.createElement('div'); el.className = 'toast'; el.setAttribute('role', 'status'); el.textContent = msg;
  document.body.appendChild(el); setTimeout(() => el.remove(), 2800);
}
function confetti(from) {
  if (REDUCED || !from || !document.body.animate) return;
  const r = from.getBoundingClientRect(), cx = r.left + r.width / 2, cy = r.top + r.height / 2, cols = ['#FFD43B', '#FF5A5F', '#22C55E', '#3B82F6', '#A855F7'];
  for (let k = 0; k < 18; k++) {
    const el = document.createElement('span'); el.className = 'cf'; el.style.left = cx + 'px'; el.style.top = cy + 'px'; el.style.background = cols[k % cols.length];
    document.body.appendChild(el);
    const dx = (Math.random() - .5) * 220, dy = -60 - Math.random() * 90;
    el.animate([{ transform: 'translate(-50%,-50%) rotate(0)', opacity: 1 }, { transform: `translate(${dx}px, ${dy}px) rotate(${Math.random() * 360}deg)`, opacity: 1, offset: .5 }, { transform: `translate(${dx * 1.2}px, ${dy + 120}px) rotate(${Math.random() * 720}deg)`, opacity: 0 }], { duration: 900 + Math.random() * 300, easing: 'cubic-bezier(.2,.7,.4,1)' }).onfinish = () => el.remove();
  }
}
/* 줄이 자리를 바꾸면 미끄러지듯 옮겨 가요 (FLIP) */
function flip(box, html, animate) {
  const before = {};
  if (animate) box.querySelectorAll('[data-key]').forEach(el => { before[el.dataset.key] = el.getBoundingClientRect().top; });
  box.innerHTML = html;
  if (!animate || !box.animate || REDUCED) return;
  box.querySelectorAll('[data-key]').forEach(el => {
    const b = before[el.dataset.key];
    if (b === undefined) { el.animate([{ opacity: 0, transform: 'translateX(-24px)' }, { opacity: 1, transform: 'none' }], { duration: 500, easing: 'ease-out' }); return; }
    const d = b - el.getBoundingClientRect().top;
    if (Math.abs(d) > 1) el.animate([{ transform: `translateY(${d}px)` }, { transform: 'none' }], { duration: 700, easing: 'cubic-bezier(.2,.8,.2,1)' });
  });
}
/* 순위가 바뀐 줄에 ▲▼ 표시 (4초) */
function makeMover() {
  const ranks = {}, moves = {};
  return (key, rank) => {
    const old = ranks[key];
    if (old !== undefined && old !== rank) moves[key] = { d: old - rank, at: Date.now() };
    ranks[key] = rank;
    const m = moves[key];
    if (!m || Date.now() - m.at > 4000) return '';
    return `<span class="mv ${m.d > 0 ? 'up' : 'down'}">${m.d > 0 ? '▲' : '▼'}${Math.abs(m.d)}</span>`;
  };
}
/* 참여 주소 QR (js/qrcode.js · MIT) */
function qrSvg(text) {
  if (typeof qrcode !== 'function') return '<p class="note">QR을 만들 수 없어요</p>';
  const q = qrcode(0, 'M'); q.addData(text); q.make();
  return q.createSvgTag({ cellSize: 8, margin: 2, scalable: true, alt: '퀴즈 참여 QR 코드' });
}
function demoRibbon() { if (DEMO) { const r = document.createElement('div'); r.className = 'demo-ribbon'; r.textContent = '체험 모드 · 예시 데이터'; document.body.appendChild(r); } }

/* ---------- 문제 화면에 쓰는 이름 ---------- */
const AREAS = ['파이썬', 'AI', '정보윤리'];
const AREA_INFO = {
  '파이썬': { color: '#15803D', desc: '코드를 읽고, 빈칸 채우고, 버그도 잡아요' },
  'AI': { color: '#1D4ED8', desc: '생활 속 AI, 얼마나 알고 있을까?' },
  '정보윤리': { color: '#6D28D9', desc: '내 계정과 친구를 지키는 선택은?' },
};
const KIND = { imgox: 'AI 판별', imgspot: '찾아 누르기', imgpick: '사진 고르기', ox: 'O / X', mc: '4지선다', multi: '모두 고르기', input: '직접 입력', fill: '빈칸 채우기', order: '블록 쌓기', match: '짝 맞추기', bug: '찾아내기', sort: '분류하기' };
const PAIR_COLORS = ['#FFD43B', '#7DD3FC', '#FDA4AF', '#86EFAC', '#C4B5FD', '#FDBA74'];

/* ---------- 등급 ----------
   count  : 맞힌 개수 (끝나자마자 정해지고 바뀌지 않음)
   rank   : 전체 순위 (다른 학생이 풀면 바뀜)
   hybrid : 다이아몬드까지는 개수, 마스터 이상은 14문제 이상 + 순위 */
const TIERS = [
  { name: '아이언', c1: '#B4B8C0', c2: '#5B5F68' },
  { name: '브론즈', c1: '#E0A472', c2: '#8A5530' },
  { name: '실버', c1: '#E6ECF2', c2: '#8C9AAB' },
  { name: '골드', c1: '#FFE066', c2: '#C98A00' },
  { name: '플래티넘', c1: '#7FEBDD', c2: '#1F9C8C' },
  { name: '에메랄드', c1: '#6EE7A0', c2: '#0E8A5F' },
  { name: '다이아몬드', c1: '#A5CDFF', c2: '#3563D6' },
  { name: '마스터', c1: '#DDBDFF', c2: '#7C3AED' },
  { name: '그랜드마스터', c1: '#FF9C9C', c2: '#C81E1E' },
  { name: '챌린저', c1: '#FFE58A', c2: '#2563EB' },
];
const MODES = {
  count: { label: '맞힌 개수', rules: ['0~3문제', '4~5문제', '6~7문제', '8~9문제', '10~11문제', '12문제', '13문제', '14문제', '15문제', '만점+5분 안'], note: '맞힌 개수로 정해져요. 만점을 5분 안에 끝내면 챌린저!' },
  rank: { label: '전체 순위', rules: ['나머지', '상위 90%', '상위 75%', '상위 60%', '상위 45%', '상위 30%', '상위 20%', '상위 10%', 'TOP 10', 'TOP 3'], note: '전체 순위(점수 → 빠른 시간)로 정해져요. 다른 친구가 풀면 바뀔 수 있어요.' },
  hybrid: { label: '개수 + 순위', rules: ['0~3문제', '4~5문제', '6~7문제', '8~9문제', '10~11문제', '12문제', '13문제+', '상위 10%', 'TOP 10', 'TOP 3'], note: '다이아몬드까지는 맞힌 개수, 마스터 이상은 14문제 이상 + 전체 순위로 정해져요.' },
};
const COUNT_MIN = { count: [0, 4, 6, 8, 10, 12, 13, 14, 15], hybrid: [0, 4, 6, 8, 10, 12, 13] };
const RANK_PCT = [1, .9, .75, .6, .45, .3, .2, .1];
const FAST_SECS = 300;
function rankCut(i, n) { if (i === 9) return 3; if (i === 8) return 10; return Math.max(1, Math.ceil(n * RANK_PCT[i])); }
function countTier(k, list) { let i = 0; list.forEach((m, t) => { if (k >= m) i = t; }); return i; }
function tierOf(mode, right, total, rank, n, secs) {
  const k = Math.round(right / Math.max(total, 1) * 15);
  if (mode === 'count') return k >= 15 && secs <= FAST_SECS ? 9 : countTier(k, COUNT_MIN.count);
  if (mode === 'rank') { for (let i = 9; i > 0; i--) if (rank <= rankCut(i, n)) return i; return 0; }
  if (k >= 14) for (let i = 9; i >= 7; i--) if (rank <= rankCut(i, n)) return i;
  return countTier(k, COUNT_MIN.hybrid);
}
function nextMsg(mode, i, right, total, rank, n) {
  const k = Math.round(right / Math.max(total, 1) * 15);
  if (i === 9) return '최고 등급! 정상에 섰어요';
  const nx = TIERS[i + 1].name;
  if (mode === 'count') return i === 8 ? `만점을 ${FAST_SECS / 60}분 안에 끝내면 챌린저!` : `${nx}까지 ${COUNT_MIN.count[i + 1] - k}문제 더!`;
  if (mode === 'rank' || i >= 7) return `${nx}까지 ${Math.max(1, rank - rankCut(i + 1, n))}계단!`;
  if (i === 6) return k >= 14 ? `상위 10%에 들면 ${nx}!` : `14문제 이상 + 상위 10%면 ${nx}!`;
  return `${nx}까지 ${COUNT_MIN.hybrid[i + 1] - k}문제 더!`;
}
function tierGrid(mode, cur) {
  return `<div class="tiers">${TIERS.map((t, i) => `<div class="lv${i === cur ? ' on' : ''}">${emblem(i, 44)}<span class="nm">${t.name.replace('그랜드마스터', '그랜드<br>마스터')}</span><small>${MODES[mode].rules[i]}</small></div>`).join('')}</div>`;
}

/* 등급 엠블럼 (직접 그린 방패). flawless 면 금색 월계관 */
function emblem(i, size, flawless) {
  const t = TIERS[i], ink = '#1B1B2F';
  const shield = 'M60 26 L92 38 V64 C92 84 78 98 60 106 C42 98 28 84 28 64 V38 Z';
  let s = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 120 120" aria-hidden="true">`;
  if (i >= 9) {
    let pts = ''; for (let k = 0; k < 24; k++) { const r = k % 2 ? 40 : 58, a = Math.PI * 2 * k / 24; pts += `${(60 + r * Math.sin(a)).toFixed(1)},${(64 - r * Math.cos(a)).toFixed(1)} `; }
    s += `<polygon points="${pts}" fill="#FFE58A" stroke="${ink}" stroke-width="2.5" stroke-linejoin="round"/>`;
  }
  if (i >= 2) {
    const ws = Math.min(1.15, 0.78 + 0.06 * (i - 2));
    const wing = 'M34 48 C18 40 6 48 2 62 C10 58 16 59 22 62 C12 66 8 74 8 84 C16 78 24 77 32 80 Z';
    const wc = i >= 8 ? t.c2 : i >= 6 ? t.c1 : '#E6ECF2';
    s += `<g transform="translate(60 62) scale(${ws}) translate(-60 -62)"><path d="${wing}" fill="${wc}" stroke="${ink}" stroke-width="3" stroke-linejoin="round"/><path d="${wing}" transform="translate(120 0) scale(-1 1)" fill="${wc}" stroke="${ink}" stroke-width="3" stroke-linejoin="round"/></g>`;
  }
  if (i >= 3 && i < 7) s += `<path d="M50 32 L60 10 L70 32 Z" fill="${t.c1}" stroke="${ink}" stroke-width="3" stroke-linejoin="round"/>`;
  if (i === 8) s += `<path d="M36 38 L26 16 L46 30 Z M84 38 L94 16 L74 30 Z" fill="${t.c2}" stroke="${ink}" stroke-width="3" stroke-linejoin="round"/>`;
  s += `<path d="${shield}" fill="${t.c2}" stroke="${ink}" stroke-width="3.5" stroke-linejoin="round"/>`;
  s += `<path d="${shield}" transform="translate(60 66) scale(.72) translate(-60 -66)" fill="${t.c1}" stroke="${ink}" stroke-width="2.5" stroke-linejoin="round"/>`;
  if (i === 1) s += `<circle cx="44" cy="44" r="3" fill="${ink}"/><circle cx="76" cy="44" r="3" fill="${ink}"/>`;
  if (i < 5) s += `<circle cx="60" cy="66" r="11" fill="#FFFFFF" stroke="${ink}" stroke-width="2.5"/>`;
  else if (i === 5) s += `<polygon points="60,52 72,59 72,73 60,80 48,73 48,59" fill="#10B981" stroke="${ink}" stroke-width="2.5"/><polygon points="60,57 66,61 60,65 54,61" fill="#A7F3D0"/>`;
  else s += `<polygon points="60,50 74,64 60,82 46,64" fill="#FFFFFF" stroke="${ink}" stroke-width="2.5" stroke-linejoin="round"/><path d="M46 64 H74 M60 50 L54 64 L60 82 M60 50 L66 64 L60 82" fill="none" stroke="${t.c2}" stroke-width="1.6"/>`;
  if (i >= 7) s += `<path d="M38 34 L41 12 L51 23 L60 6 L69 23 L79 12 L82 34 Z" fill="#FFD43B" stroke="${ink}" stroke-width="3" stroke-linejoin="round"/><circle cx="60" cy="25" r="3.5" fill="${i >= 8 ? '#FF5A5F' : '#7C3AED'}" stroke="${ink}" stroke-width="1.5"/>`;
  if (flawless) {
    for (const side of [-1, 1]) for (let k = 0; k < 6; k++) {
      const a = 100 + k * 13, rad = a * Math.PI / 180, x = 60 + side * 52 * Math.sin(rad), y = 64 - 52 * Math.cos(rad), rot = side > 0 ? a : 180 - a;
      s += `<ellipse cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" rx="8" ry="3.8" transform="rotate(${rot.toFixed(0)} ${x.toFixed(1)} ${y.toFixed(1)})" fill="#F5B700" stroke="${ink}" stroke-width="1.6"/>`;
    }
    s += `<polygon points="60,103 63,110 70,110 64.5,114 66.5,119 60,116 53.5,119 55.5,114 50,110 57,110" fill="#FFD43B" stroke="${ink}" stroke-width="1.6" stroke-linejoin="round"/>`;
  }
  return s + '</svg>';
}
const MINI = {};
const mini = (i, fl) => MINI[i + (fl ? 'f' : '')] || (MINI[i + (fl ? 'f' : '')] = emblem(i, 28, fl));

/* ---------- 칭호 (학교 전체에서 단 한 명) · 업적 (조건만 채우면 누구나) ---------- */
const minBy = (list, f) => list.reduce((best, p) => (best === undefined || f(p) < f(best) ? p : best), undefined);
const stageBest = st => all => minBy(all.filter(p => p.sr && p.sr[st] === 5), p => p.st[st] * 1e13 + p.at);
const TITLE_DEFS = [
  { id: 'king', name: '끝판왕', icon: 'trophy', bg: '#FFD43B', pick: (all, ranked) => ranked[0], detail: p => `전체 1등 · ${p.score}점 · ${fmtTime(p.time)}` },
  { id: 'first', name: '첫 도전자', icon: 'flag', bg: '#7DD3FC', pick: all => minBy(all, p => p.at), detail: () => '가장 먼저 도전했어요' },
  { id: 'firstPerfect', name: '첫 만점자', icon: 'crown', bg: '#FDE68A', pick: all => minBy(all.filter(p => p.score === 100), p => p.at), detail: p => `가장 먼저 만점 · ${fmtTime(p.time)}` },
  { id: 'firstFlawless', name: '첫 무결점', icon: 'star', bg: '#86EFAC', pick: all => minBy(all.filter(p => p.flawless), p => p.at), detail: () => '가장 먼저 힌트 없이 만점' },
  { id: 'fastest', name: '번개손', icon: 'bolt', bg: '#FEF08A', pick: all => minBy(all, p => p.time * 1e13 + p.at), detail: p => `${fmtTime(p.time)} 완주 · 점수 상관없이` },
  { id: 'combo', name: '콤보 킹', icon: 'flame', bg: '#FDA4AF', pick: all => minBy(all, p => -p.combo * 1e13 + p.at), detail: p => `${p.combo}연속 정답` },
  { id: 'oneshot', name: '원샷 원킬', icon: 'target', bg: '#FECACA', pick: all => minBy(all.filter(p => isFinite(p.bestQ)), p => p.bestQ * 1e13 + p.at), detail: p => `단 ${p.bestQ}초 만에 정답` },
  { id: 'buzzer', name: '극장골', icon: 'clock', bg: '#C7D2FE', pick: all => minBy(all.filter(p => isFinite(p.clutch)), p => p.clutch * 1e13 + p.at), detail: p => `${p.clutch}초 남기고 정답!` },
  { id: 'py', name: '파이썬 장인', icon: 'code', bg: '#BBF7D0', pick: stageBest(0), detail: p => `파이썬 5/5 · ${fmtTime(p.st[0])}` },
  { id: 'ai', name: 'AI 박사', icon: 'chip', bg: '#BFDBFE', pick: stageBest(1), detail: p => `AI 5/5 · ${fmtTime(p.st[1])}` },
  { id: 'eth', name: '보안관', icon: 'shield', bg: '#DDD6FE', pick: stageBest(2), detail: p => `정보윤리 5/5 · ${fmtTime(p.st[2])}` },
];
const ACH = [
  { id: 'flawless', name: '무결점', icon: 'star', bg: '#FFD43B', desc: '힌트 없이 만점', test: m => m.flawless },
  { id: 'py5', name: '파이썬 올킬', icon: 'code', bg: '#BBF7D0', desc: '파이썬 5문제 모두 정답', test: m => m.sr[0] === 5 },
  { id: 'ai5', name: 'AI 올킬', icon: 'chip', bg: '#BFDBFE', desc: 'AI 5문제 모두 정답', test: m => m.sr[1] === 5 },
  { id: 'eth5', name: '윤리 올킬', icon: 'shield', bg: '#DDD6FE', desc: '정보윤리 5문제 모두 정답', test: m => m.sr[2] === 5 },
  { id: 'nohint', name: '노힌트', icon: 'nohint', bg: '#E5E7EB', desc: '힌트를 한 번도 안 씀', test: m => m.hints === 0 },
  { id: 'combo10', name: '콤보 머신', icon: 'flame', bg: '#FDA4AF', desc: '10연속 정답', test: m => m.combo >= 10 },
  { id: 'speed', name: '스피드러너', icon: 'bolt', bg: '#FEF08A', desc: '4분 안에 완주', test: m => m.time <= 240 },
  { id: 'reflex', name: '순발력', icon: 'target', bg: '#FECACA', desc: '3초 안에 정답 맞히기', test: m => m.bestQ <= 3 },
  { id: 'clutch', name: '클러치', icon: 'clock', bg: '#C7D2FE', desc: '5초도 안 남기고 정답', test: m => m.clutch <= 5 },
];
function icon(kind, size = 40, bg = '#FFFFFF') {
  const ink = '#1B1B2F', sw = 'stroke="' + ink + '" stroke-width="2.4" stroke-linejoin="round"';
  const g = {
    flag: `<path d="M15 30 V10" stroke="${ink}" stroke-width="3" stroke-linecap="round"/><path d="M15 11 H28 L25 16 L28 21 H15 Z" fill="#FF5A5F" ${sw}/>`,
    crown: `<path d="M9 27 L11 13 L16 19 L20 10 L24 19 L29 13 L31 27 Z" fill="#FFFFFF" ${sw}/><text x="20" y="25" text-anchor="middle" font-size="8" font-weight="900" fill="${ink}" font-family="sans-serif">100</text>`,
    star: `<polygon points="20,8 23.5,15.5 31.5,16.3 25.5,21.6 27.3,29.5 20,25.4 12.7,29.5 14.5,21.6 8.5,16.3 16.5,15.5" fill="#FFD43B" ${sw}/>`,
    bolt: `<path d="M22 7 L11 22 H19 L17 33 L29 17 H21 Z" fill="#FFD43B" ${sw}/>`,
    flame: `<path d="M20 33 C12 33 9 27 11 21 C12 17 15 15 15 10 C19 13 20 16 20 19 C22 17 23 15 23 12 C28 16 31 21 29 26 C28 30 25 33 20 33 Z" fill="#FF5A5F" ${sw}/>`,
    target: `<circle cx="20" cy="20" r="11.5" fill="#FFFFFF" ${sw}/><circle cx="20" cy="20" r="7" fill="#FF5A5F" ${sw}/><circle cx="20" cy="20" r="2.6" fill="#FFFFFF" stroke="${ink}" stroke-width="1.8"/>`,
    clock: `<circle cx="20" cy="21" r="11" fill="#FFFFFF" ${sw}/><path d="M20 14.5 V21 L24.5 24" fill="none" stroke="${ink}" stroke-width="2.6" stroke-linecap="round"/><path d="M16 8 H24" stroke="${ink}" stroke-width="2.6" stroke-linecap="round"/>`,
    code: `<text x="20" y="25" text-anchor="middle" font-size="13" font-weight="900" fill="${ink}" font-family="monospace">&lt;/&gt;</text>`,
    chip: `<rect x="12" y="12" width="16" height="16" rx="3" fill="#FFFFFF" ${sw}/><path d="M16 9 V12 M20 9 V12 M24 9 V12 M16 28 V31 M20 28 V31 M24 28 V31 M9 16 H12 M9 20 H12 M9 24 H12 M28 16 H31 M28 20 H31 M28 24 H31" stroke="${ink}" stroke-width="2" stroke-linecap="round"/><text x="20" y="23" text-anchor="middle" font-size="7.5" font-weight="900" fill="${ink}" font-family="sans-serif">AI</text>`,
    shield: `<path d="M20 9 L29 12.5 V20 C29 26 25 30 20 32 C15 30 11 26 11 20 V12.5 Z" fill="#FFFFFF" ${sw}/><path d="M15.5 20.5 L19 24 L25 17" fill="none" stroke="#16A34A" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`,
    trophy: `<path d="M13 12 H9 C9 17 11 19 14 19 M27 12 H31 C31 17 29 19 26 19" fill="none" stroke="${ink}" stroke-width="2.4"/><path d="M13 9 H27 V16 C27 21 24 24 20 24 C16 24 13 21 13 16 Z" fill="#FFD43B" ${sw}/><path d="M17 24 H23 V28 H17 Z M14 28 H26 V32 H14 Z" fill="#FFFFFF" ${sw}/>`,
    nohint: `<circle cx="20" cy="17" r="7.5" fill="#FFF1A8" ${sw}/><path d="M17 24 H23 V29 H17 Z" fill="#FFFFFF" ${sw}/><path d="M10 30 L30 10" stroke="#FF5A5F" stroke-width="3.2" stroke-linecap="round"/>`,
  }[kind];
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 40 40" aria-hidden="true"><circle cx="20" cy="20" r="18" fill="${bg}" stroke="${ink}" stroke-width="2.4"/>${g}</svg>`;
}
const titleIcon = (id, size) => { const t = TITLE_DEFS.find(x => x.id === id); return icon(t.icon, size, t.bg); };

/* ---------- quiz_stats 결과 → 순위표 ---------- */
function buildBoard(stats) {
  const st = stats.settings, mode = st.tierMode;
  const rows = (stats.rows || []).map(r => {
    const o = Object.fromEntries(stats.cols.map((c, i) => [c, r[i]]));
    o.grade = +o.sid[0]; o.cls = +o.sid.slice(1, 3); o.num = +o.sid.slice(3, 5);
    o.bestQ = o.bestQ == null ? Infinity : +o.bestQ; o.clutch = o.clutch == null ? Infinity : +o.clutch;
    o.sr = o.sr || [0, 0, 0]; o.st = o.st || [0, 0, 0];
    return o;
  });
  const n = rows.length;
  let rk = 0, pk = null;
  rows.forEach((p, i) => { const k = p.score + '/' + p.time; if (k !== pk) { rk = i + 1; pk = k; } p.rank = rk; });   // 서버가 이미 순서대로 줘요
  rows.forEach(p => { p.tier = tierOf(mode, p.right, p.total, p.rank, n, p.time); });
  const me = rows.find(p => p.mine) || null;
  if (me && stats.me) me.fullName = stats.me.name;
  const cmap = {};
  rows.forEach(p => { const k = p.grade + '-' + p.cls; (cmap[k] = cmap[k] || { key: k, grade: p.grade, cls: p.cls, n: 0, total: 0, mine: false }); cmap[k].n++; cmap[k].total += p.score; if (p.mine) cmap[k].mine = true; });
  const classes = Object.values(cmap).sort((a, b) => b.total - a.total || a.grade - b.grade || a.cls - b.cls);
  let cr = 0, prev = null; classes.forEach((c, i) => { if (c.total !== prev) { cr = i + 1; prev = c.total; } c.rank = cr; c.avg = Math.round(c.total / c.n * 10) / 10; });
  const perfect = rows.filter(p => p.score === 100).sort((a, b) => a.time - b.time || a.at - b.at);
  const avg = n ? Math.round(rows.reduce((a, p) => a + p.score, 0) / n * 10) / 10 : 0;
  const titles = TITLE_DEFS.map(t => { const h = n ? t.pick(rows, rows) : undefined; return { ...t, holder: h, text: h ? t.detail(h) : '' }; });
  const out = { settings: st, mode, rows, n, me, classes, perfect, avg, titles, playing: stats.playing || 0 };
  if (me) {
    out.achs = ACH.map(a => ({ ...a, got: !!a.test(me) }));
    out.mine = titles.filter(t => t.holder === me);
    out.next = nextMsg(mode, me.tier, me.right, me.total, me.rank, n);
    out.myClass = classes.find(c => c.mine);
  }
  return out;
}
