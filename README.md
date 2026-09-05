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
- **Horário livre, de 15 em 15 minutos** (como reunião no Outlook): cada
  pessoa marca de que hora a que hora, dentro do horário do local (6h–22h).
  "Turno" é quem está no mesmo local ao mesmo tempo; quem fica sozinho por
  15 minutos ou mais aparece em *Precisando de companhia* pra todo mundo.
- **Toda semana:** marca uma vez com 🔁 e vale até parar. Numa semana que
  não der, "Faltar só nesta semana"; pra encerrar, "Parar de vez".
- **Colocar alguém:** quem organiza coloca a dupla direto, sem os dois
  precisarem entrar. Dá pra ajustar o horário de qualquer um.
- **O banco manda.** Toda presença, saída, cancelamento e cadastro vai pro
  Supabase na hora; todo mundo vê a mesma escala. As regras (máximo de
  pessoas juntas, ninguém em dois lugares ao mesmo tempo, máximo por semana,
  período cancelado) valem no servidor, não só na tela.
- **Problema no carrinho?** Botão que abre o WhatsApp do responsável com a
  mensagem pronta (publicação faltando, cartaz desatualizado…). A lista e o
  número são editáveis em *Mais*.

## Telas

| aba | o que tem |
|---|---|
| Hoje | seu próximo horário, quem está precisando de companhia ("Eu vou"), onde está cada carrinho, linha do tempo de hoje |
| Agenda | por dia e local: linha do tempo 6h–22h e quem está junto em cada período; mandar a escala no WhatsApp, imprimir |
| Entrar (+) | local → dia → início e fim (15 em 15), prévia de quem vai estar lá, 🔁 toda semana |
| Meus | seus horários, com quem, ajustar, sair (só esta semana ou de vez), contagem do mês |
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
(semana, local, dia, hora, fim, quem), `cn_fixos` (toda semana, de `desde`
até `ate`), `cn_faltas` (semana em que o fixo não vai), `cn_cancelamentos`.

## Rodar local

É um HTML estático: `python3 -m http.server` na pasta e abre
`http://localhost:8000`. O banco é o de produção, então cuidado com o que
você clica.

## Deploy

Projeto `congregacaonova` na Vercel, arquivo `index.html` na raiz.
