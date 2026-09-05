-- Congregação Nova: escala de testemunho público com carrinhos.
-- Espelho do que está aplicado no projeto Supabase (migrations
-- congregacaonova_escala + congregacaonova_config_contato). Rodar inteiro
-- num banco vazio deixa o backend pronto; a inversa está em derrubar.sql.
--
-- Sem login. A "porta" é um código simples guardado em cn_config('senha');
-- toda leitura e escrita passa por função SECURITY DEFINER que confere o
-- código. As tabelas ficam com RLS ligado e sem política: a chave pública
-- (anon) não enxerga nada direto.

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
  motivo text not null default '',
  criado_em timestamptz not null default now(),
  primary key (semana, local, dia, hora)
);

alter table public.cn_config enable row level security;
alter table public.cn_publicadores enable row level security;
alter table public.cn_inscricoes enable row level security;
alter table public.cn_cancelamentos enable row level security;
revoke all on public.cn_config, public.cn_publicadores, public.cn_inscricoes, public.cn_cancelamentos from anon, authenticated;

create or replace function public.cn_segunda(d date) returns date
language sql immutable as $$
  select d - (extract(isodow from d)::int - 1);
$$;

create or replace function public.cn_senha_ok(p_senha text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from cn_config where chave = 'senha' and valor #>> '{}' = p_senha);
$$;
revoke execute on function public.cn_senha_ok(text) from public, anon, authenticated;

-- Tudo que o app lê, numa chamada: configuração, publicadores ativos,
-- inscrições e cancelamentos da semana pedida, contagem do mês.
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
    'inscricoes', (select coalesce(jsonb_agg(jsonb_build_object('local', local, 'dia', dia, 'hora', hora, 'publicador_id', publicador_id) order by criado_em), '[]'::jsonb) from cn_inscricoes where semana = v_semana),
    'cancelamentos', (select coalesce(jsonb_agg(jsonb_build_object('local', local, 'dia', dia, 'hora', hora, 'motivo', motivo)), '[]'::jsonb) from cn_cancelamentos where semana = v_semana),
    'mes', (select coalesce(jsonb_object_agg(publicador_id, n), '{}'::jsonb) from (select publicador_id, count(*) as n from cn_inscricoes where semana >= v_mes_ini and semana < v_mes_fim group by publicador_id) m),
    'mes_turnos', (select count(distinct (semana, local, dia, hora)) from cn_inscricoes where semana >= v_mes_ini and semana < v_mes_fim)
  );
end $$;

-- Tudo que o app escreve. As regras (máximo por turno, por semana,
-- conflito de horário, turno cancelado) valem aqui, não só na tela.
create or replace function public.cn_acao(p_senha text, p_acao text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_senha text := p_senha;
  v_semana date := (p->>'semana')::date;
  v_local text := p->>'local';
  v_dia int := (p->>'dia')::int;
  v_hora text := p->>'hora';
  v_pub uuid := (p->>'publicador_id')::uuid;
  v_regras jsonb;
  v_n int;
  v_id uuid;
  v_extra jsonb := '{}'::jsonb;
begin
  if not cn_senha_ok(p_senha) then
    raise exception 'Código da porta errado' using errcode = '28000';
  end if;
  select valor into v_regras from cn_config where chave = 'regras';

  case p_acao
  when 'entrar' then
    if v_pub is null or v_semana is null or v_local is null or v_hora is null then raise exception 'Faltou quem ou quando'; end if;
    if not exists (select 1 from cn_publicadores where id = v_pub and ativo) then raise exception 'Publicador não encontrado'; end if;
    if exists (select 1 from cn_cancelamentos c where c.semana = v_semana and c.local = v_local and c.dia = v_dia and c.hora = v_hora) then raise exception 'Esse turno foi cancelado'; end if;
    select count(*) into v_n from cn_inscricoes i where i.semana = v_semana and i.local = v_local and i.dia = v_dia and i.hora = v_hora;
    if v_n >= coalesce((v_regras->>'max_por_turno')::int, 3) then raise exception 'Esse turno já está cheio'; end if;
    if exists (select 1 from cn_inscricoes i where i.semana = v_semana and i.publicador_id = v_pub and i.dia = v_dia and i.hora = v_hora) then raise exception 'Você já está em outro local nesse horário'; end if;
    select count(*) into v_n from cn_inscricoes i where i.semana = v_semana and i.publicador_id = v_pub;
    if v_n >= coalesce((v_regras->>'max_por_semana')::int, 3) then raise exception 'Você já tem % turnos nesta semana, o máximo', v_n; end if;
    insert into cn_inscricoes (semana, local, dia, hora, publicador_id) values (v_semana, v_local, v_dia, v_hora, v_pub) on conflict do nothing;
  when 'sair' then
    delete from cn_inscricoes i where i.semana = v_semana and i.local = v_local and i.dia = v_dia and i.hora = v_hora and i.publicador_id = v_pub;
  when 'cancelar' then
    insert into cn_cancelamentos (semana, local, dia, hora, motivo) values (v_semana, v_local, v_dia, v_hora, coalesce(p->>'motivo', ''))
      on conflict (semana, local, dia, hora) do update set motivo = excluded.motivo;
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

-- Semente: código da porta, regras, três locais, dois carrinhos, contato.
-- Tudo isso é editável pelo app em "Mais"; o código, em "Trocar código".
insert into public.cn_config (chave, valor) values
('senha', to_jsonb('1914'::text)),
('congregacao', to_jsonb('Congregação Nova'::text)),
('regras', '{"min_por_turno":2,"max_por_turno":3,"max_por_semana":3,"cancelar_ate_horas":2}'::jsonb),
('locais', '[
 {"id":"praca","nome":"Praça","apelido":"Praça","endereco":"","cor":"#1f6f8b","icone":"🌳","janela":"todo dia · 7h–19h","carrinho":"A","mapa":"","dias":[0,1,2,3,4,5,6],"horas":["07:00","09:00","11:00","13:00","15:00","17:00"],"duracao":2},
 {"id":"rodoviaria","nome":"Rodoviária","apelido":"Rodoviária","endereco":"","cor":"#8b5e1f","icone":"🚌","janela":"todo dia · 7h–19h","carrinho":"B","mapa":"","dias":[0,1,2,3,4,5,6],"horas":["07:00","09:00","11:00","13:00","15:00","17:00"],"duracao":2},
 {"id":"outro","nome":"Outro","apelido":"Outro","endereco":"","cor":"#3d7a3a","icone":"📍","janela":"todo dia · 7h–19h","carrinho":"B","mapa":"","dias":[0,1,2,3,4,5,6],"horas":["07:00","09:00","11:00","13:00","15:00","17:00"],"duracao":2}
]'::jsonb),
('carrinhos', '[
 {"id":"A","nome":"Carrinho A","guardado":"Salão do Reino (armário da entrada)","responsavel":"","publicacoes":"Bíblia, Sentinela, Despertai!, folhetos"},
 {"id":"B","nome":"Carrinho B","guardado":"","responsavel":"","publicacoes":"Bíblia, Sentinela, Despertai!, folhetos, cartões jw.org"}
]'::jsonb),
('contato', '{"nome":"Thiago","whatsapp":"5521995988404"}'::jsonb),
('problemas', '["Publicação faltando","Cartaz desatualizado","Carrinho com defeito","Outro"]'::jsonb)
on conflict (chave) do nothing;
