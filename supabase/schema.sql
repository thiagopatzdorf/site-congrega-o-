-- Congregação Nova: escala de testemunho público com carrinhos.
-- Espelho do que está aplicado no projeto Supabase (migrations
-- congregacaonova_escala, _config_contato, _fixos, _fixos_historico,
-- _horario_livre). Rodar inteiro num banco vazio deixa o backend pronto; a
-- inversa está em derrubar.sql.
--
-- Sem login. A "porta" é um código simples guardado em cn_config('senha');
-- toda leitura e escrita passa por função SECURITY DEFINER que confere o
-- código. As tabelas ficam com RLS ligado e sem política: a chave pública
-- (anon) não enxerga nada direto.
--
-- Horário é livre (passos de 15 min no app): cada presença tem início (hora)
-- e fim; "turno" é quem está no mesmo local ao mesmo tempo. Presença fixa
-- (cn_fixos) vale toda semana de `desde` até `ate`; faltar numa semana só é
-- uma linha em cn_faltas.

create table public.cn_config (
  chave text primary key,
  valor jsonb not null,
  atualizado_em timestamptz not null default now()
);

create table public.cn_publicadores (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(trim(nome)) between 2 and 60),
  responsavel boolean not null default false,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

create table public.cn_inscricoes (
  id uuid primary key default gen_random_uuid(),
  semana date not null,
  local text not null,
  dia smallint not null check (dia between 0 and 6),
  hora text not null,
  fim text not null default '',
  publicador_id uuid not null references public.cn_publicadores(id) on delete cascade,
  criado_em timestamptz not null default now(),
  unique (semana, local, dia, hora, publicador_id)
);
create index cn_inscricoes_semana on public.cn_inscricoes (semana);

create table public.cn_cancelamentos (
  semana date not null,
  local text not null,
  dia smallint not null,
  hora text not null,
  fim text not null default '23:59',
  motivo text not null default '',
  criado_em timestamptz not null default now(),
  primary key (semana, local, dia, hora)
);

create table public.cn_fixos (
  id uuid primary key default gen_random_uuid(),
  local text not null,
  dia smallint not null check (dia between 0 and 6),
  hora text not null,
  fim text not null default '',
  publicador_id uuid not null references public.cn_publicadores(id) on delete cascade,
  desde date not null,
  ate date,
  criado_em timestamptz not null default now(),
  constraint cn_fixos_periodo unique (local, dia, hora, publicador_id, desde)
);

create table public.cn_faltas (
  semana date not null,
  local text not null,
  dia smallint not null,
  hora text not null,
  publicador_id uuid not null references public.cn_publicadores(id) on delete cascade,
  primary key (semana, local, dia, hora, publicador_id)
);

alter table public.cn_config enable row level security;
alter table public.cn_publicadores enable row level security;
alter table public.cn_inscricoes enable row level security;
alter table public.cn_cancelamentos enable row level security;
alter table public.cn_fixos enable row level security;
alter table public.cn_faltas enable row level security;
revoke all on public.cn_config, public.cn_publicadores, public.cn_inscricoes, public.cn_cancelamentos, public.cn_fixos, public.cn_faltas from anon, authenticated;

create or replace function public.cn_segunda(d date) returns date
language sql immutable as $$
  select d - (extract(isodow from d)::int - 1);
$$;

create or replace function public.cn_senha_ok(p_senha text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from cn_config where chave = 'senha' and valor #>> '{}' = p_senha);
$$;
revoke execute on function public.cn_senha_ok(text) from public, anon, authenticated;

-- Quem está em cada local numa semana: inscrições avulsas + fixos ativos
-- naquela semana, menos as faltas avisadas (e menos fixo coberto por avulso).
create or replace function public.cn_quem(p_semana date)
returns table (local text, dia smallint, hora text, fim text, publicador_id uuid, fixo boolean, criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select i.local, i.dia, i.hora, i.fim, i.publicador_id, false, i.criado_em
    from cn_inscricoes i join cn_publicadores p on p.id = i.publicador_id and p.ativo
   where i.semana = p_semana
  union
  select f.local, f.dia, f.hora, f.fim, f.publicador_id, true, f.criado_em
    from cn_fixos f join cn_publicadores p on p.id = f.publicador_id and p.ativo
   where f.desde <= p_semana and (f.ate is null or f.ate > p_semana)
     and not exists (select 1 from cn_faltas x where x.semana = p_semana and x.local = f.local and x.dia = f.dia and x.hora = f.hora and x.publicador_id = f.publicador_id)
     and not exists (select 1 from cn_inscricoes i where i.semana = p_semana and i.local = f.local and i.dia = f.dia and i.publicador_id = f.publicador_id and i.hora < f.fim and i.fim > f.hora);
$$;
revoke execute on function public.cn_quem(date) from public, anon, authenticated;

-- Tudo que o app lê, numa chamada.
create or replace function public.cn_estado(p_senha text, p_semana date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_semana date := cn_segunda(coalesce(p_semana, current_date));
  v_mes_ini date := date_trunc('month', v_semana)::date;
  v_mes_fim date := (date_trunc('month', v_semana) + interval '1 month')::date;
begin
  if not cn_senha_ok(p_senha) then
    raise exception 'Código da porta errado' using errcode = '28000';
  end if;
  return jsonb_build_object(
    'semana', v_semana,
    'hoje', current_date,
    'config', (select coalesce(jsonb_object_agg(chave, valor) filter (where chave <> 'senha'), '{}'::jsonb) from cn_config),
    'publicadores', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'responsavel', responsavel) order by nome), '[]'::jsonb) from cn_publicadores where ativo),
    'inscricoes', (select coalesce(jsonb_agg(jsonb_build_object('local', q.local, 'dia', q.dia, 'hora', q.hora, 'fim', q.fim, 'publicador_id', q.publicador_id, 'fixo', q.fixo) order by q.hora, q.criado_em), '[]'::jsonb) from cn_quem(v_semana) q),
    'cancelamentos', (select coalesce(jsonb_agg(jsonb_build_object('local', local, 'dia', dia, 'hora', hora, 'fim', fim, 'motivo', motivo)), '[]'::jsonb) from cn_cancelamentos where semana = v_semana),
    'mes', (select coalesce(jsonb_object_agg(publicador_id, n), '{}'::jsonb) from (
        select q.publicador_id, count(*) as n
          from generate_series(cn_segunda(v_mes_ini), v_mes_fim - 1, interval '7 days') s
          cross join lateral cn_quem(s::date) q
         group by q.publicador_id) m),
    'mes_horas', (select coalesce(round(sum(extract(epoch from (q.fim::time - q.hora::time)) / 3600)::numeric, 1), 0)
          from generate_series(cn_segunda(v_mes_ini), v_mes_fim - 1, interval '7 days') s
          cross join lateral cn_quem(s::date) q)
  );
end $$;

-- Tudo que o app escreve. As regras valem aqui, não só na tela: máximo de
-- pessoas juntas num instante, ninguém em dois lugares ao mesmo tempo,
-- máximo de presenças por semana, horário cancelado.
create or replace function public.cn_acao(p_senha text, p_acao text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_senha text := p_senha;
  v_semana date := (p->>'semana')::date;
  v_local text := p->>'local';
  v_dia int := (p->>'dia')::int;
  v_hora text := p->>'hora';
  v_fim text := p->>'fim';
  v_pub uuid := (p->>'publicador_id')::uuid;
  v_regras jsonb;
  v_max int;
  v_n int;
  v_ponto text;
  v_id uuid;
  v_extra jsonb := '{}'::jsonb;
begin
  if not cn_senha_ok(p_senha) then
    raise exception 'Código da porta errado' using errcode = '28000';
  end if;
  select valor into v_regras from cn_config where chave = 'regras';

  case p_acao
  when 'entrar', 'fixar' then
    if v_pub is null or v_semana is null or v_local is null or v_hora is null or v_fim is null then raise exception 'Faltou quem ou quando'; end if;
    if v_hora !~ '^\d\d:\d\d$' or v_fim !~ '^\d\d:\d\d$' or v_hora >= v_fim then raise exception 'Horário inválido: o fim precisa ser depois do início'; end if;
    if not exists (select 1 from cn_publicadores where id = v_pub and ativo) then raise exception 'Publicador não encontrado'; end if;
    if exists (select 1 from cn_cancelamentos c where c.semana = v_semana and c.local = v_local and c.dia = v_dia and c.hora < v_fim and c.fim > v_hora) then raise exception 'Esse horário foi cancelado neste local'; end if;
    -- a própria pessoa já está nesse horário (avulso ou fixo)? então é só ajuste
    delete from cn_inscricoes i where i.semana = v_semana and i.local = v_local and i.dia = v_dia and i.publicador_id = v_pub and i.hora < v_fim and i.fim > v_hora;
    if exists (select 1 from cn_quem(v_semana) q where q.dia = v_dia and q.publicador_id = v_pub and q.hora < v_fim and q.fim > v_hora and q.local <> v_local) then raise exception 'Já está em outro local nesse horário'; end if;
    if exists (select 1 from cn_quem(v_semana) q where q.dia = v_dia and q.publicador_id = v_pub and q.hora < v_fim and q.fim > v_hora and q.local = v_local and q.fixo and p_acao = 'entrar') then raise exception 'Já está fixo nesse horário'; end if;
    v_max := coalesce((v_regras->>'max_por_turno')::int, 3);
    -- máximo de pessoas juntas: confere no início pedido e no início de cada presença que cruza a nova
    for v_ponto in select v_hora union select q.hora from cn_quem(v_semana) q where q.local = v_local and q.dia = v_dia and q.hora > v_hora and q.hora < v_fim loop
      select count(*) into v_n from cn_quem(v_semana) q where q.local = v_local and q.dia = v_dia and q.publicador_id <> v_pub and q.hora <= v_ponto and q.fim > v_ponto;
      if v_n >= v_max then raise exception 'Às % já tem % pessoas nesse local, o máximo', v_ponto, v_n; end if;
    end loop;
    select count(*) into v_n from cn_quem(v_semana) q where q.publicador_id = v_pub;
    if v_n >= coalesce((v_regras->>'max_por_semana')::int, 3) then raise exception 'Já tem % presenças nesta semana, o máximo', v_n; end if;
    if p_acao = 'entrar' then
      insert into cn_inscricoes (semana, local, dia, hora, fim, publicador_id) values (v_semana, v_local, v_dia, v_hora, v_fim, v_pub);
    else
      update cn_fixos f set ate = v_semana where f.local = v_local and f.dia = v_dia and f.publicador_id = v_pub and f.hora < v_fim and f.fim > v_hora and f.desde < v_semana and (f.ate is null or f.ate > v_semana);
      delete from cn_fixos f where f.local = v_local and f.dia = v_dia and f.publicador_id = v_pub and f.hora < v_fim and f.fim > v_hora and f.desde >= v_semana;
      insert into cn_fixos (local, dia, hora, fim, publicador_id, desde, ate) values (v_local, v_dia, v_hora, v_fim, v_pub, v_semana, null);
      delete from cn_faltas x where x.local = v_local and x.dia = v_dia and x.hora = v_hora and x.publicador_id = v_pub and x.semana >= v_semana;
      delete from cn_inscricoes i where i.local = v_local and i.dia = v_dia and i.publicador_id = v_pub and i.semana >= v_semana and i.hora < v_fim and i.fim > v_hora;
    end if;
  when 'sair' then
    -- só esta semana
    delete from cn_inscricoes i where i.semana = v_semana and i.local = v_local and i.dia = v_dia and i.hora = v_hora and i.publicador_id = v_pub;
    if exists (select 1 from cn_fixos f where f.local = v_local and f.dia = v_dia and f.hora = v_hora and f.publicador_id = v_pub and f.desde <= v_semana and (f.ate is null or f.ate > v_semana)) then
      insert into cn_faltas (semana, local, dia, hora, publicador_id) values (v_semana, v_local, v_dia, v_hora, v_pub) on conflict do nothing;
    end if;
  when 'desfixar' then
    update cn_fixos f set ate = v_semana where f.local = v_local and f.dia = v_dia and f.hora = v_hora and f.publicador_id = v_pub and f.desde < v_semana and (f.ate is null or f.ate > v_semana);
    delete from cn_fixos f where f.local = v_local and f.dia = v_dia and f.hora = v_hora and f.publicador_id = v_pub and f.desde >= v_semana;
    delete from cn_inscricoes i where i.local = v_local and i.dia = v_dia and i.hora = v_hora and i.publicador_id = v_pub and i.semana >= v_semana;
  when 'cancelar' then
    insert into cn_cancelamentos (semana, local, dia, hora, fim, motivo) values (v_semana, v_local, v_dia, v_hora, coalesce(v_fim, '23:59'), coalesce(p->>'motivo', ''))
      on conflict (semana, local, dia, hora) do update set motivo = excluded.motivo, fim = excluded.fim;
  when 'reabrir' then
    delete from cn_cancelamentos c where c.semana = v_semana and c.local = v_local and c.dia = v_dia and c.hora = v_hora;
  when 'publicador_salvar' then
    if v_pub is null then
      insert into cn_publicadores (nome, responsavel) values (trim(p->>'nome'), coalesce((p->>'responsavel')::boolean, false)) returning id into v_id;
      v_extra := jsonb_build_object('novo_id', v_id);
    else
      update cn_publicadores set nome = coalesce(nullif(trim(p->>'nome'), ''), nome), responsavel = coalesce((p->>'responsavel')::boolean, responsavel) where id = v_pub;
    end if;
  when 'publicador_remover' then
    update cn_publicadores set ativo = false where id = v_pub;
    delete from cn_inscricoes where publicador_id = v_pub and semana >= cn_segunda(current_date);
    update cn_fixos set ate = cn_segunda(current_date) where publicador_id = v_pub and (ate is null or ate > cn_segunda(current_date));
  when 'config_salvar' then
    if p->>'chave' not in ('congregacao', 'regras', 'locais', 'carrinhos', 'contato', 'problemas') then raise exception 'Chave inválida'; end if;
    insert into cn_config (chave, valor) values (p->>'chave', p->'valor')
      on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  when 'senha_trocar' then
    if length(coalesce(p->>'nova', '')) < 4 then raise exception 'O código precisa de pelo menos 4 dígitos'; end if;
    update cn_config set valor = to_jsonb(p->>'nova'), atualizado_em = now() where chave = 'senha';
    v_senha := p->>'nova';
  else
    raise exception 'Ação desconhecida: %', p_acao;
  end case;

  return cn_estado(v_senha, coalesce(v_semana, current_date)) || v_extra;
end $$;

grant execute on function public.cn_estado(text, date) to anon, authenticated;
grant execute on function public.cn_acao(text, text, jsonb) to anon, authenticated;

-- Semente: código da porta, regras, três locais (todo dia, 6h–22h), dois
-- carrinhos, contato. Tudo editável pelo app em "Mais".
insert into public.cn_config (chave, valor) values
('senha', to_jsonb('1914'::text)),
('congregacao', to_jsonb('Congregação Nova'::text)),
('regras', '{"min_por_turno":2,"max_por_turno":3,"max_por_semana":3,"cancelar_ate_horas":2}'::jsonb),
('locais', '[
 {"id":"praca","nome":"Praça","apelido":"Praça","endereco":"","cor":"#1f6f8b","icone":"🌳","janela":"todo dia · 6h–22h","carrinho":"A","mapa":"","dias":[0,1,2,3,4,5,6],"abre":"06:00","fecha":"22:00"},
 {"id":"rodoviaria","nome":"Rodoviária","apelido":"Rodoviária","endereco":"","cor":"#8b5e1f","icone":"🚌","janela":"todo dia · 6h–22h","carrinho":"B","mapa":"","dias":[0,1,2,3,4,5,6],"abre":"06:00","fecha":"22:00"},
 {"id":"outro","nome":"Outro","apelido":"Outro","endereco":"","cor":"#3d7a3a","icone":"📍","janela":"todo dia · 6h–22h","carrinho":"B","mapa":"","dias":[0,1,2,3,4,5,6],"abre":"06:00","fecha":"22:00"}
]'::jsonb),
('carrinhos', '[
 {"id":"A","nome":"Carrinho A","guardado":"Salão do Reino (armário da entrada)","responsavel":"","publicacoes":"Bíblia, Sentinela, Despertai!, folhetos"},
 {"id":"B","nome":"Carrinho B","guardado":"","responsavel":"","publicacoes":"Bíblia, Sentinela, Despertai!, folhetos, cartões jw.org"}
]'::jsonb),
('contato', '{"nome":"Thiago","whatsapp":"5521995988404"}'::jsonb),
('problemas', '["Publicação faltando","Cartaz desatualizado","Carrinho com defeito","Outro"]'::jsonb)
on conflict (chave) do nothing;
