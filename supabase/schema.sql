-- SMASH INU 랭킹 서버 (Supabase) — 누적 단과대 대항
-- Supabase 대시보드 > SQL Editor에 통째로 붙여 넣고 한 번 실행하세요. 다시 실행해도 기록은 지워지지 않아요.
-- 브라우저는 공개 키(anon/publishable)로 아래 두 함수만 부를 수 있고, 표를 직접 읽거나 쓸 수는 없어요.
--   inu_add(기기, 점수, 닉네임, 단과대) : 30초마다 그동안 번 점수를 더함. 결과로 오늘 순위표를 돌려줌
--   inu_board(기기)                     : 오늘 단과대 순위표(최대 13줄)와 내 오늘 누적 점수
--   inu_people, inu_college_top, inu_set_nick : 개인 랭킹, 기여 TOP 5, 닉네임 바꾸기 (맨 아래 '이번 업데이트용 SQL')
-- ※ inu_add, inu_board는 맨 아래 업데이트 구역에서 새 버전으로 다시 정의돼요. 파일 전체를 실행하면 마지막 정의가 적용됩니다.

-- 점수: 하루 × 기기 한 줄 (중간에 단과대를 바꾸면 그 단과대로 한 줄 더 생김)
create table if not exists public.inu_scores (
  day        date        not null,
  device     uuid        not null,
  college    text        not null,
  nick       text        check (nick is null or char_length(nick) between 1 and 10),
  points     bigint      not null default 0,
  sends      integer     not null default 0,
  updated_at timestamptz not null default now(),
  primary key (day, device, college)
);
create index if not exists inu_scores_day_device on public.inu_scores (day, device);

-- 오늘 × 단과대 합계. 점수가 들어올 때 바로 더해서, 조회할 때 전체 기록을 합산하지 않음
create table if not exists public.inu_college_day (
  day     date    not null,
  college text    not null,
  total   bigint  not null default 0,
  people  integer not null default 0,   -- 그날 이 단과대로 점수를 올린 기기 수
  primary key (day, college)
);

-- 요청 빈도 제한: 1분 칸마다 횟수만 셈 (k = 'd:기기' 또는 'i:IP해시', 2분 넘은 칸은 지움)
create table if not exists public.inu_limits (
  k   text        not null,
  win timestamptz not null,
  n   integer     not null default 0,
  primary key (k, win)
);

alter table public.inu_scores      enable row level security;
alter table public.inu_college_day enable row level security;
alter table public.inu_limits      enable row level security;
-- 정책을 만들지 않으므로 anon 키로는 표를 직접 읽거나 쓸 수 없음 (권한도 한 번 더 뺌)
revoke all on table public.inu_scores, public.inu_college_day, public.inu_limits from anon, authenticated;

-- 예전 60초 도전용 함수는 지움. 예전 표(inu_runs, inu_hits)는 기록 보존을 위해 남겨 둠 (더는 쓰지 않음)
drop function if exists public.inu_submit(integer, text, text);
drop function if exists public.inu_board();

create or replace function public.inu_board(p_device uuid default null)
returns json
language sql
stable
security definer
set search_path = public
as $$
  with d as (select (now() at time zone 'Asia/Seoul')::date as day)
  select json_build_object(
    'day', (select day from d),
    'colleges', coalesce((select json_agg(c) from (
        select college, total, people from inu_college_day
        where day = (select day from d) order by total desc, college) c), '[]'::json),
    'mine', coalesce((select sum(points) from inu_scores
        where day = (select day from d) and device = p_device), 0)
  );
$$;

create or replace function public.inu_add(p_device uuid, p_points integer, p_nick text, p_college text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  -- ※ 임시 상한: 30초 동안 낼 수 있는 최대치를 실제로 재 본 뒤 다시 정할 것 (index.html의 SEND_MAX도 같이)
  c_max_points constant integer := 300000;
  c_dev_per_min constant integer := 6;     -- 기기당 1분 요청 수 (정상: 30초 주기 2번 + 탭 전환 몇 번)
  c_ip_per_min  constant integer := 600;   -- 같은 공인 IP 1분 요청 수 (학교 와이파이, 통신사 공유 IP 고려해 아주 느슨하게)
  v_day date := (now() at time zone 'Asia/Seoul')::date;
  v_win timestamptz := date_trunc('minute', now());
  v_ip  text := nullif(btrim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)), '');
  v_n   integer;
  v_new boolean;
begin
  if p_device is null then raise exception 'device required'; end if;
  if p_points is null or p_points < 1 or p_points > c_max_points then raise exception 'bad points'; end if;
  if p_college is null or p_college not in ('HUM','NAT','SOC','GPE','ENG','IT','BIZ','ART','EDU','URB','BIO','NAS','ETC') then
    raise exception 'college required';
  end if;

  -- 주된 방어: 기기 id 기준 빈도 제한 (막히면 트랜잭션이 취소돼 횟수도 더 늘지 않음)
  insert into inu_limits (k, win, n) values ('d:' || p_device, v_win, 1)
    on conflict (k, win) do update set n = inu_limits.n + 1
    returning n into v_n;
  if v_n > c_dev_per_min then raise exception 'too many'; end if;

  -- 보조 방어: 같은 IP (IP는 날짜와 섞은 해시로만 저장)
  if v_ip is not null then
    insert into inu_limits (k, win, n) values ('i:' || md5(v_ip || v_day::text), v_win, 1)
      on conflict (k, win) do update set n = inu_limits.n + 1
      returning n into v_n;
    if v_n > c_ip_per_min then raise exception 'too many'; end if;
  end if;
  if random() < 0.05 then delete from inu_limits where win < v_win - interval '2 minutes'; end if;

  p_nick := nullif(left(btrim(regexp_replace(coalesce(p_nick, ''), '[[:cntrl:]<>]', '', 'g')), 10), '');

  insert into inu_scores (day, device, college, nick, points, sends)
    values (v_day, p_device, p_college, p_nick, p_points, 1)
    on conflict (day, device, college) do update
      set points = inu_scores.points + excluded.points, nick = excluded.nick,
          sends = inu_scores.sends + 1, updated_at = now()
    returning (xmax = 0) into v_new;            -- 오늘 이 단과대로 처음 올린 기기면 true

  insert into inu_college_day (day, college, total, people)
    values (v_day, p_college, p_points, 1)
    on conflict (day, college) do update
      set total = inu_college_day.total + excluded.total,
          people = inu_college_day.people + (case when v_new then 1 else 0 end);

  return inu_board(p_device);
end;
$$;

revoke all on function public.inu_board(uuid) from public;
revoke all on function public.inu_add(uuid, integer, text, text) from public;
grant execute on function public.inu_board(uuid) to anon, authenticated;
grant execute on function public.inu_add(uuid, integer, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- [관리용] 브라우저에서는 부를 수 없고, SQL Editor에서 직접 실행하세요. (필요할 때 주석을 풀어서)
--
-- 1) 오늘 점수가 이상하게 많은 기기 찾기
-- select device, college, nick, points, sends, updated_at
--   from public.inu_scores where day = (now() at time zone 'Asia/Seoul')::date
--   order by points desc limit 20;
--
-- 2) 특정 기기의 오늘 점수를 지우고 단과대 합계를 다시 계산
--    ('기기-id'를 위에서 찾은 device 값으로 바꾸기. 계산하는 동안 새 점수가 끼어들지 않게 표를 잠금)
-- begin;
-- lock table public.inu_college_day in exclusive mode;
-- delete from public.inu_scores
--   where day = (now() at time zone 'Asia/Seoul')::date and device = '기기-id';
-- delete from public.inu_college_day where day = (now() at time zone 'Asia/Seoul')::date;
-- insert into public.inu_college_day (day, college, total, people)
--   select day, college, sum(points), count(*) from public.inu_scores
--   where day = (now() at time zone 'Asia/Seoul')::date group by day, college;
-- commit;
--
-- 3) 예전 60초 도전 기록 표가 더는 필요 없으면
-- drop table if exists public.inu_runs, public.inu_hits;
--
-- 4) 개인 랭킹과 단과대 기여 TOP 5에서 숨기기 (점수는 단과대 합계에 그대로 남음. 아래 업데이트 SQL을 실행한 뒤에 쓸 수 있음)
-- insert into public.inu_hidden (device, note) values ('기기-id', '이유');
-- insert into public.inu_hidden (nick, note) values ('닉네임', '이유');     -- 대소문자 무시, 그 닉네임을 쓰는 모든 기기
-- 숨김 풀기: delete from public.inu_hidden where device = '기기-id';
--            delete from public.inu_hidden where lower(nick) = lower('닉네임');
-- 닉네임으로 기기 찾기:
-- select device, college, nick, points from public.inu_scores
--   where day = (now() at time zone 'Asia/Seoul')::date and nick ilike '%닉네임%';

-- ===========================================================================
-- 이번 업데이트용 SQL (2026-10-24: 개인 랭킹, 단과대 기여 TOP 5, 닉네임 관리, 시간 기준 점수 상한)
-- 이 구역만 따로 실행해도 되고, 파일 전체를 다시 실행해도 기록은 지워지지 않아요.
-- 기존 함수 inu_add, inu_board는 이름, 인자, 반환 형태를 그대로 두고 안쪽만 바꿈 (옛 코드도 계속 동작)
--   inu_board : 응답에 mine_college(단과대별 내 오늘 점수) 키 추가
--   inu_add   : 응답에 accepted(이번에 받은 점수) 키 추가, 점수 상한을 '시간 기준'으로
-- 새 함수: inu_people(기기), inu_college_top(단과대, 기기), inu_set_nick(기기, 닉네임)
-- ===========================================================================

-- 개인 랭킹, 기여 TOP 5에서 숨길 기기나 닉네임 (관리용 4번 참고)
create table if not exists public.inu_hidden (
  id         bigint generated always as identity primary key,
  device     uuid,
  nick       text,
  note       text,
  created_at timestamptz not null default now(),
  check (device is not null or nick is not null)
);
-- 시간 기준 점수 상한: 기기마다 '받을 수 있는 점수 통'
create table if not exists public.inu_bucket (
  device uuid primary key,
  tokens double precision not null,
  at     timestamptz not null default now()
);
alter table public.inu_hidden enable row level security;
alter table public.inu_bucket enable row level security;
revoke all on table public.inu_hidden, public.inu_bucket from anon, authenticated;

-- 단과대 기여 TOP 5용 (개인 TOP 20은 오늘 줄들을 기존 (day, device) 인덱스로 읽어 합산)
create index if not exists inu_scores_day_college_points on public.inu_scores (day, college, points desc);

-- 닉네임 욕설 검사: 띄어쓰기, 숫자, 특수문자를 빼고 비교. index.html의 BAD_WORDS와 같은 목록을 유지할 것
create or replace function public.inu_nick_bad(p text)
returns boolean
language sql
immutable
as $$
  select p is not null and exists (
    select 1 from unnest(array[
      '시발','씨발','씨바','씨빨','시빨','ㅅㅂ','ㅆㅂ','ㅅㅍ','씹','병신','븅신','빙신','ㅂㅅ','ㅄ',
      '개새','개색','개섀','새끼','ㅅㄲ','좆','존나','졸라','ㅈㄴ','지랄','ㅈㄹ','염병','엠창','애미','애비',
      '느금','니미','섹스','보지','자지','창녀','걸레','꺼져','닥쳐','등신','미친','ㅁㅊ','또라이','틀딱',
      '한남충','김치녀','된장녀','일베','메갈','운지','찐따',
      'fuck','fuk','fck','shit','bitch','asshole','dick','cunt','nigger','nigga','faggot','pussy','porn',
      'sex','slut','whore','bastard','retard','penis','vagina'
    ]) w
    where regexp_replace(lower(p), '[^a-z가-힣ㄱ-ㅎㅏ-ㅣ]', '', 'g') like '%' || w || '%'
  );
$$;
revoke all on function public.inu_nick_bad(text) from public, anon, authenticated;

-- 화면에 보여도 되는 닉네임이면 그대로, 아니면 null (욕설, 숨김 목록)
create or replace function public.inu_shown_nick(p_device uuid, p_nick text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when p_nick is null or inu_nick_bad(p_nick)
    or exists (select 1 from inu_hidden h where h.device = p_device or lower(h.nick) = lower(p_nick))
    then null else p_nick end;
$$;
revoke all on function public.inu_shown_nick(uuid, text) from public, anon, authenticated;

create or replace function public.inu_board(p_device uuid default null)
returns json
language sql
stable
security definer
set search_path = public
as $$
  with d as (select (now() at time zone 'Asia/Seoul')::date as day)
  select json_build_object(
    'day', (select day from d),
    'colleges', coalesce((select json_agg(c) from (
        select college, total, people from inu_college_day
        where day = (select day from d) order by total desc, college) c), '[]'::json),
    'mine', coalesce((select sum(points) from inu_scores
        where day = (select day from d) and device = p_device), 0),
    'mine_college', coalesce((select json_object_agg(college, points) from inu_scores
        where day = (select day from d) and device = p_device), '{}'::json)
  );
$$;

create or replace function public.inu_add(p_device uuid, p_points integer, p_nick text, p_college text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  c_hard_max    constant integer := 2000000;   -- 한 번 요청에 이보다 크면 이상한 요청으로 보고 거절
  -- ※ 임시값: 시간 기준 상한. 통은 초당 c_rate씩 차고 최대 c_burst까지 쌓임. 넘는 몫은 받지 않고 accepted로 알려 줌
  c_rate        constant double precision := 20000;
  c_burst       constant double precision := 600000;
  c_dev_per_min constant integer := 6;
  c_ip_per_min  constant integer := 600;
  v_day date := (now() at time zone 'Asia/Seoul')::date;
  v_win timestamptz := date_trunc('minute', now());
  v_ip  text := nullif(btrim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)), '');
  v_n   integer;
  v_new boolean;
  v_tok double precision;
  v_acc integer;
begin
  if p_device is null then raise exception 'device required'; end if;
  if p_points is null or p_points < 1 or p_points > c_hard_max then raise exception 'bad points'; end if;
  if p_college is null or p_college not in ('HUM','NAT','SOC','GPE','ENG','IT','BIZ','ART','EDU','URB','BIO','NAS','ETC') then
    raise exception 'college required';
  end if;

  insert into inu_limits (k, win, n) values ('d:' || p_device, v_win, 1)
    on conflict (k, win) do update set n = inu_limits.n + 1
    returning n into v_n;
  if v_n > c_dev_per_min then raise exception 'too many'; end if;
  if v_ip is not null then
    insert into inu_limits (k, win, n) values ('i:' || md5(v_ip || v_day::text), v_win, 1)
      on conflict (k, win) do update set n = inu_limits.n + 1
      returning n into v_n;
    if v_n > c_ip_per_min then raise exception 'too many'; end if;
  end if;
  if random() < 0.05 then delete from inu_limits where win < v_win - interval '2 minutes'; end if;

  -- 시간 기준 상한: 몇 초 간격으로 보내든 받을 수 있는 양은 흐른 시간에 비례
  insert into inu_bucket (device, tokens, at) values (p_device, c_burst, now())
    on conflict (device) do update
      set tokens = least(c_burst, inu_bucket.tokens + extract(epoch from now() - inu_bucket.at) * c_rate), at = now()
    returning tokens into v_tok;
  v_acc := least(p_points, floor(v_tok))::integer;
  update inu_bucket set tokens = tokens - v_acc where device = p_device;

  p_nick := nullif(left(btrim(regexp_replace(coalesce(p_nick, ''), '[[:cntrl:]<>]', '', 'g')), 10), '');

  if v_acc > 0 then
    insert into inu_scores (day, device, college, nick, points, sends)
      values (v_day, p_device, p_college, p_nick, v_acc, 1)
      on conflict (day, device, college) do update
        set points = inu_scores.points + excluded.points, nick = excluded.nick,
            sends = inu_scores.sends + 1, updated_at = now()
      returning (xmax = 0) into v_new;
    insert into inu_college_day (day, college, total, people)
      values (v_day, p_college, v_acc, 1)
      on conflict (day, college) do update
        set total = inu_college_day.total + excluded.total,
            people = inu_college_day.people + (case when v_new then 1 else 0 end);
  end if;

  return (inu_board(p_device)::jsonb || jsonb_build_object('accepted', v_acc))::json;
end;
$$;

-- 하루 중에 닉네임을 바꾸거나 익명으로 바꾸면 오늘 내 줄에 바로 반영 (욕설이면 거절)
create or replace function public.inu_set_nick(p_device uuid, p_nick text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day  date := (now() at time zone 'Asia/Seoul')::date;
  v_win  timestamptz := date_trunc('minute', now());
  v_nick text := nullif(left(btrim(regexp_replace(coalesce(p_nick, ''), '[[:cntrl:]<>]', '', 'g')), 10), '');
  v_n    integer;
begin
  if p_device is null then raise exception 'device required'; end if;
  if inu_nick_bad(v_nick) then raise exception 'bad nick'; end if;
  insert into inu_limits (k, win, n) values ('d:' || p_device, v_win, 1)
    on conflict (k, win) do update set n = inu_limits.n + 1
    returning n into v_n;
  if v_n > 6 then raise exception 'too many'; end if;
  update inu_scores set nick = v_nick where day = v_day and device = p_device;
  return json_build_object('nick', v_nick);
end;
$$;

-- 오늘 개인 랭킹: 닉네임 참가 기기만 TOP 20 + 내 순위. 기기 id는 내보내지 않고 내 줄은 mine으로만 표시
create or replace function public.inu_people(p_device uuid default null)
returns json
language sql
stable
security definer
set search_path = public
as $$
  with per as (
    select device, sum(points) as points,
      (array_agg(nick order by updated_at desc))[1] as nick,
      (array_agg(college order by updated_at desc))[1] as college
    from inu_scores where day = (now() at time zone 'Asia/Seoul')::date
    group by device
  ), vis as (
    select device, points, college, inu_shown_nick(device, nick) as nick from per
  ), ranked as (
    select *, rank() over (order by points desc) as rk from vis where nick is not null
  )
  select json_build_object(
    'top', coalesce((select json_agg(json_build_object('rank', rk, 'nick', nick, 'college', college, 'points', points, 'mine', coalesce(device = p_device, false)) order by rk, nick)
        from (select * from ranked order by rk, nick limit 20) t), '[]'::json),
    'me', (select json_build_object('rank', rk, 'points', points) from ranked where device = p_device),
    'count', (select count(*) from ranked)
  );
$$;

-- 단과대 기여 TOP 5: 닉네임 참가자는 닉네임, 익명은 null(화면에서 '익명'). 숨김 기기와 숨김 닉네임은 뺌
create or replace function public.inu_college_top(p_college text, p_device uuid default null)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_college is null or p_college not in ('HUM','NAT','SOC','GPE','ENG','IT','BIZ','ART','EDU','URB','BIO','NAS','ETC') then
    raise exception 'college required';
  end if;
  return coalesce((select json_agg(json_build_object('nick', case when inu_nick_bad(nick) then null else nick end, 'points', points, 'mine', coalesce(device = p_device, false)) order by points desc)
    from (select device, nick, points from inu_scores s
          where day = (now() at time zone 'Asia/Seoul')::date and college = p_college
            and not exists (select 1 from inu_hidden h where h.device = s.device or lower(h.nick) = lower(s.nick))
          order by points desc limit 5) t), '[]'::json);
end;
$$;

revoke all on function public.inu_set_nick(uuid, text) from public;
revoke all on function public.inu_people(uuid) from public;
revoke all on function public.inu_college_top(text, uuid) from public;
grant execute on function public.inu_set_nick(uuid, text) to anon, authenticated;
grant execute on function public.inu_people(uuid) to anon, authenticated;
grant execute on function public.inu_college_top(text, uuid) to anon, authenticated;
