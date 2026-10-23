-- SMASH INU 랭킹 서버 (Supabase)
-- Supabase 대시보드 > SQL Editor에 통째로 붙여 넣고 한 번 실행하세요. 다시 실행해도 기록은 지워지지 않아요.
-- 브라우저는 공개 키(anon/publishable)로 아래 두 함수만 부를 수 있고, 표를 직접 읽거나 쓸 수는 없어요.

create table if not exists public.inu_runs (
  id         bigint generated always as identity primary key,
  day        date        not null,
  score      integer     not null check (score between 0 and 500000),
  nick       text        check (nick is null or char_length(nick) between 1 and 10),
  college    text,
  created_at timestamptz not null default now()
);
create index if not exists inu_runs_day_score on public.inu_runs (day, score desc);

-- 같은 IP에서 너무 자주 올리는 것을 막는 기록 (IP는 날짜와 섞은 해시로만, 2분 뒤 지움)
create table if not exists public.inu_hits (
  h  text        not null,
  at timestamptz not null default now()
);

alter table public.inu_runs enable row level security;
alter table public.inu_hits enable row level security;
-- 정책을 만들지 않으므로 anon 키로는 두 표를 직접 읽거나 쓸 수 없음

create or replace function public.inu_submit(p_score integer, p_nick text, p_college text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day  date := (now() at time zone 'Asia/Seoul')::date;
  v_ip   text := coalesce(split_part((current_setting('request.headers', true)::json ->> 'x-forwarded-for'), ',', 1), '?');
  v_h    text := md5(v_ip || v_day::text);
  v_rank integer;
begin
  if p_score is null or p_score < 0 or p_score > 500000 then
    raise exception 'bad score';
  end if;

  delete from inu_hits where at < now() - interval '2 minutes';
  if (select count(*) from inu_hits where h = v_h and at > now() - interval '1 minute') >= 3 then
    raise exception 'too many';
  end if;
  insert into inu_hits (h) values (v_h);

  p_nick := nullif(left(btrim(regexp_replace(coalesce(p_nick, ''), '[[:cntrl:]<>]', '', 'g')), 10), '');
  if p_college is null or p_college not in ('HUM','NAT','SOC','GPE','ENG','IT','BIZ','ART','EDU','URB','BIO','NAS','ETC') then
    raise exception 'college required';
  end if;

  insert into inu_runs (day, score, nick, college) values (v_day, p_score, p_nick, p_college);
  select count(*) + 1 into v_rank from inu_runs where day = v_day and score > p_score;
  return v_rank;
end;
$$;

create or replace function public.inu_board()
returns json
language sql
stable
security definer
set search_path = public
as $$
  with today as (select * from inu_runs where day = (now() at time zone 'Asia/Seoul')::date)
  select json_build_object(
    'top', coalesce((select json_agg(t) from (
        select nick, college, score from today order by score desc, created_at limit 10) t), '[]'::json),
    'colleges', coalesce((select json_agg(c) from (
        select college, sum(score)::bigint as total, count(*) as runs
        from today where college is not null group by college order by total desc) c), '[]'::json),
    'runs', (select count(*) from today)
  );
$$;

revoke all on function public.inu_submit(integer, text, text) from public;
revoke all on function public.inu_board() from public;
grant execute on function public.inu_submit(integer, text, text) to anon, authenticated;
grant execute on function public.inu_board() to anon, authenticated;
