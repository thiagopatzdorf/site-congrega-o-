# Congregação Nova · testemunho público

Escala de testemunho público com carrinhos, feita pra celular: quem vai a
cada turno, onde está cada carrinho, quem tem a chave. Um arquivo
(`index.html`) na Vercel e um banco no Supabase.

**No ar:** https://congregacaonova.vercel.app

## Como funciona

- **Sem login.** Existe um código da porta (4 dígitos, combinado no grupo).
  Quem digita entra; o aparelho lembra. Dá pra trocar em *Mais › Trocar
  código da porta*.
- **Quem é você.** Na primeira vez a pessoa escolhe o próprio nome na lista
  (ou cadastra). Fica só no aparelho. Confiança, não senha.
- **O banco manda.** Toda inscrição, saída, cancelamento e cadastro vai
  pro Supabase na hora; todo mundo vê a mesma escala. As regras (mínimo e
  máximo por turno, máximo por semana, conflito de horário, turno
  cancelado) valem no servidor, não só na tela.
- **Problema no carrinho?** Botão que abre o WhatsApp do responsável com a
  mensagem pronta (publicação faltando, cartaz desatualizado…). A lista e o
  número são editáveis em *Mais*.

## Telas

| aba | o que tem |
|---|---|
| Hoje | seu próximo turno, quem falta hoje ("Eu vou"), onde está cada carrinho, turnos de hoje |
| Agenda | semana inteira por local e dia, mandar a escala no WhatsApp, imprimir |
| Inscrever (+) | local → dia → hora, em três toques |
| Meus | seus turnos, dupla, pedir troca, sair, contagem do mês |
| Mais | regras, locais, carrinhos, publicadores, contato, código da porta |

A seta `‹ esta semana ›` no topo troca de semana.

## Backend (Supabase)

Duas funções, só isso — `cn_estado` (lê) e `cn_acao` (escreve). As duas
conferem o código da porta. As tabelas têm RLS ligado e nenhuma política:
a chave pública que está no HTML não enxerga nada sem passar pelas
funções.

- [`supabase/schema.sql`](supabase/schema.sql): cria tudo e planta a
  semente (código `1914`, regras, três locais, dois carrinhos, contato).
- [`supabase/derrubar.sql`](supabase/derrubar.sql): a inversa. Derruba
  só o que é da Congregação Nova.

Tabelas: `cn_config` (chave → json), `cn_publicadores`, `cn_inscricoes`
(semana, local, dia, hora, quem), `cn_cancelamentos`.

## Rodar local

É um HTML estático: `python3 -m http.server` na pasta e abre
`http://localhost:8000`. O banco é o de produção, então cuidado com o que
você clica.

## Deploy

Projeto `congregacaonova` na Vercel, arquivo `index.html` na raiz.
