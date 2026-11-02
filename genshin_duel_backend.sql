-- Genshin Duel Draft - backend sécurisé (étape 1)
-- À exécuter dans Supabase > SQL Editor > New query.
-- Les navigateurs ne doivent PAS modifier directement les tables : uniquement via les fonctions RPC.

create table if not exists public.gdd_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  mode text not null check (mode in ('free','referee')),
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  rules jsonb not null default '{"banCount":3,"pickCount":4,"budget":30,"cost5":5,"cost4":2,"limit5":3,"limitElement":2,"enforceBudget":true,"enforceRarity":true,"enforceElement":false,"showCost":true,"firstPlayer":1}'::jsonb,
  state jsonb not null default '{"players":[{"name":"Joueur 1","picks":[],"bans":[]},{"name":"Joueur 2","picks":[],"bans":[]}],"actions":[],"phase":"ban","turn":1,"started":false,"finished":false}'::jsonb,
  revision bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.gdd_members (
  room_id uuid not null references public.gdd_rooms(id) on delete cascade,
  user_id uuid not null,
  role text not null check (role in ('player1','player2','referee','observer')),
  display_name text not null default 'Participant',
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id),
  unique (room_id, role, user_id)
);

create table if not exists public.gdd_action_history (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.gdd_rooms(id) on delete cascade,
  actor_id uuid not null,
  action_type text not null check (action_type in ('ban','pick','skip')),
  player_no integer not null check (player_no in (1,2)),
  character_id text,
  state_before jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists gdd_members_user_idx on public.gdd_members(user_id);
create index if not exists gdd_action_history_room_idx on public.gdd_action_history(room_id, id desc);

alter table public.gdd_rooms enable row level security;
alter table public.gdd_members enable row level security;
alter table public.gdd_action_history enable row level security;

-- Helper utilisé uniquement par la politique SELECT Realtime : un membre ne voit que son salon.
create or replace function public.gdd_is_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists(select 1 from public.gdd_members m where m.room_id=p_room_id and m.user_id=auth.uid());
$$;
revoke all on function public.gdd_is_member(uuid) from public;
grant execute on function public.gdd_is_member(uuid) to authenticated;
create policy gdd_rooms_member_read on public.gdd_rooms for select to authenticated using (public.gdd_is_member(id));

-- Pas d'accès direct aux tables pour les mutations : les fonctions RPC contrôlent chaque action.
revoke all on public.gdd_rooms from anon, authenticated;
revoke all on public.gdd_members from anon, authenticated;
revoke all on public.gdd_action_history from anon, authenticated;
grant select on public.gdd_rooms to authenticated;

create or replace function public.gdd_create_room(p_mode text, p_rules jsonb default null, p_name text default 'Joueur 1')
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare uid uuid := auth.uid(); rid uuid; code_value text; initial_rules jsonb; initial_state jsonb;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 if p_mode not in ('free','referee') then raise exception 'INVALID_MODE'; end if;
 initial_rules := coalesce(p_rules, '{"banCount":3,"pickCount":4,"budget":30,"cost5":5,"cost4":2,"limit5":3,"limitElement":2,"enforceBudget":true,"enforceRarity":true,"enforceElement":false,"showCost":true,"firstPlayer":1}'::jsonb);
 if (initial_rules->>'banCount')::int not between 0 and 10 or (initial_rules->>'pickCount')::int not between 1 and 8 then raise exception 'INVALID_RULES'; end if;
 initial_state := jsonb_build_object('players',jsonb_build_array(jsonb_build_object('name',left(coalesce(nullif(trim(p_name),''),'Joueur 1'),24),'picks','[]'::jsonb,'bans','[]'::jsonb),jsonb_build_object('name','Joueur 2','picks','[]'::jsonb,'bans','[]'::jsonb)),'actions','[]'::jsonb,'phase','ban','turn',coalesce((initial_rules->>'firstPlayer')::int,1),'started',false,'finished',false);
 loop
  code_value := upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  begin
   insert into public.gdd_rooms(code,mode,rules,state) values(code_value,p_mode,initial_rules,initial_state) returning id into rid;
   exit;
  exception when unique_violation then null;
  end;
 end loop;
 insert into public.gdd_members(room_id,user_id,role,display_name) values(rid,uid,case when p_mode='referee' then 'referee' else 'player1' end,left(coalesce(nullif(trim(p_name),''),'Joueur 1'),24));
 return jsonb_build_object('room_id',rid,'code',code_value,'role',case when p_mode='referee' then 'referee' else 'player1' end,'state',initial_state,'rules',initial_rules,'revision',0);
end; $$;

create or replace function public.gdd_join_room(p_code text, p_role text default 'player', p_name text default 'Participant')
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare uid uuid := auth.uid(); r public.gdd_rooms%rowtype; existing_role text; new_role text;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into r from public.gdd_rooms where code=upper(trim(p_code)) for update;
 if not found then raise exception 'ROOM_NOT_FOUND'; end if;
 select role into existing_role from public.gdd_members where room_id=r.id and user_id=uid;
 if existing_role is not null then return jsonb_build_object('room_id',r.id,'code',r.code,'role',existing_role,'state',r.state,'rules',r.rules,'revision',r.revision); end if;
 if p_role='observer' then new_role:='observer';
 elsif r.mode='referee' then
   if not exists(select 1 from public.gdd_members where room_id=r.id and role='player1') then new_role:='player1';
   elsif not exists(select 1 from public.gdd_members where room_id=r.id and role='player2') then new_role:='player2';
   else raise exception 'ROOM_FULL'; end if;
 else
   if not exists(select 1 from public.gdd_members where room_id=r.id and role='player2') then new_role:='player2';
   else raise exception 'ROOM_FULL'; end if;
 end if;
 insert into public.gdd_members(room_id,user_id,role,display_name) values(r.id,uid,new_role,left(coalesce(nullif(trim(p_name),''),'Participant'),24));
 return jsonb_build_object('room_id',r.id,'code',r.code,'role',new_role,'state',r.state,'rules',r.rules,'revision',r.revision);
end; $$;

create or replace function public.gdd_get_room(p_code text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r public.gdd_rooms%rowtype; member_role text;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into r from public.gdd_rooms where code=upper(trim(p_code));
 if not found then raise exception 'ROOM_NOT_FOUND'; end if;
 select role into member_role from public.gdd_members where room_id=r.id and user_id=uid;
 if member_role is null then raise exception 'NOT_A_MEMBER'; end if;
 return jsonb_build_object('room_id',r.id,'code',r.code,'mode',r.mode,'role',member_role,'state',r.state,'rules',r.rules,'revision',r.revision);
end; $$;

create or replace function public.gdd_update_rules(p_code text, p_rules jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r public.gdd_rooms%rowtype; member_role text;
begin
 select * into r from public.gdd_rooms where code=upper(trim(p_code)) for update;
 if not found then raise exception 'ROOM_NOT_FOUND'; end if;
 select role into member_role from public.gdd_members where room_id=r.id and user_id=uid;
 if member_role is null then raise exception 'NOT_A_MEMBER'; end if;
 if (r.mode='referee' and member_role<>'referee') or (r.mode='free' and member_role<>'player1') then raise exception 'NOT_AUTHORIZED'; end if;
 if coalesce((r.state->>'started')::boolean,false) then raise exception 'DRAFT_ALREADY_STARTED'; end if;
 if (p_rules->>'banCount')::int not between 0 and 10 or (p_rules->>'pickCount')::int not between 1 and 8 then raise exception 'INVALID_RULES'; end if;
 update public.gdd_rooms set rules=p_rules, state=jsonb_set(state,'{turn}',to_jsonb(coalesce((p_rules->>'firstPlayer')::int,1))), revision=revision+1,updated_at=now() where id=r.id returning * into r;
 return jsonb_build_object('state',r.state,'rules',r.rules,'revision',r.revision);
end; $$;

create or replace function public.gdd_act(p_code text, p_action text, p_character jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r public.gdd_rooms%rowtype; member_role text; player_no int; s jsonb; rr jsonb; players jsonb; player_data jsonb; other_data jsonb; acts jsonb; char_id text; phase_value text; cost_value numeric; total_cost numeric; rarity_count int; elem_count int; taken boolean;
begin
 select * into r from public.gdd_rooms where code=upper(trim(p_code)) for update;
 if not found then raise exception 'ROOM_NOT_FOUND'; end if;
 select role into member_role from public.gdd_members where room_id=r.id and user_id=uid;
 if member_role is null then raise exception 'NOT_A_MEMBER'; end if;
 s:=r.state; rr:=r.rules; players:=s->'players'; phase_value:=s->>'phase';
 if coalesce((s->>'finished')::boolean,false) then raise exception 'DRAFT_FINISHED'; end if;
 if p_action='skip' then
   if member_role='referee' or member_role='observer' then raise exception 'NOT_AUTHORIZED'; end if;
   player_no:=case when member_role='player1' then 1 when member_role='player2' then 2 else 0 end;
   if player_no<>(s->>'turn')::int then raise exception 'NOT_YOUR_TURN'; end if;
 else
   if p_action not in ('ban','pick') then raise exception 'INVALID_ACTION'; end if;
   if p_action<>phase_value then raise exception 'WRONG_PHASE'; end if;
   player_no:=case when member_role='player1' then 1 when member_role='player2' then 2 else 0 end;
   if player_no=0 or player_no<>(s->>'turn')::int then raise exception 'NOT_YOUR_TURN'; end if;
   if p_character is null or coalesce(p_character->>'id','')='' or coalesce(p_character->>'name','')='' then raise exception 'INVALID_CHARACTER'; end if;
   char_id:=p_character->>'id';
   taken:=exists(select 1 from jsonb_array_elements(players) pl cross join lateral jsonb_array_elements(coalesce(pl->'picks','[]'::jsonb)||coalesce(pl->'bans','[]'::jsonb)) c where c->>'id'=char_id);
   if taken then raise exception 'CHARACTER_ALREADY_TAKEN'; end if;
 end if;
 player_data:=players->(player_no-1); other_data:=players->(2-player_no);
 if p_action='ban' and jsonb_array_length(player_data->'bans') >= (rr->>'banCount')::int then raise exception 'BAN_LIMIT'; end if;
 if p_action='pick' then
   if jsonb_array_length(player_data->'picks') >= (rr->>'pickCount')::int then raise exception 'PICK_LIMIT'; end if;
   cost_value:=case when (p_character->>'rarity')::int=5 then (rr->>'cost5')::numeric else (rr->>'cost4')::numeric end;
   select coalesce(sum(case when (c->>'rarity')::int=5 then (rr->>'cost5')::numeric else (rr->>'cost4')::numeric end),0),count(*) filter(where (c->>'rarity')::int=5),count(*) filter(where c->>'element'=p_character->>'element') into total_cost,rarity_count,elem_count from jsonb_array_elements(player_data->'picks') c;
   if coalesce((rr->>'enforceBudget')::boolean,false) and total_cost+cost_value>(rr->>'budget')::numeric then raise exception 'BUDGET_EXCEEDED'; end if;
   if coalesce((rr->>'enforceRarity')::boolean,false) and (p_character->>'rarity')::int=5 and rarity_count >= (rr->>'limit5')::int then raise exception 'RARITY_LIMIT'; end if;
   if coalesce((rr->>'enforceElement')::boolean,false) and (rr->>'limitElement')::int>0 and elem_count >= (rr->>'limitElement')::int then raise exception 'ELEMENT_LIMIT'; end if;
 end if;
 insert into public.gdd_action_history(room_id,actor_id,action_type,player_no,character_id,state_before) values(r.id,uid,p_action,player_no,coalesce(p_character->>'id',''),s);
 if p_action='ban' then player_data:=jsonb_set(player_data,'{bans}',(player_data->'bans')||jsonb_build_array(p_character));
 elsif p_action='pick' then player_data:=jsonb_set(player_data,'{picks}',(player_data->'picks')||jsonb_build_array(p_character));
 end if;
 players:=jsonb_set(players,array[(player_no-1)::text],player_data);
 s:=jsonb_set(s,'{players}',players); acts:=coalesce(s->'actions','[]'::jsonb)||jsonb_build_array(jsonb_build_object('player',player_no,'type',p_action,'char',coalesce(p_character,jsonb_build_object('name','Tour passé')))); s:=jsonb_set(s,'{actions}',acts); s:=jsonb_set(s,'{started}','true'::jsonb);
 if p_action='skip' then s:=jsonb_set(s,'{turn}',to_jsonb(3-player_no));
 else
   if phase_value='ban' and jsonb_array_length((players->0)->'bans')+jsonb_array_length((players->1)->'bans') >= 2*(rr->>'banCount')::int then s:=jsonb_set(s,'{phase}','"pick"'::jsonb); s:=jsonb_set(s,'{turn}',to_jsonb(coalesce((rr->>'firstPlayer')::int,1)));
   else s:=jsonb_set(s,'{turn}',to_jsonb(3-player_no)); end if;
   if s->>'phase'='pick' and jsonb_array_length((players->0)->'picks')+jsonb_array_length((players->1)->'picks') >= 2*(rr->>'pickCount')::int then s:=jsonb_set(s,'{finished}','true'::jsonb); end if;
 end if;
 update public.gdd_rooms set state=s,status=case when coalesce((s->>'finished')::boolean,false) then 'finished' else 'playing' end,revision=revision+1,updated_at=now() where id=r.id returning * into r;
 return jsonb_build_object('state',r.state,'rules',r.rules,'revision',r.revision);
end; $$;

create or replace function public.gdd_undo_last(p_code text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r public.gdd_rooms%rowtype; member_role text; last_row public.gdd_action_history%rowtype;
begin
 select * into r from public.gdd_rooms where code=upper(trim(p_code)) for update;
 if not found then raise exception 'ROOM_NOT_FOUND'; end if;
 select role into member_role from public.gdd_members where room_id=r.id and user_id=uid;
 if member_role is null then raise exception 'NOT_A_MEMBER'; end if;
 if r.mode<>'referee' or member_role<>'referee' then raise exception 'REFEREE_ONLY'; end if;
 select * into last_row from public.gdd_action_history where room_id=r.id order by id desc limit 1 for update;
 if not found then raise exception 'NO_ACTION_TO_UNDO'; end if;
 update public.gdd_rooms set state=last_row.state_before,status=case when coalesce((last_row.state_before->>'finished')::boolean,false) then 'finished' when coalesce((last_row.state_before->>'started')::boolean,false) then 'playing' else 'waiting' end,revision=revision+1,updated_at=now() where id=r.id returning * into r;
 delete from public.gdd_action_history where id=last_row.id;
 return jsonb_build_object('state',r.state,'rules',r.rules,'revision',r.revision);
end; $$;

revoke all on function public.gdd_create_room(text,jsonb,text) from public;
revoke all on function public.gdd_join_room(text,text,text) from public;
revoke all on function public.gdd_get_room(text) from public;
revoke all on function public.gdd_update_rules(text,jsonb) from public;
revoke all on function public.gdd_act(text,text,jsonb) from public;
revoke all on function public.gdd_undo_last(text) from public;
grant execute on function public.gdd_create_room(text,jsonb,text) to authenticated;
grant execute on function public.gdd_join_room(text,text,text) to authenticated;
grant execute on function public.gdd_get_room(text) to authenticated;
grant execute on function public.gdd_update_rules(text,jsonb) to authenticated;
grant execute on function public.gdd_act(text,text,jsonb) to authenticated;
grant execute on function public.gdd_undo_last(text) to authenticated;

-- Realtime sur les changements de rooms pour que les clients autorisés puissent se rafraîchir.
do $$ begin
 alter publication supabase_realtime add table public.gdd_rooms;
exception when duplicate_object then null; when undefined_object then null; end $$;

comment on table public.gdd_rooms is 'État autoritatif des salons Genshin Duel Draft; mutations via RPC uniquement.';
comment on table public.gdd_members is 'Rôles des utilisateurs authentifiés anonymement dans chaque salon.';
comment on table public.gdd_action_history is 'Historique transactionnel permettant à l’arbitre d’annuler la dernière action.';
