-- =====================================================================
--  AI·코딩 퀴즈 챌린지 · Supabase 설정
--  Supabase → SQL Editor → New query 에 이 파일 전체를 붙여 넣고 Run.
--  다시 실행해도 괜찮아요 (참가 기록과 문제는 지워지지 않아요).
--  ※ 맨 아래 "관리자 비밀번호" 줄은 꼭 바꿔서 실행하세요.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 0) 예전 버전(15문제 · quiz_responses)을 실행했었다면 정리
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'quiz_questions' and column_name = 'no') then
    drop table if exists quiz_responses cascade;
    drop table if exists quiz_questions cascade;
    drop table if exists quiz_settings cascade;
    for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname in ('quiz_get', 'quiz_submit', 'quiz_my_result', 'quiz_stats', 'quiz__result', 'quiz__check', 'quiz__answer_text', 'quiz__mask')
    loop execute 'drop function ' || f.sig; end loop;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1) 테이블
-- ---------------------------------------------------------------------
create table if not exists quiz_settings (
  id          int primary key default 1 check (id = 1),
  title       text not null default 'AI·코딩 퀴즈 챌린지',
  school      text not null default '온양고등학교',
  is_open     boolean not null default true,             -- false면 새로 시작할 수 없어요
  tier_mode   text not null default 'hybrid' check (tier_mode in ('count', 'rank', 'hybrid')),
  time_limit  int not null default 60 check (time_limit between 20 and 180),
  admin_hash  text                                       -- 관리자 비밀번호 (암호화되어 저장)
);
insert into quiz_settings (id) values (1) on conflict (id) do nothing;

create table if not exists quiz_classes (
  grade   int primary key check (grade between 1 and 3),
  classes int not null check (classes between 1 and 20)
);
insert into quiz_classes (grade, classes) values (1, 12), (2, 11), (3, 11)
  on conflict (grade) do update set classes = excluded.classes;      -- 1학년 1~12반, 2·3학년 1~11반

create table if not exists quiz_questions (
  id         bigserial primary key,
  area       text not null check (area in ('파이썬', 'AI', '정보윤리')),
  topic      text not null default '',
  level      int  not null check (level between 1 and 3),
  type       text not null check (type in ('ox', 'mc', 'multi', 'input', 'fill', 'order', 'match', 'bug', 'sort', 'imgox', 'imgspot', 'imgpick')),
  active     boolean not null default true,              -- false면 출제되지 않아요
  body       jsonb not null,                             -- 문제 내용 + 정답 + 힌트 + 해설
  updated_at timestamptz not null default now()
);

create table if not exists quiz_attempts (
  id          bigserial primary key,
  token       uuid not null unique default gen_random_uuid(),  -- 학생 휴대폰만 아는 열쇠
  grade int not null, cls int not null, num int not null,
  name        text not null,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  right_count int, total int, score int, time_sec int, hints int, combo int,
  best_q numeric, clutch numeric, stage_right int[], stage_time int[], flawless boolean,
  unique (grade, cls, num)                                       -- 첫 도전만 인정
);

create table if not exists quiz_items (
  attempt_id  bigint not null references quiz_attempts(id) on delete cascade,
  pos         int not null,
  question_id bigint references quiz_questions(id) on delete set null,
  area        text not null,
  snapshot    jsonb not null,     -- 출제 순간의 문제 (정답 포함 · 학생에게 안 보여요)
  view        jsonb not null,     -- 학생에게 보여 주는 모양 (정답 없음)
  opened_at   timestamptz,
  answered_at timestamptz,
  answer      jsonb,
  correct     boolean,
  timeout     boolean,
  hint        boolean not null default false,
  time_sec    numeric,
  primary key (attempt_id, pos)
);

-- 학생 브라우저가 표를 직접 읽거나 쓰지 못하게 막아요 (모든 일은 아래 함수로만)
alter table quiz_settings  enable row level security;
alter table quiz_classes   enable row level security;
alter table quiz_questions enable row level security;
alter table quiz_attempts  enable row level security;
alter table quiz_items     enable row level security;
revoke all on quiz_settings, quiz_classes, quiz_questions, quiz_attempts, quiz_items from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) 도우미 함수 (밖에서 못 불러요)
-- ---------------------------------------------------------------------
create or replace function quiz__err(msg text) returns void language plpgsql as $$
begin raise exception '%', msg using errcode = 'P0001'; end $$;

create or replace function quiz__norm(s text) returns text language sql immutable as $$
  select regexp_replace(lower(coalesce(s, '')), '[[:space:]''"`]', '', 'g') $$;

create or replace function quiz__mask(n text) returns text language sql immutable as $$
  select case when char_length(n) < 2 then n
              when char_length(n) = 2 then left(n, 1) || '*'
              else left(n, 1) || repeat('*', char_length(n) - 2) || right(n, 1) end $$;

create or replace function quiz__sid(g int, c int, n int) returns text language sql immutable as $$
  select g::text || lpad(c::text, 2, '0') || lpad(n::text, 2, '0') $$;

create or replace function quiz__stage(area text) returns int language sql immutable as $$
  select case area when '파이썬' then 0 when 'AI' then 1 else 2 end $$;

-- 학생에게 보여 줄 모양: 정답·힌트·해설을 빼고, 순서가 정답이 되는 것은 섞어서 보내요
create or replace function quiz__view(t text, b jsonb) returns jsonb language plpgsql volatile as $$
declare v jsonb := b - 'answer' - 'answers' - 'why' - 'hint' - 'spot' - 'spotLabel';
begin
  v := v || jsonb_build_object('hasHint', coalesce(length(b->>'hint'), 0) > 0);
  if t in ('mc', 'multi') then
    v := jsonb_set(v, '{options}', (select jsonb_agg(e order by random()) from jsonb_array_elements(b->'options') e));
  elsif t = 'order' then
    v := jsonb_set(v, '{blocks}', (select jsonb_agg(e order by random()) from jsonb_array_elements(b->'blocks') e));
  elsif t = 'fill' then
    v := jsonb_set(v, '{chips}', (select jsonb_agg(e order by random()) from jsonb_array_elements(b->'chips') e));
  elsif t = 'match' then
    v := (v - 'pairs') || jsonb_build_object(
      'left',  (select jsonb_agg(e->0 order by random()) from jsonb_array_elements(b->'pairs') e),
      'right', (select jsonb_agg(e->1 order by random()) from jsonb_array_elements(b->'pairs') e));
  elsif t = 'sort' then
    v := (v - 'items') || jsonb_build_object('items', (select jsonb_agg(e->0 order by random()) from jsonb_array_elements(b->'items') e));
  end if;
  return v;
end $$;

-- 채점 (학생 답은 보기 '글자'로 와요 → 보기 순서를 섞어도 안전)
create or replace function quiz__grade(t text, b jsonb, a jsonb) returns boolean language plpgsql immutable as $$
begin
  if a is null or jsonb_typeof(a) = 'null' then return false; end if;
  case t
    when 'ox', 'imgox' then return a #>> '{}' = b->>'answer';
    when 'mc' then return a #>> '{}' = b->'options'->>((b->>'answer')::int);
    when 'multi' then
      return (select coalesce(array_agg(distinct x order by x), '{}') from jsonb_array_elements_text(a) x)
           = (select coalesce(array_agg(distinct o order by o), '{}') from (select b->'options'->>(i::int) as o from jsonb_array_elements_text(b->'answers') i) s);
    when 'input' then
      return exists (select 1 from jsonb_array_elements_text(b->'answer') x where quiz__norm(x) = quiz__norm(a #>> '{}'));
    when 'fill' then return a = b->'answer';
    when 'order' then return a = b->'blocks';
    when 'match' then
      return jsonb_array_length(a) = jsonb_array_length(b->'pairs')
         and (select array_agg(k order by k) from (select (e->>0) || chr(31) || (e->>1) as k from jsonb_array_elements(a) e) s)
           = (select array_agg(k order by k) from (select (e->>0) || chr(31) || (e->>1) as k from jsonb_array_elements(b->'pairs') e) s);
    when 'sort' then
      return jsonb_array_length(a) = jsonb_array_length(b->'items')
         and (select array_agg(k order by k) from (select (e->>0) || chr(31) || (e->>1) as k from jsonb_array_elements(a) e) s)
           = (select array_agg(k order by k) from (select (e->>0) || chr(31) || (e->>1) as k from jsonb_array_elements(b->'items') e) s);
    when 'bug', 'imgpick' then return (a #>> '{}')::int = (b->>'answer')::int;
    when 'imgspot' then
      return (a->>'x')::numeric between (b->'spot'->>0)::numeric and (b->'spot'->>0)::numeric + (b->'spot'->>2)::numeric
         and (a->>'y')::numeric between (b->'spot'->>1)::numeric and (b->'spot'->>1)::numeric + (b->'spot'->>3)::numeric;
    else return false;
  end case;
exception when others then return false;
end $$;

-- 답한 뒤에 보여 줄 정답 (학생 화면의 색칠용)
create or replace function quiz__key(t text, b jsonb) returns jsonb language sql immutable as $$
  select case t
    when 'mc' then b->'options'->((b->>'answer')::int)
    when 'multi' then (select jsonb_agg(b->'options'->(i::int)) from jsonb_array_elements_text(b->'answers') i)
    when 'input' then b->'answer'->0
    when 'order' then b->'blocks'
    when 'match' then b->'pairs'
    when 'sort' then b->'items'
    when 'imgspot' then b->'spot'
    else b->'answer' end $$;

create or replace function quiz__answer_text(t text, b jsonb) returns text language sql immutable as $$
  select case t
    when 'ox' then b->>'answer'
    when 'imgox' then b->>'answer'
    when 'mc' then b->'options'->>((b->>'answer')::int)
    when 'multi' then (select string_agg(b->'options'->>(i::int), ', ') from jsonb_array_elements_text(b->'answers') i)
    when 'input' then b->'answer'->>0
    when 'fill' then (select string_agg(x, '  /  ') from jsonb_array_elements_text(b->'answer') x)
    when 'order' then (select string_agg(trim(x), '  →  ' order by n) from jsonb_array_elements_text(b->'blocks') with ordinality as o(x, n))
    when 'match' then (select string_agg((e->>0) || '  →  ' || (e->>1), E'\n' order by n) from jsonb_array_elements(b->'pairs') with ordinality as o(e, n))
    when 'sort' then (select string_agg(bk || ': ' || coalesce((select string_agg(it->>0, ', ') from jsonb_array_elements(b->'items') it where (it->>1)::int = bn - 1), ''), E'\n' order by bn)
                      from jsonb_array_elements_text(b->'buckets') with ordinality as o(bk, bn))
    when 'bug' then trim(b->'lines'->>((b->>'answer')::int))
    when 'imgpick' then chr(65 + (b->>'answer')::int) || ' 사진'
    when 'imgspot' then coalesce(b->>'spotLabel', '표시된 곳')
  end $$;

-- 관리자가 저장하는 문제가 올바른지 검사
create or replace function quiz__check_body(t text, b jsonb) returns void language plpgsql as $$
declare n int;
begin
  if coalesce(trim(b->>'q'), '') = '' then perform quiz__err('문제 글을 적어 주세요.'); end if;
  case t
    when 'ox', 'imgox' then
      if coalesce(b->>'answer', '') not in ('O', 'X') then perform quiz__err('정답을 O 또는 X로 골라 주세요.'); end if;
    when 'mc', 'multi' then
      if jsonb_array_length(coalesce(b->'options', '[]')) < 2 then perform quiz__err('보기를 2개 이상 적어 주세요.'); end if;
      if (select count(distinct x) from jsonb_array_elements_text(b->'options') x) <> jsonb_array_length(b->'options') then perform quiz__err('보기 글자가 서로 달라야 해요.'); end if;
      if t = 'mc' and not ((b->>'answer')::int between 0 and jsonb_array_length(b->'options') - 1) then perform quiz__err('정답 보기를 골라 주세요.'); end if;
      if t = 'multi' and jsonb_array_length(coalesce(b->'answers', '[]')) = 0 then perform quiz__err('정답 보기를 하나 이상 골라 주세요.'); end if;
    when 'input' then
      if jsonb_array_length(coalesce(b->'answer', '[]')) = 0 then perform quiz__err('인정할 정답을 하나 이상 적어 주세요.'); end if;
    when 'fill' then
      n := (select count(*) from regexp_matches(b->>'code', '\{\d\}', 'g'));
      if n = 0 then perform quiz__err('빈칸 자리에 {0}, {1} 처럼 적어 주세요.'); end if;
      if jsonb_array_length(coalesce(b->'answer', '[]')) <> n then perform quiz__err('빈칸 수와 정답 수가 같아야 해요.'); end if;
      if exists (select 1 from jsonb_array_elements_text(b->'answer') x where not (b->'chips') ? x) then perform quiz__err('정답은 블록 목록에도 들어 있어야 해요.'); end if;
      if (select count(distinct x) from jsonb_array_elements_text(b->'chips') x) <> jsonb_array_length(b->'chips') then perform quiz__err('블록 글자가 서로 달라야 해요.'); end if;
    when 'order' then
      if jsonb_array_length(coalesce(b->'blocks', '[]')) < 2 then perform quiz__err('블록을 2개 이상 적어 주세요.'); end if;
      if (select count(distinct x) from jsonb_array_elements_text(b->'blocks') x) <> jsonb_array_length(b->'blocks') then perform quiz__err('블록 글자가 서로 달라야 해요.'); end if;
    when 'match' then
      if jsonb_array_length(coalesce(b->'pairs', '[]')) < 2 then perform quiz__err('짝을 2개 이상 적어 주세요.'); end if;
      if (select count(distinct e->>0) from jsonb_array_elements(b->'pairs') e) <> jsonb_array_length(b->'pairs')
         or (select count(distinct e->>1) from jsonb_array_elements(b->'pairs') e) <> jsonb_array_length(b->'pairs') then perform quiz__err('짝 글자가 서로 달라야 해요.'); end if;
    when 'sort' then
      if jsonb_array_length(coalesce(b->'buckets', '[]')) <> 2 then perform quiz__err('분류 이름을 2개 적어 주세요.'); end if;
      if jsonb_array_length(coalesce(b->'items', '[]')) < 2 then perform quiz__err('분류할 항목을 2개 이상 적어 주세요.'); end if;
    when 'bug' then
      if jsonb_array_length(coalesce(b->'lines', '[]')) < 2 then perform quiz__err('줄을 2개 이상 적어 주세요.'); end if;
      if not ((b->>'answer')::int between 0 and jsonb_array_length(b->'lines') - 1) then perform quiz__err('정답 줄을 골라 주세요.'); end if;
    when 'imgspot' then
      if coalesce(b->>'img', '') = '' then perform quiz__err('그림 주소를 적어 주세요.'); end if;
      if jsonb_array_length(coalesce(b->'spot', '[]')) <> 4 then perform quiz__err('그림에서 정답 영역을 지정해 주세요.'); end if;
    when 'imgpick' then
      if jsonb_array_length(coalesce(b->'imgs', '[]')) <> 2 then perform quiz__err('그림 주소 2개를 적어 주세요.'); end if;
    else null;
  end case;
  if t = 'imgox' and coalesce(b->>'img', '') = '' then perform quiz__err('그림 주소를 적어 주세요.'); end if;
end $$;

create or replace function quiz__admin(p_pw text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  select admin_hash into h from quiz_settings where id = 1;
  if h is null then perform quiz__err('관리자 비밀번호가 아직 없어요. supabase.sql 맨 아래 줄로 먼저 정해 주세요.'); end if;
  if p_pw is null or crypt(p_pw, h) <> h then
    perform pg_sleep(1);    -- 마구 넣어 보기 늦추기
    perform quiz__err('비밀번호가 맞지 않아요.');
  end if;
end $$;

-- SQL Editor 에서만 쓰는 비밀번호 설정 함수
create or replace function quiz__set_password(p_new text) returns text language plpgsql security definer set search_path = public, extensions as $$
begin
  if char_length(coalesce(p_new, '')) < 6 then perform quiz__err('비밀번호는 6글자 이상으로 해 주세요.'); end if;
  update quiz_settings set admin_hash = crypt(p_new, gen_salt('bf')) where id = 1;
  return '관리자 비밀번호를 저장했어요.';
end $$;

create or replace function quiz__settings_json() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('title', s.title, 'school', s.school, 'isOpen', s.is_open, 'tierMode', s.tier_mode, 'limit', s.time_limit,
         'classes', (select jsonb_object_agg(grade, classes) from quiz_classes))
  from quiz_settings s where s.id = 1 $$;

-- 한 문제의 결과 (답한 뒤에만)
create or replace function quiz__item_result(i quiz_items) returns jsonb language sql stable as $$
  select case when i.answered_at is null then null else jsonb_build_object(
    'correct', i.correct, 'timeout', i.timeout, 'time', i.time_sec, 'answer', i.answer,
    'key', quiz__key(i.snapshot->>'type', i.snapshot->'body'),
    'answerText', quiz__answer_text(i.snapshot->>'type', i.snapshot->'body'),
    'why', i.snapshot->'body'->>'why') end $$;

-- 학생 화면이 이어서 그릴 수 있게 지금 상태를 통째로
create or replace function quiz__state(p_id bigint) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'token', a.token, 'grade', a.grade, 'cls', a.cls, 'num', a.num, 'name', a.name, 'done', a.finished_at is not null,
    'settings', quiz__settings_json(),
    'items', (select jsonb_agg(jsonb_build_object(
        'pos', i.pos, 'area', i.area, 'topic', i.snapshot->>'topic', 'level', (i.snapshot->>'level')::int,
        'type', i.snapshot->>'type', 'view', i.view,
        'elapsed', case when i.opened_at is null then null else extract(epoch from now() - i.opened_at) end,
        'hint', case when i.hint then i.snapshot->'body'->>'hint' end,
        'result', quiz__item_result(i)) order by i.pos)
      from quiz_items i where i.attempt_id = a.id))
  from quiz_attempts a where a.id = p_id $$;

-- ---------------------------------------------------------------------
-- 3) 학생용 함수
-- ---------------------------------------------------------------------
create or replace function quiz_info() returns jsonb language sql stable security definer set search_path = public as $$
  select quiz__settings_json() $$;

-- 시작 (같은 학년·반·번호·이름이면 하던 곳부터 이어서)
create or replace function quiz_start(p_grade int, p_cls int, p_num int, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s quiz_settings; a quiz_attempts; v_name text := regexp_replace(coalesce(p_name, ''), '\s', '', 'g');
  v_max int; ar text; chosen bigint[]; img_id bigint; img_lv int; need int[]; lv int; v_pos int := 0; qid bigint; q quiz_questions;
begin
  select * into s from quiz_settings where id = 1;
  select classes into v_max from quiz_classes where grade = p_grade;
  if v_max is null then perform quiz__err('학년을 다시 골라 주세요.'); end if;
  if p_cls is null or p_cls < 1 or p_cls > v_max then perform quiz__err(p_grade || '학년은 1~' || v_max || '반까지 있어요.'); end if;
  if p_num is null or p_num < 1 or p_num > 40 then perform quiz__err('번호를 다시 골라 주세요.'); end if;
  if char_length(v_name) < 2 or char_length(v_name) > 10 then perform quiz__err('이름을 2~10글자로 적어 주세요.'); end if;

  select * into a from quiz_attempts where grade = p_grade and cls = p_cls and num = p_num;
  if not found then
    if not s.is_open then perform quiz__err('지금은 퀴즈 시간이 아니에요.'); end if;
    insert into quiz_attempts (grade, cls, num, name) values (p_grade, p_cls, p_num, v_name)
      on conflict (grade, cls, num) do nothing returning * into a;
    if a.id is null then   -- 거의 동시에 두 번 눌렀을 때
      select * into a from quiz_attempts where grade = p_grade and cls = p_cls and num = p_num;
    else
      -- 스테이지마다: 그림 문제 1개(있으면) + ★3 · ★★1 · ★★★1
      foreach ar in array array['파이썬', 'AI', '정보윤리'] loop
        chosen := '{}'; need := array[3, 1, 1]; img_id := null;
        select id, level into img_id, img_lv from quiz_questions where active and area = ar and type like 'img%' order by random() limit 1;
        if img_id is not null then chosen := chosen || img_id; need[img_lv] := greatest(need[img_lv] - 1, 0); end if;
        for lv in 1..3 loop
          chosen := chosen || coalesce((select array_agg(id) from (select id from quiz_questions where active and area = ar and level = lv and id <> all(chosen) order by random() limit need[lv]) x), '{}');
        end loop;
        if coalesce(array_length(chosen, 1), 0) < 5 then
          chosen := chosen || coalesce((select array_agg(id) from (select id from quiz_questions where active and area = ar and id <> all(chosen) order by random() limit 5 - coalesce(array_length(chosen, 1), 0)) x), '{}');
        end if;
        for qid in select x from unnest(chosen) x order by random() loop
          select * into q from quiz_questions where id = qid;
          insert into quiz_items (attempt_id, pos, question_id, area, snapshot, view)
          values (a.id, v_pos, q.id, q.area, jsonb_build_object('topic', q.topic, 'level', q.level, 'type', q.type, 'body', q.body), quiz__view(q.type, q.body));
          v_pos := v_pos + 1;
        end loop;
      end loop;
      if v_pos = 0 then delete from quiz_attempts where id = a.id; perform quiz__err('출제할 문제가 없어요. 선생님께 말해 주세요.'); end if;
    end if;
  end if;
  if a.name <> v_name then perform quiz__err('이 번호는 다른 이름으로 이미 참여했어요. 선생님께 말해 주세요.'); end if;
  return quiz__state(a.id);
end $$;

-- 문제를 화면에 띄운 순간 (서버가 시간을 재요)
create or replace function quiz_open(p_token uuid, p_pos int) returns jsonb language plpgsql security definer set search_path = public as $$
declare i quiz_items;
begin
  update quiz_items set opened_at = coalesce(opened_at, now())
   where attempt_id = (select id from quiz_attempts where token = p_token and finished_at is null) and pos = p_pos
  returning * into i;
  if i.attempt_id is null then perform quiz__err('문제를 찾을 수 없어요. 처음 화면에서 다시 들어와 주세요.'); end if;
  return jsonb_build_object('elapsed', extract(epoch from now() - i.opened_at));
end $$;

create or replace function quiz_hint(p_token uuid, p_pos int) returns jsonb language plpgsql security definer set search_path = public as $$
declare i quiz_items;
begin
  update quiz_items set hint = hint or answered_at is null
   where attempt_id = (select id from quiz_attempts where token = p_token) and pos = p_pos
  returning * into i;
  if i.attempt_id is null then perform quiz__err('문제를 찾을 수 없어요.'); end if;
  return jsonb_build_object('hint', i.snapshot->'body'->>'hint');
end $$;

-- 답 제출 (p_answer 가 null 이면 시간 초과). 한 문제에 한 번만 · 다시 보내면 처음 결과를 돌려줘요
create or replace function quiz_answer(p_token uuid, p_pos int, p_answer jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare i quiz_items; a quiz_attempts; lim int; el numeric; tout boolean; ok boolean;
begin
  select * into a from quiz_attempts where token = p_token;
  if not found then perform quiz__err('참여 정보를 찾을 수 없어요.'); end if;
  select * into i from quiz_items where attempt_id = a.id and pos = p_pos for update;
  if not found then perform quiz__err('문제를 찾을 수 없어요.'); end if;
  if i.answered_at is not null or a.finished_at is not null then return quiz__item_result(i); end if;
  select time_limit into lim from quiz_settings where id = 1;
  el := extract(epoch from now() - coalesce(i.opened_at, now() - make_interval(secs => lim)));
  tout := p_answer is null or jsonb_typeof(p_answer) = 'null' or el > lim + 3;   -- 3초는 인터넷 지연 여유
  ok := not tout and quiz__grade(i.snapshot->>'type', i.snapshot->'body', p_answer);
  update quiz_items set answered_at = now(), answer = p_answer, correct = ok, timeout = tout, time_sec = round(least(el, lim), 1)
   where attempt_id = a.id and pos = p_pos returning * into i;
  return quiz__item_result(i);
end $$;

-- 끝내기: 안 푼 문제는 시간 초과로 두고 기록을 계산해요
create or replace function quiz_finish(p_token uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare a quiz_attempts; lim int; r record; run int := 0; best int := 0;
begin
  select * into a from quiz_attempts where token = p_token for update;
  if not found then perform quiz__err('참여 정보를 찾을 수 없어요.'); end if;
  if a.finished_at is not null then return jsonb_build_object('ok', true); end if;
  select time_limit into lim from quiz_settings where id = 1;
  update quiz_items set answered_at = now(), correct = false, timeout = true, time_sec = lim
   where attempt_id = a.id and answered_at is null;
  for r in select correct from quiz_items where attempt_id = a.id order by pos loop
    if r.correct then run := run + 1; best := greatest(best, run); else run := 0; end if;
  end loop;
  update quiz_attempts t set
    finished_at = now(),
    total       = x.total,
    right_count = x.right_count,
    score       = round(x.right_count * 100.0 / greatest(x.total, 1)),
    time_sec    = round(x.time_sec),
    hints       = x.hints,
    combo       = best,
    best_q      = x.best_q,
    clutch      = x.clutch,
    stage_right = array[x.r0, x.r1, x.r2],
    stage_time  = array[round(x.t0)::int, round(x.t1)::int, round(x.t2)::int],
    flawless    = x.right_count = x.total and x.hints = 0
  from (select count(*) as total, count(*) filter (where correct) as right_count, coalesce(sum(time_sec), 0) as time_sec,
               count(*) filter (where hint) as hints,
               min(time_sec) filter (where correct) as best_q, min(lim - time_sec) filter (where correct) as clutch,
               count(*) filter (where correct and quiz__stage(area) = 0) as r0, count(*) filter (where correct and quiz__stage(area) = 1) as r1, count(*) filter (where correct and quiz__stage(area) = 2) as r2,
               coalesce(sum(time_sec) filter (where quiz__stage(area) = 0), 0) as t0, coalesce(sum(time_sec) filter (where quiz__stage(area) = 1), 0) as t1, coalesce(sum(time_sec) filter (where quiz__stage(area) = 2), 0) as t2
        from quiz_items where attempt_id = a.id) x
  where t.id = a.id;
  return jsonb_build_object('ok', true);
end $$;

-- 대시보드·결과 화면용 (이름은 가운데를 가려서). p_ver 가 그대로면 내용을 다시 보내지 않아요
create or replace function quiz_stats(p_token uuid default null, p_ver text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v text; me bigint;
begin
  select coalesce(max(finished_at)::text, '-') || '/' || count(*) filter (where finished_at is not null) || '/' || count(*)
         || '/' || (select tier_mode || is_open::text || title || time_limit from quiz_settings where id = 1)
    into v from quiz_attempts;
  select id into me from quiz_attempts where token = p_token and finished_at is not null;
  v := v || '/' || coalesce(me, 0);
  if p_ver is not null and p_ver = v then return jsonb_build_object('same', true, 'ver', v); end if;
  return jsonb_build_object(
    'ver', v,
    'settings', quiz__settings_json(),
    'playing', (select count(*) from quiz_attempts where finished_at is null),
    'cols', jsonb_build_array('sid', 'name', 'score', 'right', 'total', 'time', 'hints', 'combo', 'bestQ', 'clutch', 'sr', 'st', 'flawless', 'at', 'mine'),
    'rows', coalesce((select jsonb_agg(jsonb_build_array(quiz__sid(grade, cls, num), quiz__mask(name), score, right_count, total, time_sec, hints, combo,
                       best_q, clutch, stage_right, stage_time, flawless, (extract(epoch from finished_at) * 1000)::bigint, id = coalesce(me, 0))
                     order by score desc, time_sec asc, finished_at asc)
                     from quiz_attempts where finished_at is not null), '[]'::jsonb),
    'me', (select jsonb_build_object('name', name, 'grade', grade, 'cls', cls, 'num', num) from quiz_attempts where id = me));
end $$;

-- 내가 푼 문제 다시 보기 (끝난 뒤)
create or replace function quiz_review(p_token uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select quiz__state(id) from quiz_attempts where token = p_token and finished_at is not null $$;

-- ---------------------------------------------------------------------
-- 4) 관리자용 함수 (비밀번호가 맞을 때만)
-- ---------------------------------------------------------------------
create or replace function admin_login(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
begin perform quiz__admin(p_pw); return jsonb_build_object('ok', true); end $$;

create or replace function admin_data(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform quiz__admin(p_pw);
  return jsonb_build_object(
    'settings', quiz__settings_json(),
    'questions', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'area', area, 'topic', topic, 'level', level, 'type', type, 'active', active, 'body', body,
                   'used', (select count(*) from quiz_items i where i.question_id = q.id),
                   'rate', (select round(avg(case when i.correct then 100 else 0 end)) from quiz_items i where i.question_id = q.id and i.answered_at is not null))
                   order by case area when '파이썬' then 0 when 'AI' then 1 else 2 end, level, id) from quiz_questions q), '[]'),
    'attempts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'grade', grade, 'cls', cls, 'num', num, 'name', name,
                   'started', started_at, 'finished', finished_at, 'score', score, 'right', right_count, 'total', total, 'time', time_sec,
                   'hints', hints, 'combo', combo, 'flawless', flawless,
                   'answered', (select count(*) from quiz_items i where i.attempt_id = a.id and i.answered_at is not null),
                   'items', (select count(*) from quiz_items i where i.attempt_id = a.id))
                   order by finished_at is null, score desc nulls last, time_sec, finished_at) from quiz_attempts a), '[]'));
end $$;

create or replace function admin_attempt(p_pw text, p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform quiz__admin(p_pw);
  return (select jsonb_agg(jsonb_build_object('pos', pos, 'area', area, 'type', snapshot->>'type', 'q', snapshot->'body'->>'q',
            'answer', answer, 'answerText', quiz__answer_text(snapshot->>'type', snapshot->'body'), 'correct', correct, 'timeout', timeout,
            'hint', hint, 'time', time_sec) order by pos) from quiz_items where attempt_id = p_id);
end $$;

create or replace function admin_save_settings(p_pw text, p jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform quiz__admin(p_pw);
  update quiz_settings set
    title      = coalesce(nullif(trim(p->>'title'), ''), title),
    school     = coalesce(nullif(trim(p->>'school'), ''), school),
    is_open    = coalesce((p->>'isOpen')::boolean, is_open),
    tier_mode  = coalesce(p->>'tierMode', tier_mode),
    time_limit = coalesce((p->>'limit')::int, time_limit)
  where id = 1;
  if coalesce(p->>'newPassword', '') <> '' then perform quiz__set_password(p->>'newPassword'); end if;
  return quiz__settings_json();
end $$;

create or replace function admin_save_question(p_pw text, p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint := (p->>'id')::bigint; t text := p->>'type';
begin
  perform quiz__admin(p_pw);
  if coalesce(p->>'area', '') not in ('파이썬', 'AI', '정보윤리') then perform quiz__err('영역을 골라 주세요.'); end if;
  if coalesce((p->>'level')::int, 0) not between 1 and 3 then perform quiz__err('난이도를 골라 주세요.'); end if;
  perform quiz__check_body(t, p->'body');
  if v_id is null then
    insert into quiz_questions (area, topic, level, type, active, body)
    values (p->>'area', coalesce(p->>'topic', ''), (p->>'level')::int, t, coalesce((p->>'active')::boolean, true), p->'body') returning id into v_id;
  else
    update quiz_questions set area = p->>'area', topic = coalesce(p->>'topic', ''), level = (p->>'level')::int, type = t,
      active = coalesce((p->>'active')::boolean, active), body = p->'body', updated_at = now() where id = v_id;
    if not found then perform quiz__err('문제를 찾을 수 없어요.'); end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function admin_set_active(p_pw text, p_id bigint, p_active boolean) returns jsonb language plpgsql security definer set search_path = public as $$
begin perform quiz__admin(p_pw); update quiz_questions set active = p_active, updated_at = now() where id = p_id; return jsonb_build_object('ok', true); end $$;

create or replace function admin_delete_question(p_pw text, p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
begin perform quiz__admin(p_pw); delete from quiz_questions where id = p_id; return jsonb_build_object('ok', true); end $$;

-- 한 학생 기록 지우기 = 다시 도전할 수 있게 하기
create or replace function admin_delete_attempt(p_pw text, p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
begin perform quiz__admin(p_pw); delete from quiz_attempts where id = p_id; return jsonb_build_object('ok', true); end $$;

-- 기록 초기화: 전체 / 한 학년 / 한 반. 지운 학생 수를 돌려줘요.
--   p_grade, p_cls 를 비우면 전체, p_grade 만 주면 그 학년, 둘 다 주면 그 반만 지워요.
drop function if exists admin_reset(text, text);
create or replace function admin_reset(p_pw text, p_confirm text, p_grade int default null, p_cls int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform quiz__admin(p_pw);
  if p_confirm is distinct from '초기화' then perform quiz__err('확인 글자가 맞지 않아요. 초기화 라고 적어 주세요.'); end if;
  if p_cls is not null and p_grade is null then perform quiz__err('반만 지울 때는 학년도 골라 주세요.'); end if;
  delete from quiz_attempts
   where (p_grade is null or grade = p_grade)
     and (p_cls is null or cls = p_cls);
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;

-- ---------------------------------------------------------------------
-- 5) 권한: 학생(anon)은 아래 함수만 부를 수 있어요
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'quiz%' or p.proname like 'admin%')
  loop execute 'revoke execute on function ' || f.sig || ' from public, anon, authenticated'; end loop;
end $$;
-- 새 프로젝트에서 'Grant API access to new tables automatically'를 꺼도 함수는 부를 수 있게 (표는 계속 잠겨 있어요)
grant usage on schema public to anon, authenticated;
grant execute on function quiz_info(), quiz_start(int, int, int, text), quiz_open(uuid, int), quiz_hint(uuid, int),
  quiz_answer(uuid, int, jsonb), quiz_finish(uuid), quiz_stats(uuid, text), quiz_review(uuid),
  admin_login(text), admin_data(text), admin_attempt(text, bigint), admin_save_settings(text, jsonb), admin_save_question(text, jsonb),
  admin_set_active(text, bigint, boolean), admin_delete_question(text, bigint), admin_delete_attempt(text, bigint), admin_reset(text, text, int, int)
  to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6) 처음 문제 54개 (문제가 하나도 없을 때만 넣어요)
-- ---------------------------------------------------------------------
insert into quiz_questions (area, topic, level, type, body)
select e->>'area', e->>'topic', (e->>'level')::int, e->>'type', e->'body'
from jsonb_array_elements($seed$[{"area": "파이썬", "topic": "변수", "level": 1, "type": "mc", "body": {"q": "보스한테 한 대 맞았다! 화면에 나오는 HP는?", "code": "hp = 100\nhp = hp - 30\nprint(hp)", "options": ["70", "100", "30", "hp"], "answer": 0, "hint": "= 의 오른쪽을 먼저 계산해서 왼쪽에 넣어요. 100 - 30 은?", "why": "= 는 오른쪽 값을 왼쪽에 넣는다는 뜻이에요. 100 - 30 = 70이 hp에 다시 들어가요."}}, {"area": "파이썬", "topic": "조건문", "level": 2, "type": "mc", "body": {"q": "오늘 경기에서 2골을 넣었다. 화면에 뭐가 나올까?", "code": "goal = 2\nif goal >= 3:\n    print('해트트릭!')\nelif goal >= 1:\n    print('골 넣었다!')\nelse:\n    print('다음 경기에...')", "options": ["골 넣었다!", "해트트릭!", "다음 경기에...", "아무것도 안 나온다"], "answer": 0, "hint": "위에서부터 차례로 검사해요. 2는 3 이상일까? 1 이상일까?", "why": "2는 3 이상이 아니라서 첫 조건은 건너뛰고, 1 이상인 두 번째 조건에서 멈춰요."}}, {"area": "파이썬", "topic": "반복문", "level": 1, "type": "input", "body": {"q": "'레벨업!'은 몇 번 출력될까? 숫자로 적어요.", "code": "for i in range(3):\n    print('레벨업!')", "answer": ["3", "3번"], "placeholder": "숫자", "hint": "range(3)은 0, 1, 2를 만들어요. 모두 몇 개일까요?", "why": "range(3)은 0, 1, 2 세 개를 만들어요. 그래서 3번 반복해요."}}, {"area": "파이썬", "topic": "입력", "level": 2, "type": "mc", "body": {"q": "함정 주의! 3과 4를 입력하면 화면에 뭐가 나올까?", "code": "a = input('숫자: ')   # 3 입력\nb = input('숫자: ')   # 4 입력\nprint(a + b)", "options": ["34", "7", "12", "오류가 난다"], "answer": 0, "hint": "input()으로 받은 값은 숫자가 아니라 \"글자\"예요. 글자끼리 더하면?", "why": "글자끼리 + 하면 이어 붙여서 34가 돼요. 숫자로 더하려면 int()로 바꿔요."}}, {"area": "파이썬", "topic": "반복문", "level": 2, "type": "order", "body": {"q": "3, 2, 1 카운트다운 후 \"발사!\"를 출력하도록 블록을 쌓아요.", "blocks": ["n = 3", "while n > 0:", "    print(n)", "    n = n - 1", "print('발사!')"], "hint": "n = 3 으로 시작! 출력하고 나서 1 줄이기. \"발사!\"는 맨 마지막이에요.", "why": "n이 0보다 큰 동안 n을 출력하고 1씩 줄여요. 줄이기 전에 출력해야 3, 2, 1이 나와요."}}, {"area": "파이썬", "topic": "변수", "level": 1, "type": "ox", "body": {"q": "파이썬에서 변수 이름은 숫자로 시작할 수 있다. (예: 1st_score)", "answer": "X", "hint": "score1 은 되는데, 1score 는 될까요?", "why": "변수 이름은 숫자로 시작할 수 없어요. first_score, score1처럼 써요."}}, {"area": "파이썬", "topic": "반복문", "level": 2, "type": "fill", "body": {"q": "1부터 5까지 출력하려고 해요. 빈칸에 들어갈 블록을 골라요.", "code": "for i in {0}(1, {1}):\n    print(i)", "chips": ["range", "6", "5", "list"], "answer": ["range", "6"], "hint": "range의 끝 숫자는 포함되지 않아요. 5까지 나오려면 끝을 몇으로?", "why": "range(1, 6)은 1부터 6 바로 전인 5까지 만들어요."}}, {"area": "파이썬", "topic": "연산", "level": 2, "type": "input", "body": {"q": "화면에 나오는 숫자를 적어요.", "code": "print(2 ** 3)", "answer": ["8"], "placeholder": "숫자", "hint": "** 는 거듭제곱이에요. 2를 3번 곱해요: 2 × 2 × 2", "why": "2 ** 3 = 2 × 2 × 2 = 8"}}, {"area": "파이썬", "topic": "오류 찾기", "level": 1, "type": "bug", "body": {"q": "이 코드는 실행하면 오류가 나요. 문제가 있는 줄을 눌러요.", "lines": ["score = 85", "if score >= 80", "    print('합격!')"], "answer": 1, "hint": "if 줄 끝에 꼭 붙여야 하는 기호가 있어요.", "why": "if 줄 끝에는 콜론(:)이 꼭 있어야 해요. if score >= 80: 으로 고쳐요."}}, {"area": "파이썬", "topic": "반복문", "level": 3, "type": "input", "body": {"q": "화면에 나오는 숫자를 적어요.", "code": "total = 0\nfor i in range(1, 4):\n    total = total + i\nprint(total)", "answer": ["6"], "placeholder": "숫자", "hint": "i는 1, 2, 3이 돼요. 0 + 1 + 2 + 3 = ?", "why": "i가 1, 2, 3일 때 차례로 더해요. 0 + 1 + 2 + 3 = 6"}}, {"area": "파이썬", "topic": "연산", "level": 2, "type": "match", "body": {"q": "코드와 실행 결과를 짝지어요.", "code_left": true, "pairs": [["print(3 + 4)", "7"], ["print('하' * 3)", "하하하"], ["len('abc')", "3"], ["print(10 - 2)", "8"]], "hint": "len은 글자 수, 글자 * 3은 글자를 3번 반복해요.", "why": "3 + 4 = 7, '하' * 3 = 하하하, 'abc'는 3글자, 10 - 2 = 8"}}, {"area": "파이썬", "topic": "함수", "level": 1, "type": "mc", "body": {"q": "화면에 글자를 보여 주는 함수는?", "options": ["print()", "input()", "len()", "range()"], "answer": 0, "hint": "\"프린트(print)\" = 출력하다", "why": "print()는 출력, input()은 입력 받기, len()은 길이, range()는 숫자 범위예요."}}, {"area": "파이썬", "topic": "반복문", "level": 2, "type": "multi", "body": {"q": "반복할 때 쓰는 키워드를 모두 골라요.", "options": ["for", "while", "if", "print"], "answers": [0, 1], "hint": "정답은 2개! 하나는 \"~동안\"이라는 뜻이에요.", "why": "for와 while이 반복문이에요. if는 조건문, print는 출력 함수예요."}}, {"area": "파이썬", "topic": "반복문", "level": 3, "type": "mc", "body": {"q": "이 코드를 실행하면 어떻게 될까?", "code": "n = 1\nwhile n < 5:\n    print(n)", "options": ["1이 끝없이 계속 출력된다", "1, 2, 3, 4가 출력되고 끝난다", "아무것도 출력되지 않는다", "바로 오류가 난다"], "answer": 0, "hint": "n 값을 바꾸는 줄이 있나요? n은 계속 몇일까요?", "why": "n이 바뀌지 않아서 n < 5가 계속 참이에요. 무한 반복을 막으려면 n = n + 1 이 필요해요."}}, {"area": "파이썬", "topic": "조건문", "level": 2, "type": "fill", "body": {"q": "비밀번호가 맞으면 로그인, 아니면 경고를 보여 줘요. 빈칸을 채워요.", "code": "pw = input('비밀번호: ')\nif pw {0} '1234':\n    print('로그인 성공')\n{1}:\n    print('틀렸어요')", "chips": ["==", "else", "=", "for"], "answer": ["==", "else"], "hint": "\"같다\"를 비교할 때는 = 를 두 번! 그 밖의 경우는?", "why": "같은지 비교할 때는 == 를 써요. = 는 값을 넣을 때 써요. 나머지 모든 경우는 else예요."}}, {"area": "파이썬", "topic": "주석", "level": 1, "type": "ox", "body": {"q": "# 뒤에 쓴 글자는 실행되지 않는 주석이다.", "answer": "O", "hint": "코드에 메모를 남길 때 쓰는 기호예요.", "why": "#부터 그 줄 끝까지는 사람이 읽는 설명(주석)이라 실행되지 않아요."}}, {"area": "파이썬", "topic": "오류 찾기", "level": 2, "type": "bug", "body": {"q": "인벤토리 아이템을 하나씩 출력하려는데 오류가 나요. 문제가 있는 줄을 눌러요.", "lines": ["items = ['검', '방패', '물약']", "for item in items:", "print(item)"], "answer": 2, "hint": "for 안에서 반복할 줄은 앞에 띄어쓰기(들여쓰기)가 필요해요.", "why": "for 안에서 반복할 줄은 스페이스 4칸 들여써야 해요. \"    print(item)\"으로 고쳐요."}}, {"area": "파이썬", "topic": "조건문", "level": 3, "type": "order", "body": {"q": "점수가 90점 이상이면 A, 아니면 B를 출력하도록 블록을 쌓아요.", "blocks": ["score = 95", "if score >= 90:", "    print('A')", "else:", "    print('B')"], "hint": "점수 정하기 → if → 할 일 → else → 할 일 순서예요.", "why": "먼저 점수를 정하고 if로 비교해요. 조건에 맞지 않으면 else 아래가 실행돼요."}}, {"area": "AI", "topic": "AI 기초", "level": 1, "type": "mc", "body": {"q": "AI는 무엇의 줄임말일까?", "options": ["Artificial Intelligence", "Automatic Internet", "Advanced Information", "Android Interface"], "answer": 0, "hint": "Intelligence = 지능", "why": "AI는 Artificial Intelligence, 우리말로 인공지능이에요."}}, {"area": "AI", "topic": "생활 속 AI", "level": 2, "type": "sort", "body": {"q": "AI 기술이 쓰인 것과 아닌 것을 나눠요.", "buckets": ["AI 기술", "AI 아님"], "items": [["유튜브 추천 영상", 0], ["휴대폰 얼굴 인식 잠금", 0], ["실시간 번역 앱", 0], ["방 전등 스위치", 1], ["계산기의 덧셈 버튼", 1], ["엘리베이터 층 버튼", 1]], "hint": "스스로 배우고 판단하면 AI! 누르는 대로만 움직이면 AI가 아니에요. (3개씩)", "why": "AI는 데이터로 배우고 스스로 판단해요. 스위치나 버튼처럼 정해진 대로만 움직이는 건 AI가 아니에요."}}, {"area": "AI", "topic": "AI 한계", "level": 1, "type": "ox", "body": {"q": "AI 챗봇이 자신 있게 말한 답은 항상 사실이다.", "answer": "X", "hint": "AI도 그럴듯하게 틀릴 때가 있어요. \"환각\"이라는 말을 들어 봤나요?", "why": "AI는 그럴듯한 거짓말(환각, 할루시네이션)을 할 수 있어요. 중요한 내용은 다른 자료로 확인해요."}}, {"area": "AI", "topic": "머신러닝", "level": 1, "type": "mc", "body": {"q": "AI가 고양이 사진을 구별하게 만들려면 가장 먼저 필요한 것은?", "options": ["고양이 사진 데이터 엄청 많이", "비싼 게이밍 키보드", "진짜 고양이 한 마리", "와이파이 비밀번호"], "answer": 0, "hint": "AI는 \"많이 보고\" 배워요.", "why": "AI는 많은 데이터를 보고 공통된 특징을 스스로 배워요. 이걸 머신러닝이라고 해요."}}, {"area": "AI", "topic": "추천 AI", "level": 1, "type": "ox", "body": {"q": "유튜브는 내가 많이 본 영상과 비슷한 영상을 더 많이 추천해 준다.", "answer": "O", "hint": "게임 영상을 많이 보면 홈 화면에 뭐가 뜨나요?", "why": "추천 AI는 내 시청 기록을 학습해요. 비슷한 것만 계속 보게 되는 걸 필터 버블이라고 해요."}}, {"area": "AI", "topic": "AI 용어", "level": 2, "type": "match", "body": {"q": "AI 용어와 뜻을 짝지어요.", "pairs": [["머신러닝", "데이터로 스스로 배우는 방법"], ["생성형 AI", "글·그림을 새로 만드는 AI"], ["할루시네이션", "AI가 그럴듯한 거짓말을 하는 것"], ["학습 데이터", "AI가 배우는 데 쓰는 자료"]], "hint": "러닝(learning) = 배우기, 생성 = 새로 만들기", "why": "이 네 가지 용어만 알아도 AI 뉴스를 훨씬 쉽게 읽을 수 있어요."}}, {"area": "AI", "topic": "생성형 AI", "level": 1, "type": "mc", "body": {"q": "ChatGPT, Gemini처럼 글을 새로 써 주는 AI를 무엇이라고 할까?", "options": ["생성형 AI", "계산기 AI", "검색 엔진", "운영체제"], "answer": 0, "hint": "\"새로 만들어 낸다\" = 생성", "why": "새로운 글·그림·음악 등을 만들어 내는 AI를 생성형 AI라고 해요."}}, {"area": "AI", "topic": "머신러닝", "level": 2, "type": "ox", "body": {"q": "고양이 사진만 학습한 AI도 강아지 사진을 보면 \"강아지\"라고 정확히 알아본다.", "answer": "X", "hint": "배운 적 없는 걸 알아볼 수 있을까요?", "why": "AI는 배운 적 없는 것은 알아보지 못해요. 무엇을 배우게 하느냐가 중요해요."}}, {"area": "AI", "topic": "데이터 편향", "level": 3, "type": "mc", "body": {"q": "남자 의사 사진만 잔뜩 학습한 AI에게 \"의사 그림\"을 그려 달라고 하면?", "options": ["대부분 남자 의사를 그린다", "남녀를 정확히 반반 그린다", "그림 그리기를 거부한다", "동물 의사를 그린다"], "answer": 0, "hint": "AI는 본 데이터를 그대로 따라 해요.", "why": "데이터가 한쪽으로 치우치면 AI의 결과도 치우쳐요. 이걸 데이터 편향이라고 해요."}}, {"area": "AI", "topic": "생성형 AI", "level": 2, "type": "multi", "body": {"q": "생성형 AI가 만들어 낼 수 있는 것을 모두 골라요.", "options": ["소설 같은 글", "그림", "음악", "내가 어제 실제로 한 일의 기록"], "answers": [0, 1, 2], "hint": "AI가 알 수 없는 것은 딱 하나예요.", "why": "생성형 AI는 글, 그림, 음악을 만들 수 있어요. 하지만 내가 실제로 한 일은 AI가 알 수 없어요."}}, {"area": "AI", "topic": "AI 기초", "level": 1, "type": "input", "body": {"q": "AI(Artificial Intelligence)를 우리말 네 글자로 적어요.", "answer": ["인공지능"], "placeholder": "네 글자", "hint": "인공○○ — 사람이 만든 \"지능\"", "why": "Artificial(인공) + Intelligence(지능) = 인공지능"}}, {"area": "AI", "topic": "머신러닝", "level": 3, "type": "order", "body": {"q": "AI를 만드는 순서대로 블록을 쌓아요.", "text_blocks": true, "blocks": ["데이터 모으기", "AI 학습시키기", "잘 맞히는지 시험하기", "실제 서비스에 쓰기"], "hint": "요리처럼! 재료(데이터) 준비 → 요리 → 맛보기 → 손님에게", "why": "데이터를 모아 학습시키고, 시험을 거쳐야 실제로 쓸 수 있어요."}}, {"area": "AI", "topic": "생활 속 AI", "level": 1, "type": "ox", "body": {"q": "자율주행 자동차는 AI 기술을 사용한다.", "answer": "O", "hint": "사람 없이 스스로 차선과 신호를 알아봐야 해요.", "why": "자율주행차는 카메라와 센서 정보를 AI로 분석해 사람, 차선, 신호를 알아봐요."}}, {"area": "AI", "topic": "AI 판단", "level": 3, "type": "mc", "body": {"q": "AI가 사진을 보고 \"고양이일 확률 92%\"라고 했다. 무슨 뜻일까?", "options": ["꽤 확신하지만 틀릴 수도 있다", "100% 고양이가 맞다", "사진의 92%가 고양이로 채워져 있다", "고양이가 92마리 있다"], "answer": 0, "hint": "100%가 아니라면?", "why": "AI의 판단은 확률이에요. 92%여도 틀릴 수 있으니 중요한 판단은 사람이 확인해요."}}, {"area": "AI", "topic": "AI 역사", "level": 2, "type": "mc", "body": {"q": "2016년 이세돌 9단과 바둑 대결을 펼친 AI의 이름은?", "options": ["알파고", "딥블루", "시리", "빅스비"], "answer": 0, "hint": "\"알파\"로 시작해요.", "why": "구글 딥마인드의 알파고예요. 딥블루는 체스 AI, 시리와 빅스비는 음성 비서예요."}}, {"area": "AI", "topic": "머신러닝", "level": 2, "type": "fill", "body": {"q": "빈칸을 채워 문장을 완성해요.", "code": "AI는 많은 {0}를 보고\n그 안의 {1}을 찾아 스스로 배운다.", "plain": true, "chips": ["데이터", "패턴", "광고", "운"], "answer": ["데이터", "패턴"], "hint": "AI가 보는 재료, 그리고 그 안에서 반복되는 \"규칙\"", "why": "AI는 데이터 속 반복되는 특징(패턴)을 찾아 배워요."}}, {"area": "정보윤리", "topic": "비밀번호", "level": 2, "type": "mc", "body": {"q": "게임 사이트 비밀번호가 유출됐다! 학교·SNS 계정도 같은 비밀번호라면 가장 먼저 할 일은?", "options": ["같은 비밀번호를 쓰는 계정을 전부 바꾼다", "별일 없겠지, 그냥 둔다", "게임만 탈퇴한다", "친구에게 비밀번호를 알려 둔다"], "answer": 0, "hint": "해커는 훔친 비밀번호를 다른 사이트에도 넣어 봐요.", "why": "같은 비밀번호를 쓴 계정은 모두 위험해요. 전부 바꿔야 해요."}}, {"area": "정보윤리", "topic": "딥페이크", "level": 1, "type": "ox", "body": {"q": "친구 얼굴을 AI로 합성해 웃긴 영상을 만들어 단톡방에 올리는 건 장난이니까 괜찮다.", "answer": "X", "hint": "친구가 허락했나요? 내가 당하면 기분이 어떨까요?", "why": "동의 없는 얼굴 합성은 장난이라도 초상권 침해나 명예훼손이 될 수 있고, 처벌받을 수도 있어요."}}, {"area": "정보윤리", "topic": "AI 이미지", "level": 2, "type": "mc", "body": {"q": "AI로 만든 사진인지 확인하는 방법으로 알맞지 않은 것은?", "options": ["좋아요 수가 많은지 보기", "손가락 개수와 모양 보기", "글자가 뭉개졌는지 보기", "원본 출처를 검색해 보기"], "answer": 0, "hint": "인기가 많으면 진짜일까요?", "why": "좋아요가 많다고 진짜인 건 아니에요. 손, 글자, 출처를 확인해요."}}, {"area": "정보윤리", "topic": "피싱", "level": 1, "type": "ox", "body": {"q": "\"게임 아이템 무료 지급! 링크 누르고 아이디·비밀번호 입력\" 메시지는 피싱일 가능성이 높다.", "answer": "O", "hint": "\"공짜\" + \"비밀번호 입력\"이 같이 나오면?", "why": "공짜를 미끼로 계정을 훔치는 피싱이에요. 공식 앱이 아닌 곳에 비밀번호를 넣지 않아요."}}, {"area": "정보윤리", "topic": "비밀번호", "level": 1, "type": "mc", "body": {"q": "다음 중 가장 안전한 비밀번호는?", "options": ["Goal!Kick7#Night", "minsu2009", "12345678", "qwerty"], "answer": 0, "hint": "길고, 대문자·숫자·특수문자가 섞인 것!", "why": "길고, 여러 종류 문자가 섞이고, 이름·생일 같은 개인정보가 없어야 해요."}}, {"area": "정보윤리", "topic": "계정 보안", "level": 2, "type": "sort", "body": {"q": "계정을 지키는 습관과 위험한 습관을 나눠요.", "buckets": ["안전", "위험"], "items": [["사이트마다 다른 비밀번호", 0], ["2단계 인증 켜기", 0], ["공용 PC에서 로그아웃하기", 0], ["생일로 비밀번호 만들기", 1], ["친구와 게임 계정 공유하기", 1], ["모든 사이트에 같은 비밀번호", 1]], "hint": "\"나만 알고, 사이트마다 다르게!\" (3개씩)", "why": "비밀번호는 나만 알고, 사이트마다 다르게, 그리고 2단계 인증으로 한 번 더 지켜요."}}, {"area": "정보윤리", "topic": "SNS", "level": 2, "type": "multi", "body": {"q": "SNS에 올리면 위험할 수 있는 정보를 모두 골라요.", "options": ["학교 이름이 보이는 교복 사진", "집 주소", "지금 있는 곳의 실시간 위치", "어제 먹은 라면 사진"], "answers": [0, 1, 2], "hint": "내가 어디 살고, 어디 있는지 알려 주는 것은?", "why": "학교, 주소, 실시간 위치는 내가 어디 있는지 알려 줘요. 음식 사진은 보통 괜찮아요."}}, {"area": "정보윤리", "topic": "SNS", "level": 1, "type": "mc", "body": {"q": "친구 얼굴이 나온 사진을 SNS에 올리기 전에 해야 할 일은?", "options": ["친구에게 허락을 받는다", "필터를 씌운다", "해시태그를 단다", "밤에 올린다"], "answer": 0, "hint": "사진 속 주인공에게 먼저 물어봐요.", "why": "다른 사람의 얼굴은 그 사람의 개인정보예요. 먼저 허락을 받아요."}}, {"area": "정보윤리", "topic": "AI 이미지", "level": 3, "type": "ox", "body": {"q": "AI로 만든 사진이어도 진짜처럼 잘 나왔다면, 합성이라고 밝히지 않고 올려도 된다.", "answer": "X", "hint": "사람들이 진짜라고 믿어 버리면 어떻게 될까요?", "why": "사람들이 진짜로 믿으면 가짜 뉴스가 될 수 있어요. AI로 만든 것은 AI로 만들었다고 밝혀요."}}, {"area": "정보윤리", "topic": "사이버 위협", "level": 2, "type": "match", "body": {"q": "사이버 위협과 설명을 짝지어요.", "pairs": [["피싱", "가짜 사이트로 비밀번호를 훔치는 것"], ["딥페이크", "AI로 얼굴·목소리를 합성하는 것"], ["스미싱", "문자 메시지 링크로 하는 사기"], ["악성코드", "몰래 설치되어 정보를 빼가는 프로그램"]], "hint": "스미싱 = 문자(SMS) + 피싱", "why": "이름을 알면 수법이 보여요. 모르는 링크는 누르지 않는 게 가장 좋은 방어예요."}}, {"area": "정보윤리", "topic": "스미싱", "level": 3, "type": "bug", "body": {"q": "택배 문자가 왔어요. 가장 의심스러운 줄을 눌러요.", "plain": true, "lines": ["[택배] 고객님의 택배가 주소 불일치로 보관 중입니다.", "확인 후 재배송을 신청해 주세요.", "▶ http://cj-deIivery.kr/re", "고객센터 운영시간 09:00~18:00"], "answer": 2, "hint": "누르라고 하는 링크가 있나요? 주소를 한 글자씩 보세요.", "why": "delivery의 l(엘) 자리에 대문자 I(아이)를 넣은 가짜 주소예요. 택배는 공식 앱에서 직접 조회해요."}}, {"area": "정보윤리", "topic": "계정 보안", "level": 1, "type": "ox", "body": {"q": "학교 공용 컴퓨터에서 로그인했다면 다 쓰고 꼭 로그아웃해야 한다.", "answer": "O", "hint": "다음 사람이 그 컴퓨터를 쓰면?", "why": "로그아웃하지 않으면 다음 사람이 내 계정을 그대로 쓸 수 있어요."}}, {"area": "정보윤리", "topic": "계정 보안", "level": 2, "type": "mc", "body": {"q": "2단계 인증을 켜면 좋은 점은?", "options": ["비밀번호가 털려도 한 번 더 막아 준다", "비밀번호를 안 만들어도 된다", "인터넷이 빨라진다", "게임 아이템을 준다"], "answer": 0, "hint": "비밀번호 + 내 휴대폰 확인 = 문이 2개", "why": "비밀번호 말고도 내 휴대폰 인증이 한 번 더 필요해서, 비밀번호만으로는 로그인할 수 없어요."}}, {"area": "정보윤리", "topic": "AI 활용", "level": 2, "type": "mc", "body": {"q": "AI로 숙제를 도움받을 때 가장 바람직한 방법은?", "options": ["AI 설명을 참고해 이해한 뒤 내 말로 쓴다", "AI 답을 그대로 복사해 낸다", "친구 숙제를 AI로 바꿔 써서 낸다", "AI는 틀릴 리 없으니 확인하지 않는다"], "answer": 0, "hint": "AI는 \"선생님\"처럼 돕는 도구예요. 숙제는 누가 하나요?", "why": "AI는 공부를 돕는 도구예요. 이해하고 내 말로 쓰고, 틀린 부분이 없는지 확인해요."}}, {"area": "정보윤리", "topic": "비밀번호", "level": 1, "type": "input", "body": {"q": "계정을 지키려면 사이트마다 서로 다른 ○○○○를 써야 한다. ○○○○에 들어갈 말은?", "answer": ["비밀번호", "패스워드", "password"], "placeholder": "네 글자", "hint": "로그인할 때 아이디와 함께 넣는 것", "why": "한 곳의 비밀번호가 새도 다른 계정은 안전하게 지킬 수 있어요."}}, {"area": "정보윤리", "topic": "딥페이크", "level": 3, "type": "multi", "body": {"q": "딥페이크 영상을 의심해 볼 신호를 모두 골라요.", "options": ["눈 깜빡임이 부자연스럽다", "입 모양과 목소리가 안 맞는다", "얼굴 테두리가 흐릿하게 번진다", "조회수가 아주 많다"], "answers": [0, 1, 2], "hint": "정답은 3개! 조회수는 진짜·가짜와 상관있을까요?", "why": "조회수는 진짜인지와 상관없어요. 눈, 입, 얼굴 테두리처럼 합성 티가 나는 곳을 봐요."}}, {"area": "정보윤리", "topic": "AI 이미지", "level": 1, "type": "imgox", "body": {"img": "img/turtle.png", "q": "이 그림은 사람이 그린 게 아니라 AI가 만든 그림이다.", "answer": "O", "hint": "휴대폰 속 QR 코드를 자세히 보세요. 찍으면 열릴까요?", "why": "선생님이 AI(Gemini·GPT)로 만든 그림이에요. 휴대폰 속 QR 코드는 카메라로 찍어도 열리지 않는 가짜 무늬예요."}}, {"area": "정보윤리", "topic": "AI 이미지", "level": 1, "type": "imgox", "body": {"img": "img/mascot_ai.png", "q": "이 그림 속 모자 로고의 영어 글자는 철자가 모두 정확하다.", "answer": "X", "hint": "School 과 since 의 철자를 떠올리며 모자를 자세히 보세요.", "why": "School이 Sabool처럼, since가 aince처럼 이상하게 쓰였어요. AI가 만든 그림은 글자를 자주 틀려요."}}, {"area": "정보윤리", "topic": "AI 이미지", "level": 2, "type": "imgspot", "body": {"img": "img/mascot_ai.png", "spot": [41, 1, 17, 14], "spotLabel": "모자 로고의 영어 글자 (Sabool, aince)", "q": "우리 학교 거북이도 AI가 그렸어요. AI가 만든 티가 가장 많이 나는 곳을 눌러요.", "hint": "그림 속 영어 글자를 한 글자씩 읽어 보세요.", "why": "모자 로고에 School이 Sabool, since가 aince처럼 쓰였어요. AI는 그림 속 글자를 흉내만 낼 때가 많아요. 휴대폰 화면 글자도 살짝 뭉개져 있어요."}}, {"area": "정보윤리", "topic": "AI 이미지", "level": 2, "type": "imgspot", "body": {"img": "img/turtle.png", "spot": [33, 49, 34, 35], "spotLabel": "휴대폰 화면 속 QR 코드", "q": "AI가 만든 그림이에요. AI가 만든 티가 나는 곳을 눌러요.", "hint": "카메라로 찍으면 열려야 하는 것이 있어요.", "why": "QR 코드는 진짜처럼 보이지만 찍어도 열리지 않아요. AI는 QR·글자·손가락처럼 정확해야 하는 모양을 흉내만 낼 때가 많아요."}}]$seed$::jsonb) with ordinality as t(e, n)
where not exists (select 1 from quiz_questions)
order by n;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 7) 관리자 비밀번호는 이 파일에 적지 않아요 (깃허브에 올라가도 안전하게).
--    이 파일을 실행한 뒤, New query 에서 아래 한 줄만 따로 실행하세요.
--
--      select quiz__set_password('내가-정한-비밀번호');
--
-- ---------------------------------------------------------------------
