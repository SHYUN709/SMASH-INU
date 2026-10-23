-- SMASH INU 랭킹 서버 (Supabase) — 누적 단과대 대항
-- Supabase 대시보드 > SQL Editor에 통째로 붙여 넣고 한 번 실행하세요. 다시 실행해도 기록은 지워지지 않아요.
-- 브라우저는 공개 키(anon/publishable)로 아래 두 함수만 부를 수 있고, 표를 직접 읽거나 쓸 수는 없어요.
--   inu_add(기기, 점수, 닉네임, 단과대) : 30초마다 그동안 번 점수를 더함. 결과로 오늘 순위표를 돌려줌
--   inu_board(기기)                     : 오늘 단과대 순위표(최대 13줄)와 내 오늘 누적 점수

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
