-- A inversa de schema.sql: derruba tudo da Congregação Nova, e só isso.
-- Antes de rodar, guarde o que importa:
--   select * from cn_publicadores; select * from cn_inscricoes; select * from cn_config;
drop function if exists public.cn_acao(text, text, jsonb);
drop function if exists public.cn_estado(text, date);
drop function if exists public.cn_senha_ok(text);
drop function if exists public.cn_segunda(date);
drop table if exists public.cn_inscricoes;
drop table if exists public.cn_cancelamentos;
drop table if exists public.cn_publicadores;
drop table if exists public.cn_config;
